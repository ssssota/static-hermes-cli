#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "${repo_root}/versions.env"
archive="${1:-}"

if [[ -z "${archive}" ]] || [[ ! -f "${archive}" ]]; then
  echo "usage: $0 <static-hermes-*.tar.gz>" >&2
  exit 1
fi

# Check the archive before extracting it, including the published checksum.
(
  cd "$(dirname -- "${archive}")"
  shasum -a 256 -c "$(basename -- "${archive}").sha256"
)

work="$(mktemp -d "${TMPDIR:-/tmp}/static-hermes-test.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

tar -xzf "${archive}" -C "${work}"
package_dir="$(find "${work}" -mindepth 1 -maxdepth 1 -type d -name 'static-hermes-*' -print -quit)"
if [[ -z "${package_dir}" ]]; then
  echo "The archive does not contain a static-hermes package directory." >&2
  exit 1
fi

# A path containing spaces catches accidental string-based argument splitting.
relocated="${work}/relocated toolchain"
mv "${package_dir}" "${relocated}"
relocated="$(CDPATH='' cd -- "${relocated}" && pwd)"
shermes="${relocated}/bin/shermes"
output_dir="${work}/output"
mkdir -p "${output_dir}"

path_bin="${work}/path-bin"
mkdir -p "${path_bin}"
ln -s "${shermes}" "${path_bin}/shermes"

"${shermes}" --version
"${shermes}" -O -emit-c -o "${output_dir}/hello.c" "${repo_root}/tests/hello.js"
"${shermes}" -O -dump-ir "${repo_root}/tests/hello.js" >"${output_dir}/hello.ir"

compile_log="${output_dir}/compile.log"
"${path_bin}/shermes" -v -O -c -o "${output_dir}/hello.o" \
  "${repo_root}/tests/hello.js" 2>"${compile_log}"
grep -F "${relocated}/include" "${compile_log}" >/dev/null

"${shermes}" -O -static-link -o "${output_dir}/hello" \
  "${repo_root}/tests/hello.js"
actual="$("${output_dir}/hello")"
if [[ "${actual}" != "hello" ]]; then
  echo "Unexpected executable output: ${actual}" >&2
  exit 1
fi

# Exercise the Unicode dependency and C++ exception/console bindings too.
"${shermes}" -O -static-link -o "${output_dir}/runtime" \
  "${repo_root}/tests/runtime.js"
[[ "$("${output_dir}/runtime")" == "runtime ok" ]]

assert_system_dependencies() {
  local executable="$1"
  local dependency
  if [[ "$(uname -s)" == "Linux" ]]; then
    local dependencies
    dependencies="$(ldd "${executable}")"
    if grep -E 'not found|lib(hermes|shermes|jsi|boost_context)' <<<"${dependencies}"; then
      echo "Missing dependency or unexpected shared runtime in ${executable}." >&2
      exit 1
    fi
    while IFS= read -r dependency; do
      case "${dependency}" in
        /lib/* | /lib64/* | /usr/lib/* | /usr/lib64/*) ;;
        *) echo "Unexpected dynamic dependency: ${dependency}" >&2; exit 1 ;;
      esac
    done < <(awk '/=> \// { print $3 } /^[[:space:]]*\// { print $1 }' <<<"${dependencies}")
    if readelf -d "${executable}" | grep -E '\((RPATH|RUNPATH)\)'; then
      echo "Unexpected runtime search path in ${executable}." >&2
      exit 1
    fi
    return
  fi
  while IFS= read -r dependency; do
    case "${dependency}" in
      /usr/lib/* | /System/Library/*) ;;
      *)
        echo "Unexpected dynamic dependency in ${executable}: ${dependency}" >&2
        exit 1
        ;;
    esac
  done < <(/usr/bin/otool -L "${executable}" | /usr/bin/awk 'NR > 1 { print $1 }')
}

assert_system_dependencies "${shermes}"
assert_system_dependencies "${output_dir}/hello"
assert_system_dependencies "${output_dir}/runtime"

if [[ "$(uname -s)" == "Darwin" ]]; then
  for executable in "${shermes}" "${output_dir}/hello" "${output_dir}/runtime"; do
    if ! /usr/bin/vtool -show-build "${executable}" |
        grep -E "minos[[:space:]]+${MACOSX_DEPLOYMENT_TARGET}$" >/dev/null; then
      echo "Unexpected minimum macOS version in ${executable}." >&2
      exit 1
    fi
  done
  /usr/bin/codesign --verify --strict "${shermes}"
fi

python3 -m json.tool "${relocated}/manifest.json" >/dev/null
python3 - "${relocated}/manifest.json" <<'PY'
import json
import platform
import sys

with open(sys.argv[1]) as f:
    manifest = json.load(f)
os_name = {"Darwin": "darwin", "Linux": "linux"}[platform.system()]
arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64"}[platform.machine()]
assert manifest["platform"] == f"{os_name}-{arch}", manifest
assert len(manifest["hermesRevision"]) == 40, manifest
PY

case "${archive}" in
  *-darwin-arm64.tar.gz)
    file "${shermes}" | grep -F arm64 >/dev/null
    ;;
  *-darwin-x64.tar.gz)
    file "${shermes}" | grep -F x86_64 >/dev/null
    ;;
  *-linux-arm64.tar.gz)
    file "${shermes}" | grep -F 'ARM aarch64' >/dev/null
    ;;
  *-linux-x64.tar.gz)
    file "${shermes}" | grep -F 'x86-64' >/dev/null
    ;;
esac

echo "Package passed relocation, compile, static-link, and runtime tests."
