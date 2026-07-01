# Warp OSS Debian Package Bundle

This repository builds Debian packages for the Warp OSS channel from the [warpdotdev/warp](https://github.com/warpdotdev/warp) source tree and publishes the resulting artifacts through GitHub Releases.

## Download

- Latest release: <https://github.com/yolkarian/warp-oss-deb-bundle/releases/latest>
- All releases: <https://github.com/yolkarian/warp-oss-deb-bundle/releases>

Download `warp-terminal-oss_*.deb` from the release page, then install it with:

```bash
sudo apt install ./warp-terminal-oss_*.deb
```

You can also download the latest package with GitHub CLI:

```bash
gh release download --repo yolkarian/warp-oss-deb-bundle --pattern 'warp-terminal-oss_*.deb'
```

## Notes

This repository publishes standalone `.deb` packages only. It does not provide an apt repository.

The packaging flow removes the apt source setup that Warp's upstream Debian bundler adds by default. This avoids `apt update` errors such as:

```text
E: The repository 'https://releases.warp.dev/linux/deb oss Release' does not have a Release file.
W: Target Packages ... is configured multiple times ...
```

Packages built by this repository also try to remove stale `warpdotdev-oss` apt source files and signing keys that may have been left behind by older OSS packages.

## Build with GitHub Actions

Open the Actions tab and manually run the **Build Warp OSS Debian package** workflow.

Inputs:

- `warp_repository`: Warp source repository, defaults to `warpdotdev/warp`
- `warp_ref`: branch, tag, or commit to build, defaults to `main`

After the workflow finishes, the generated `.deb` is uploaded to a GitHub Release in this repository.

## Build locally

By default, the script expects the Warp source tree at `../warp` relative to this repository:

```bash
bash scripts/build-warp-oss-deb.sh
```

You can also provide the source path explicitly:

```bash
WARP_SOURCE_DIR=/path/to/warp bash scripts/build-warp-oss-deb.sh
```

If your machine has limited memory, limit Rust/Cargo parallelism, for example:

```bash
CARGO_BUILD_JOBS=2 WARP_SOURCE_DIR=/path/to/warp bash scripts/build-warp-oss-deb.sh
```

Build artifacts are written under `target/*/bundle/linux/` in the Warp source tree.
