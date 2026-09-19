#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "${repo_root}/versions.env"

build_root="${BUILD_ROOT:-${repo_root}/.build}"
hermes_dir="${repo_root}/hermes"
source_dir="${build_root}/hermes-src"
build_dir="${build_root}/hermes-build"
patch_files=("${repo_root}"/patches/*.patch)
cmake_bin="${CMAKE_BIN:-cmake}"
ninja_bin="${NINJA_BIN:-ninja}"
python_bin="${PYTHON_BIN:-python3}"
build_host="$(uname -s)-$(uname -m)"
platform_args=()
xcode_version=
sdk_version=
linux_distribution=
linux_version=
glibc_version=
icu_version=

case "$(uname -s)" in
  Darwin)
    c_compiler="$(/usr/bin/xcrun --find clang)"
    cxx_compiler="$(/usr/bin/xcrun --find clang++)"
    xcode_version="$(/usr/bin/xcodebuild -version | awk 'NR == 1 { print $2 }')"
    sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
    platform_args=(
      "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}"
      -DSHERMES_CC=/usr/bin/clang
      "-DSHERMES_CC_SYSCFLAGS=-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
      "-DSHERMES_CC_SYSLDFLAGS=-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
    )
    host_jobs="$(/usr/sbin/sysctl -n hw.ncpu)"
    if [[ "${STATIC_HERMES_RELEASE_BUILD:-0}" == "1" ]] &&
        { [[ "${xcode_version}" != "${RELEASE_XCODE_VERSION}" ]] ||
          [[ "${sdk_version}" != "${RELEASE_MACOSX_SDK_VERSION}" ]]; }; then
      echo "Expected Xcode ${RELEASE_XCODE_VERSION} / SDK ${RELEASE_MACOSX_SDK_VERSION}, found ${xcode_version} / ${sdk_version}." >&2
      exit 1
    fi
    ;;
  Linux)
    c_compiler="$(command -v "${CC:-clang}")"
    cxx_compiler="$(command -v "${CXX:-clang++}")"
    platform_args=(-DSHERMES_CC=clang -DSHERMES_CC_SYSCFLAGS= -DSHERMES_CC_SYSLDFLAGS=)
    host_jobs="$(nproc)"
    # shellcheck source=/dev/null
    source /etc/os-release
    linux_distribution="${ID}"
    linux_version="${VERSION_ID}"
    glibc_version="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
    icu_version="$(pkg-config --modversion icu-uc)"
    clang_version="$("${c_compiler}" -dumpversion)"
    if [[ "${STATIC_HERMES_RELEASE_BUILD:-0}" == "1" ]] &&
        { [[ "${linux_distribution}" != "ubuntu" ]] ||
          [[ "${linux_version}" != "${RELEASE_UBUNTU_VERSION}" ]] ||
          [[ "${clang_version%%.*}" != "${RELEASE_CLANG_MAJOR}" ]]; }; then
      echo "Expected Ubuntu ${RELEASE_UBUNTU_VERSION} / Clang ${RELEASE_CLANG_MAJOR}, found ${linux_distribution} ${linux_version} / ${clang_version}." >&2
      exit 1
    fi
    ;;
  *)
    echo "Unsupported build host: ${build_host}" >&2
    exit 1
    ;;
esac

for command in "${cmake_bin}" "${ninja_bin}" "${python_bin}" git shasum; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

mkdir -p "${build_root}"
build_root="$(CDPATH='' cd -- "${build_root}" && pwd)"
source_dir="${build_root}/hermes-src"
build_dir="${build_root}/hermes-build"

if [[ ! -e "${hermes_dir}/.git" ]] ||
    ! hermes_revision="$(git -C "${hermes_dir}" rev-parse --verify HEAD 2>/dev/null)"; then
  echo "Hermes submodule is not initialized. Run: git submodule update --init hermes" >&2
  exit 1
fi

reset_directory() {
  local path="$1"
  case "${path}" in
    "${build_root}"/*) ;;
    *)
      echo "Refusing to remove a path outside BUILD_ROOT: ${path}" >&2
      exit 1
      ;;
  esac
  rm -rf -- "${path}"
}

if [[ "${CLEAN:-0}" == "1" ]]; then
  reset_directory "${source_dir}"
  reset_directory "${build_dir}"
fi

patch_sha="$(cat "${patch_files[@]}" | shasum -a 256 | awk '{print $1}')"
source_fingerprint="${build_host}:${hermes_revision}:${patch_sha}"

if [[ -d "${source_dir}" ]]; then
  if [[ ! -f "${source_dir}/.static-hermes-source" ]] ||
      [[ "$(<"${source_dir}/.static-hermes-source")" != "${source_fingerprint}" ]]; then
    echo "The prepared Hermes source is stale. Re-run with CLEAN=1." >&2
    exit 1
  fi
else
  mkdir -p "${source_dir}"
  git -C "${hermes_dir}" archive --format=tar "${hermes_revision}" |
    tar -x -C "${source_dir}"
  # Use an explicit work tree: the archive may be inside the parent Git repo.
  # Only the exported files are patched; neither the submodule nor its index changes.
  hermes_git_dir="$(git -C "${hermes_dir}" rev-parse --absolute-git-dir)"
  for patch_file in "${patch_files[@]}"; do
    git -C "${source_dir}" --git-dir="${hermes_git_dir}" \
      --work-tree="${source_dir}" apply "${patch_file}"
  done
  printf '%s\n' "${source_fingerprint}" >"${source_dir}/.static-hermes-source"
fi

ninja_path="$(command -v "${ninja_bin}")"
python_path="$(command -v "${python_bin}")"

if [[ -n "${BUILD_JOBS:-}" ]]; then
  build_jobs="${BUILD_JOBS}"
else
  build_jobs="${host_jobs}"
  if ((build_jobs > 4)); then
    build_jobs=4
  fi
fi

"${cmake_bin}" \
  -S "${source_dir}" \
  -B "${build_dir}" \
  -G Ninja \
  "-DCMAKE_MAKE_PROGRAM=${ninja_path}" \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_C_COMPILER=${c_compiler}" \
  "-DCMAKE_CXX_COMPILER=${cxx_compiler}" \
  "-DPython_EXECUTABLE=${python_path}" \
  "${platform_args[@]}" \
  -DSHERMES_CC_INCLUDE_PATH= \
  -DSHERMES_CC_LIB_PATH=

"${cmake_bin}" \
  --build "${build_dir}" \
  --target shermes hermesvm_a shermes_console_a jsi \
  --parallel "${build_jobs}"

cat >"${build_dir}/static-hermes-build.env" <<EOF
HERMES_REVISION=${hermes_revision}
BUILD_HOST=${build_host}
XCODE_VERSION=${xcode_version}
MACOSX_SDK_VERSION=${sdk_version}
LINUX_DISTRIBUTION=${linux_distribution}
LINUX_VERSION=${linux_version}
GLIBC_VERSION=${glibc_version}
ICU_VERSION=${icu_version}
EOF

echo "Built shermes and its static runtime libraries in ${build_dir}"
