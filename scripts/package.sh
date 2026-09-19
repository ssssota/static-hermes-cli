#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "${repo_root}/versions.env"

build_root="${BUILD_ROOT:-${repo_root}/.build}"
build_root="$(CDPATH='' cd -- "${build_root}" && pwd)"
source_dir="${build_root}/hermes-src"
build_dir="${build_root}/hermes-build"
dist_dir="${DIST_DIR:-${repo_root}/dist}"
package_version="${PACKAGE_VERSION:-dev}"

if [[ ! -f "${build_dir}/static-hermes-build.env" ]]; then
  echo "Build metadata not found. Run scripts/build.sh first." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${build_dir}/static-hermes-build.env"

if [[ "${BUILD_HOST:-}" != "$(uname -s)-$(uname -m)" ]]; then
  echo "Build metadata does not match this host. Run scripts/build.sh first." >&2
  exit 1
fi

case "${package_version}" in
  *[!0-9A-Za-z._-]* | "")
    echo "PACKAGE_VERSION contains unsupported characters: ${package_version}" >&2
    exit 1
    ;;
esac

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Darwin-x86_64) platform=darwin-x64 ;;
  Linux-aarch64) platform=linux-arm64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  *)
    echo "Unsupported build host: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

if [[ -n "${PLATFORM:-}" ]] && [[ "${PLATFORM}" != "${platform}" ]]; then
  echo "Expected ${PLATFORM}, but the build host is ${platform}." >&2
  exit 1
fi

package_name="static-hermes-${package_version}-${platform}"
stage="${dist_dir}/${package_name}"
archive="${dist_dir}/${package_name}.tar.gz"

mkdir -p "${dist_dir}"
dist_dir="$(CDPATH='' cd -- "${dist_dir}" && pwd)"
stage="${dist_dir}/${package_name}"
archive="${dist_dir}/${package_name}.tar.gz"

rm -rf -- "${stage}"
rm -f -- "${archive}" "${archive}.sha256"
mkdir -p \
  "${stage}/bin" \
  "${stage}/include/config" \
  "${stage}/lib" \
  "${stage}/share/licenses/static-hermes-cli" \
  "${stage}/share/licenses/hermes" \
  "${stage}/share/licenses/boost" \
  "${stage}/share/licenses/dragonbox" \
  "${stage}/share/licenses/dtoa" \
  "${stage}/share/licenses/fast_float" \
  "${stage}/share/licenses/hermes-regex" \
  "${stage}/share/licenses/llvh" \
  "${stage}/share/licenses/zip"

install -m 0755 "${build_dir}/bin/shermes" "${stage}/bin/shermes"
cp -R "${source_dir}/include/hermes" "${stage}/include/hermes"
install -m 0644 \
  "${build_dir}/lib/config/libhermesvm-config.h" \
  "${stage}/include/config/libhermesvm-config.h"

install_library() {
  local source="$1"
  local name="$2"
  if [[ ! -f "${source}" ]]; then
    echo "Required library not found: ${source}" >&2
    exit 1
  fi
  install -m 0644 "${source}" "${stage}/lib/${name}"
}

install_library "${build_dir}/lib/libhermesvm_a.a" libhermesvm_a.a
install_library "${build_dir}/jsi/libjsi.a" libjsi.a
install_library \
  "${build_dir}/tools/shermes/libshermes_console_a.a" \
  libshermes_console_a.a

boost_context="$(find "${build_dir}/external/boost" -type f -name libboost_context.a -print -quit)"
if [[ -z "${boost_context}" ]]; then
  echo "Required Boost.Context library was not produced." >&2
  exit 1
fi
install_library "${boost_context}" libboost_context.a

install -m 0644 "${repo_root}/README.md" "${stage}/README.md"
install -m 0644 "${repo_root}/LICENSE" \
  "${stage}/share/licenses/static-hermes-cli/LICENSE"
install -m 0644 "${source_dir}/LICENSE" \
  "${stage}/share/licenses/hermes/LICENSE"
boost_license="$(find "${source_dir}/external/boost" -type f -name LICENSE_1_0.txt -print -quit)"
if [[ -z "${boost_license}" ]]; then
  echo "Boost license not found." >&2
  exit 1
fi
install -m 0644 "${boost_license}" "${stage}/share/licenses/boost/LICENSE_1_0.txt"
install -m 0644 "${repo_root}/licenses/dragonbox-NOTICE.txt" \
  "${stage}/share/licenses/dragonbox/NOTICE.txt"
install -m 0644 "${repo_root}/licenses/dtoa-LICENSE.txt" \
  "${stage}/share/licenses/dtoa/dtoa-LICENSE.txt"
install -m 0644 "${repo_root}/licenses/g_fmt-LICENSE.txt" \
  "${stage}/share/licenses/dtoa/g_fmt-LICENSE.txt"
install -m 0644 "${repo_root}/licenses/fast_float-LICENSE.txt" \
  "${stage}/share/licenses/fast_float/LICENSE.txt"
install -m 0644 "${source_dir}/include/hermes/Regex/LICENSE.TXT" \
  "${stage}/share/licenses/hermes-regex/LICENSE.txt"
install -m 0644 "${source_dir}/external/llvh/LICENSE.txt" \
  "${stage}/share/licenses/llvh/LICENSE.txt"
install -m 0644 "${source_dir}/external/zip/UNLICENSE" \
  "${stage}/share/licenses/zip/UNLICENSE"

python3 - "${package_version}" "${platform}" "${HERMES_REVISION}" \
  "${XCODE_VERSION:-}" "${MACOSX_SDK_VERSION:-}" "${MACOSX_DEPLOYMENT_TARGET}" \
  "${LINUX_DISTRIBUTION:-}" "${LINUX_VERSION:-}" "${GLIBC_VERSION:-}" \
  "${ICU_VERSION:-}" >"${stage}/manifest.json" <<'PY'
import json
import sys

version, platform, revision, xcode, sdk, macos, distro, release, glibc, icu = sys.argv[1:]
manifest = dict(schemaVersion=1, name="static-hermes", version=version,
                platform=platform, hermesRevision=revision, linkage="static-hermes-runtime")
if platform.startswith("darwin-"):
    manifest.update(xcodeVersion=xcode, macOSSDKVersion=sdk,
                    minimumMacOSVersion=macos, codeSignature="adhoc")
else:
    manifest.update(linuxDistribution=distro, linuxVersion=release,
                    glibcVersion=glibc, icuVersion=icu, codeSignature="none")
json.dump(manifest, sys.stdout, indent=2)
print()
PY

# Stripping invalidates the build-time signature. Apply a fresh ad-hoc
# signature so the archive has a valid Mach-O signature. Public Developer ID
# signing and notarization are intentionally a separate release concern.
case "${platform}" in
  darwin-*)
    /usr/bin/strip -x "${stage}/bin/shermes"
    /usr/bin/codesign --force --sign - --timestamp=none "${stage}/bin/shermes"
    ;;
  linux-*) strip --strip-all "${stage}/bin/shermes" ;;
esac

if strings "${stage}/bin/shermes" | grep -F "${build_root}" >/dev/null; then
  echo "The packaged shermes still contains its build directory." >&2
  exit 1
fi

tar -czf "${archive}" -C "${dist_dir}" "${package_name}"
(
  cd "${dist_dir}"
  shasum -a 256 "${package_name}.tar.gz" >"${package_name}.tar.gz.sha256"
)

echo "Created ${archive}"
