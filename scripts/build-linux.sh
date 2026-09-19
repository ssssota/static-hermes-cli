#!/usr/bin/env bash
set -euo pipefail

# Run the same Linux build, packaging and relocation tests locally and in CI.
repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
docker_platform="${DOCKER_PLATFORM:-linux/$(docker version --format '{{.Server.Arch}}')}"
case "${docker_platform}" in
  linux/arm64) platform=linux-arm64 ;;
  linux/amd64) platform=linux-x64 ;;
  *) echo "Unsupported Docker platform: ${docker_platform}" >&2; exit 1 ;;
esac

if [[ ! -e "${repo_root}/hermes/.git" ]]; then
  echo "Run: git submodule update --init hermes" >&2
  exit 1
fi

build_root="${BUILD_ROOT:-${repo_root}/.build/${platform}}"
dist_dir="${DIST_DIR:-${repo_root}/dist}"
mkdir -p "${build_root}" "${dist_dir}"
build_root="$(CDPATH='' cd -- "${build_root}" && pwd)"
dist_dir="$(CDPATH='' cd -- "${dist_dir}" && pwd)"
image="${DOCKER_IMAGE:-static-hermes-builder:${platform}}"

docker build --platform "${docker_platform}" --tag "${image}" \
  --file "${repo_root}/docker/Dockerfile.linux" "${repo_root}/docker"

# Mount the parent repository too, because hermes/.git refers to .git/modules/hermes.
# Build products and packages are written only to their dedicated mounts.
docker run --rm --platform "${docker_platform}" \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=${repo_root},dst=/repo,readonly" \
  --mount "type=bind,src=${repo_root}/hermes,dst=/repo/hermes,readonly" \
  --mount "type=bind,src=${build_root},dst=/build" \
  --mount "type=bind,src=${dist_dir},dst=/dist" \
  --env GIT_CONFIG_COUNT=1 \
  --env GIT_CONFIG_KEY_0=safe.directory --env GIT_CONFIG_VALUE_0=/repo/hermes \
  --env BUILD_ROOT=/build --env DIST_DIR=/dist \
  --env "BUILD_JOBS=${BUILD_JOBS:-4}" --env "CLEAN=${CLEAN:-0}" \
  --env "PACKAGE_VERSION=${PACKAGE_VERSION:-dev}" --env "PLATFORM=${platform}" \
  --env STATIC_HERMES_RELEASE_BUILD=1 \
  "${image}" bash -euo pipefail -c '
    ./scripts/build.sh
    ./scripts/package.sh
    ./scripts/test-package.sh "/dist/static-hermes-${PACKAGE_VERSION}-${PLATFORM}.tar.gz"
  '
