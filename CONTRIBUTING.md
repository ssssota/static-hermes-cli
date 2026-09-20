# Contributing

This repository builds and packages the `hermes` submodule as a relocatable
Static Hermes toolchain. See [README.md](README.md) for installation and usage.

## Set up the repository

```sh
git clone --recurse-submodules https://github.com/ssssota/static-hermes-cli.git
cd static-hermes-cli
```

For an existing clone, initialize or synchronize the pinned submodule:

```sh
git submodule update --init hermes
```

Build scripts export the submodule's checked-out commit into a separate source
directory and apply the patches in [patches/](patches/). They do not modify the
submodule, and uncommitted changes inside it are not included in a build.

## Build and test locally

### macOS

Install Xcode or Command Line Tools, CMake, Ninja, Python 3, and Git. Then run:

```sh
./scripts/build.sh
PACKAGE_VERSION=dev ./scripts/package.sh
./scripts/test-package.sh "dist/static-hermes-dev-darwin-$(uname -m | sed 's/x86_64/x64/').tar.gz"
```

The default build directory is `.build/`; archives are written to `dist/`.
Release builds use Xcode 16.4 and macOS SDK 15.5, targeting macOS 13.0.
The pinned environment versions are defined in [versions.env](versions.env).
Set `STATIC_HERMES_RELEASE_BUILD=1` to enforce the release environment checks.

### Linux with Docker

Docker can build Linux packages from either macOS or Linux:

```sh
PACKAGE_VERSION=dev ./scripts/build-linux.sh
```

This builds an Ubuntu 24.04 / Clang 18 image, mounts the repository and Hermes
submodule read-only, and runs the build, packaging, and relocation tests.
The parent repository is mounted too because the submodule's Git metadata lives
under `.git/modules/hermes`.

Packages are written to `dist/`. Build caches live in `.build/linux-arm64/` or
`.build/linux-x64/`, according to the Docker host's architecture. To select an
architecture explicitly:

```sh
DOCKER_PLATFORM=linux/amd64 ./scripts/build-linux.sh
DOCKER_PLATFORM=linux/arm64 ./scripts/build-linux.sh
```

Building for a different CPU requires Docker emulation and takes longer.
For a native Ubuntu 24.04 build, install the dependencies listed in
[docker/Dockerfile.linux](docker/Dockerfile.linux), then run `build.sh`,
`package.sh`, and `test-package.sh` as above, using the matching Linux archive.

### Build settings

Use `BUILD_ROOT` and `DIST_DIR` to change output locations, `BUILD_JOBS` to set
parallelism, and `PACKAGE_VERSION` to name an archive. When running `build.sh`
directly, `CMAKE_BIN`, `NINJA_BIN`, and `PYTHON_BIN` select the local tools.

After changing the Hermes commit or any patch, rebuild with `CLEAN=1`:

```sh
CLEAN=1 ./scripts/build.sh       # Native build
CLEAN=1 ./scripts/build-linux.sh # Docker build
```

This removes the prepared source and compiled output under the selected build
root. It does not remove the submodule or previously packaged archives.

### Validation

`scripts/test-package.sh` verifies the archive's `.sha256` sidecar, extracts it
into a path containing spaces, and checks:

- `--version`, C emission, IR output, and object compilation through a symlink.
- Static linking and execution, including Unicode normalization, arrays, and exceptions.
- Dynamic dependencies with `otool -L` on macOS or `ldd` / `readelf` on Linux.
- Package architecture and manifest metadata.
- Minimum macOS version and ad-hoc code signing on macOS.

Run the relevant build and package tests before proposing changes to scripts or
patches. Preserve relative header/library lookup so packages remain relocatable.
Shared Hermes distribution, lean VM packages, fully static Linux binaries, and
musl builds are outside the current scope.

## Update Hermes

[Update Hermes](.github/workflows/update-hermes.yml) runs daily at 09:00 Japan
time and can also be started manually:

```sh
gh workflow run update-hermes.yml
```

It follows the upstream `static_h` branch configured in [.gitmodules](.gitmodules)
and opens a PR against this repository's default branch from
`automation/update-hermes`. The fixed branch and existing PR are refreshed on
subsequent runs; the branch may be force-updated. The PR body includes a permanent
link to the new Hermes commit. No new PR is created when there is no difference,
and this workflow does not publish a release.

Enable **Allow GitHub Actions to create and approve pull requests** under
Settings → Actions → General → Workflow permissions. To trigger CI on these
automated PRs, configure the `HERMES_UPDATE_TOKEN` Actions secret with a
fine-grained PAT granting `Contents: write` and `Pull requests: write`.
Without it, the workflow uses `GITHUB_TOKEN`, whose PR events do not trigger
build workflows. See the
[create-pull-request token documentation](https://github.com/peter-evans/create-pull-request#token).

Review upstream changes and ensure the distribution patches still apply and
the package tests pass before merging an update.

## Publish a release

Start [Build and release](.github/workflows/build.yml) with `workflow_dispatch`:

```sh
gh workflow run build.yml --ref main -f version=v2026.9.20
```

The optional `version` input uses `vYYYY.M.D`, without zero-padded months or days.
If omitted, the workflow uses the current date in Japan time. The tag and release
title are identical; archive versions omit the leading `v`.

The workflow builds and tests macOS and Linux packages for arm64 and x64 on
native runners. Linux uses the same Docker script as local development.
Metadata, publishing, and Hermes-update jobs use `ubuntu-slim`.

Once all builds pass, the workflow tags the exact parent-repository commit that
was built and publishes the archives with `SHA256SUMS`. Release notes contain
only a permanent link to the Hermes commit used in the build; changelog generation
is disabled.

Re-running the same tag at the same commit replaces the assets, title, and notes.
A tag pointing to a different commit is rejected. Choose another date instead of
moving an existing release tag.

Pushes to `main` and pull requests run build checks only. Tag pushes do not
trigger the workflow or publish releases.

## macOS signing

Packages are ad-hoc signed. Developer ID signing and notarization are not part of
the current workflow. Adding them requires the maintainer's signing credentials
and Apple notarization configuration, managed through GitHub Actions secrets.
