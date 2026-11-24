# Setup Unity CLI

Installs the [Unity CLI](https://docs.unity.com/en-us/unity-cli) (`unity`) on a GitHub Actions runner and
adds it to `PATH`.

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: Unity-Technologies/setup-unity-cli@v1
  - run: unity --version
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `latest` | `latest`, or an exact version such as `1.0.1`. Pin a version for reproducible builds. |
| `channel` | `stable` | Release channel when `version` is `latest`: `stable` or `beta`. |
| `cache` | `true` | Cache the downloaded binary between workflow runs. |
| `non-interactive` | `true` | Sets `UNITY_NON_INTERACTIVE=1` for later steps, so no command waits on a prompt. |

## Outputs

| Output | Description |
|---|---|
| `version` | The installed Unity CLI version. |
| `path` | Full path to the installed `unity` binary. |
| `cache-hit` | `true` when the binary came from the cache. |

## Supported runners

GitHub-hosted and self-hosted runners on Linux, macOS and Windows, x64 and ARM64. Linux needs glibc 2.31 or
newer (Ubuntu 20.04, Debian 11 and later); Alpine and other musl images are not supported. The runner needs
`bash` and `curl`; Windows runners use the Git Bash that ships with them.

## Building and testing a Unity project

Sign-in uses a Unity Cloud service account read from the environment, so credentials never appear on a
command line. Pass them only to the steps that need them, never to this action.

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      UNITY_FORMAT: github # failures show up as annotations
    steps:
      - uses: actions/checkout@v4
      - uses: Unity-Technologies/setup-unity-cli@v1
        with:
          version: 1.0.1

      - name: Install the Unity Editor
        env:
          UNITY_SERVICE_ACCOUNT_ID: ${{ secrets.UNITY_SERVICE_ACCOUNT_ID }}
          UNITY_SERVICE_ACCOUNT_SECRET: ${{ secrets.UNITY_SERVICE_ACCOUNT_SECRET }}
        run: unity install 6000.0.32f1 --yes --accept-eula

      - name: Activate the Unity license
        env:
          UNITY_LICENSE_SERIAL: ${{ secrets.UNITY_LICENSE_SERIAL }}
        run: unity license activate

      - name: Test
        env:
          UNITY_SERVICE_ACCOUNT_ID: ${{ secrets.UNITY_SERVICE_ACCOUNT_ID }}
          UNITY_SERVICE_ACCOUNT_SECRET: ${{ secrets.UNITY_SERVICE_ACCOUNT_SECRET }}
        run: unity test --report-format junit --output test-results.xml

      - name: Build
        env:
          UNITY_SERVICE_ACCOUNT_ID: ${{ secrets.UNITY_SERVICE_ACCOUNT_ID }}
          UNITY_SERVICE_ACCOUNT_SECRET: ${{ secrets.UNITY_SERVICE_ACCOUNT_SECRET }}
        run: unity build --target StandaloneLinux64 --output build/

      - name: Return the Unity license
        if: always()
        env:
          UNITY_SERVICE_ACCOUNT_ID: ${{ secrets.UNITY_SERVICE_ACCOUNT_ID }}
          UNITY_SERVICE_ACCOUNT_SECRET: ${{ secrets.UNITY_SERVICE_ACCOUNT_SECRET }}
        run: unity license return --yes
```

`unity ci init` generates a complete workflow for your project, including Library caching, the Editor's Linux
runtime libraries and test sharding.

## Security

- The binary is checked against the SHA-256 in the release manifest before it is installed, and again when
  it is restored from the cache. The manifest comes from the same CDN as the binary, so the check proves
  the download is intact, not who published it. Every request is HTTPS only, redirects included.
- Inputs are validated against allowlists and passed to the script through environment variables.
- The action takes no secrets.
- Pin the action to a full commit SHA if your policy requires it.

## License

[Unity Companion License](LICENSE.md). Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
