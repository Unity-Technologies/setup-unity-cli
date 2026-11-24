#!/usr/bin/env bash
# Resolves and installs the Unity CLI for the setup-unity-cli action.
#
#   setup.sh resolve   reads the release manifest, writes version/platform/
#                      filename/sha256/dir to $GITHUB_OUTPUT
#   setup.sh install   downloads (unless the cache already restored it),
#                      verifies the SHA-256, and puts the binary on PATH
#
# Inputs arrive as environment variables, never interpolated into this script,
# so a crafted input cannot inject shell.
set -euo pipefail

CDN_BASE="https://public-cdn.cloud.unity3d.com/hub/prod/cli/"
GLIBC_MIN="2.31"

# Never call fail inside $(...): its ::error line would land in the captured
# value instead of the log, and the step would exit 1 with no message.
fail() {
  # Messages quote rejected input: flatten newlines so it can't start a new
  # workflow command line.
  local msg="${1//[$'\r\n']/ }"
  echo "::error title=setup-unity-cli::$msg"
  exit 1
}

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

# HTTPS only, redirects included.
CURL_OPTS=(-fsSL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2)
http_get() { curl "${CURL_OPTS[@]}" "$1"; }

# Sets PLATFORM to the runner's manifest key, <os>-<arch> as install.sh names
# them. A global, not an echo, so its fail is not swallowed by a $(...).
detect_platform() {
  local os arch
  case "${RUNNER_OS:-}" in
    Linux) os="linux" ;;
    macOS) os="darwin" ;;
    Windows) os="win32" ;;
    *) fail "Unsupported runner OS: '${RUNNER_OS:-unset}'." ;;
  esac
  case "${RUNNER_ARCH:-}" in
    X64) arch="x64" ;;
    ARM64) arch="arm64" ;;
    *) fail "Unsupported runner architecture: '${RUNNER_ARCH:-unset}'. Supported: X64, ARM64." ;;
  esac
  PLATFORM="${os}-${arch}"
}

# The Linux binaries are built against glibc $GLIBC_MIN. Below it the loader
# dies before main, which in a container job reads as a baffling exit code.
check_glibc() {
  local have=""
  have="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{ print $2 }')" || true
  if [ -z "$have" ]; then
    # Captured first: musl's ldd exits 1, which pipefail would hand to a
    # `ldd | grep` pipeline even when grep matches (same trap as install.sh).
    local ldd_out=""
    ldd_out="$(ldd --version 2>&1)" || true
    if printf '%s' "$ldd_out" | grep -qi musl; then
      fail "This runner uses musl libc (Alpine?). The Unity CLI requires glibc ${GLIBC_MIN} or newer."
    fi
    echo "::warning title=setup-unity-cli::Could not read the glibc version; continuing."
    return 0
  fi
  if ! awk -v have="$have" -v need="$GLIBC_MIN" 'BEGIN {
      split(have, h, "."); split(need, n, ".")
      exit !((h[1] > n[1]) || (h[1] == n[1] && h[2] >= n[2]))
    }'; then
    fail "This runner has glibc ${have}; the Unity CLI requires ${GLIBC_MIN} or newer. Use a newer container image."
  fi
}

# Prints the string at a dotted key path (binaries.linux-x64.sha256), or
# nothing. Plain awk because container images often have neither jq nor
# python3. Escapes are left as written; callers allowlist what they read.
json_get() {
  printf '%s' "$1" | awk -v want="$2" '
  { s = s $0 "\n" }
  END {
    n = length(s); depth = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "{") { depth++; type[depth] = "o"; expect[depth] = 1; key[depth] = "" }
      else if (c == "[") { depth++; type[depth] = "a"; expect[depth] = 0 }
      else if (c == "}" || c == "]") { depth-- }
      else if (c == ",") { if (type[depth] == "o") expect[depth] = 1 }
      else if (c == ":") { expect[depth] = 0 }
      else if (c == "\"") {
        str = ""
        for (j = i + 1; j <= n; j++) {
          d = substr(s, j, 1)
          if (d == "\\") { str = str substr(s, j, 2); j++; continue }
          if (d == "\"") break
          str = str d
        }
        i = j
        if (type[depth] == "o" && expect[depth]) { key[depth] = str; continue }
        p = ""
        for (k = 1; k <= depth; k++) {
          seg = (type[k] == "o") ? key[k] : "[]"
          p = (k == 1) ? seg : p "." seg
        }
        if (p == want) { print str; exit }
      }
    }
  }'
}

resolve() {
  local version="${INPUT_VERSION:-latest}"
  local channel
  channel="$(printf '%s' "${INPUT_CHANNEL:-stable}" | tr '[:upper:]' '[:lower:]')"

  # Allowlists: both values end up in a URL.
  case "$channel" in
    stable) manifest_file="latest.json" ;;
    beta) manifest_file="latest-beta.json" ;;
    *) fail "Invalid channel '$channel'. Allowed: stable, beta." ;;
  esac
  # [[ =~ ]] anchors to the whole string; grep would accept any one line.
  if [ "$version" != "latest" ] && ! [[ $version =~ $VERSION_RE ]]; then
    fail "Invalid version '$version'. Use 'latest' or an exact version such as 1.0.1."
  fi

  detect_platform
  local platform="$PLATFORM"
  case "$platform" in linux-*) check_glibc ;; esac

  # A pinned version reads its own release manifest; 'latest' reads the
  # channel's. Either way the checksum belongs to the binary we download.
  local url manifest
  if [ "$version" = "latest" ]; then
    url="${CDN_BASE}${manifest_file}"
  else
    url="${CDN_BASE}${version}/latest.json"
  fi
  manifest="$(http_get "$url")" || fail "Could not fetch the release manifest: $url"

  local got filename sha256
  got="$(json_get "$manifest" version)"
  filename="$(json_get "$manifest" "binaries.$platform.filename")"
  sha256="$(json_get "$manifest" "binaries.$platform.sha256")"

  # The manifest's version reaches a URL and a path too, so it gets the same
  # allowlist as the input.
  [[ $got =~ $VERSION_RE ]] \
    || fail "The release manifest has no valid version: $url"
  if [ "$version" != "latest" ] && [ "$got" != "$version" ]; then
    fail "Requested version $version but the manifest reports $got."
  fi
  [ -n "$filename" ] && [ -n "$sha256" ] \
    || fail "Unity CLI $got has no binary for $platform."
  # The filename also ends up in a URL and a path.
  [[ $filename =~ ^[A-Za-z0-9._-]+$ ]] \
    || fail "Unexpected binary name in the manifest: $filename"
  [[ $sha256 =~ ^[0-9a-f]{64}$ ]] \
    || fail "Unexpected checksum in the manifest for $platform."

  local dir="${RUNNER_TOOL_CACHE:?}/unity-cli/${got}/${platform}"
  {
    echo "version=$got"
    echo "platform=$platform"
    echo "filename=$filename"
    echo "sha256=$sha256"
    echo "dir=$dir"
  } >>"$GITHUB_OUTPUT"
  echo "Resolved Unity CLI $got for $platform."
}

# Picks the hashing tool up front, outside any $(...), so a missing one fails
# with a message.
SHA_TOOL=""
pick_sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_TOOL="shasum -a 256"
  else
    fail "Cannot verify the download: neither sha256sum nor shasum is available."
  fi
}

# Hash stdin: GNU sha256sum prefixes its line with a backslash when
# the filename needs escaping, as a Windows tool-cache path with backslashes does.
sha256_of() {
  $SHA_TOOL <"$1" | awk '{ print $1 }'
}

install() {
  local version="${RESOLVED_VERSION:?}" filename="${RESOLVED_FILENAME:?}"
  local sha256="${RESOLVED_SHA256:?}" dir="${RESOLVED_DIR:?}"
  local exe="unity"
  case "$filename" in *.exe) exe="unity.exe" ;; esac
  local bin="$dir/$exe"

  pick_sha_tool
  mkdir -p "$dir"
  # The cache is writable by any job in the repo, and $dir goes on PATH: keep
  # only the binary (no symlink) and verify it, so nothing else restored there
  # can shadow a command.
  find "$dir" -mindepth 1 -maxdepth 1 ! -name "$exe" -exec rm -rf {} +
  if [ -L "$bin" ] || [ -d "$bin" ]; then rm -rf "$bin"; fi
  if [ -f "$bin" ] && [ "$(sha256_of "$bin")" = "$sha256" ]; then
    echo "Using cached Unity CLI $version."
    chmod +x "$bin"
  else
    # A per-run name beside $dir, not in it: concurrent jobs on a shared
    # self-hosted runner never share it, and the prune above never sees it.
    local tmp
    tmp="$(mktemp "${dir}.XXXXXX")"
    echo "Downloading Unity CLI $version ($filename)..."
    if ! curl "${CURL_OPTS[@]}" "${CDN_BASE}${version}/${filename}" -o "$tmp"; then
      rm -f "$tmp"
      fail "Download failed: ${CDN_BASE}${version}/${filename}"
    fi
    local actual
    actual="$(sha256_of "$tmp")"
    if [ "$actual" != "$sha256" ]; then
      rm -f "$tmp"
      fail "SHA-256 mismatch for $filename: expected $sha256, got $actual."
    fi
    chmod +x "$tmp"
    mv -f "$tmp" "$bin"
  fi

  # GITHUB_PATH wants the runner's native form; Git Bash on Windows hands us a
  # POSIX path otherwise.
  local path_dir="$dir"
  if command -v cygpath >/dev/null 2>&1; then
    path_dir="$(cygpath -w "$dir")"
    bin="$(cygpath -w "$bin")"
  fi
  echo "$path_dir" >>"$GITHUB_PATH"

  if [ "${INPUT_NON_INTERACTIVE:-true}" = "true" ]; then
    echo "UNITY_NON_INTERACTIVE=1" >>"$GITHUB_ENV"
  fi

  echo "path=$bin" >>"$GITHUB_OUTPUT"
  # GITHUB_ENV applies from the next step, so set it for this run too.
  UNITY_NON_INTERACTIVE=1 "$dir/$exe" --version
}

case "${1:-}" in
  resolve) resolve ;;
  install) install ;;
  *) fail "usage: setup.sh resolve|install" ;;
esac
