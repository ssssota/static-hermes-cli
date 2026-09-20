# static-hermes-cli

Prebuilt [Static Hermes](https://github.com/facebook/hermes/tree/static_h)
toolchains for macOS, Linux, and Windows. Each release includes `shermes`, headers, and
static libraries for compiling JavaScript to native executables.

## Supported platforms

| Operating system | CPU | Asset suffix |
| --- | --- | --- |
| macOS 13 or later | Apple Silicon | `darwin-arm64` |
| macOS 13 or later | Intel | `darwin-x64` |
| Ubuntu 24.04 | ARM64 | `linux-arm64` |
| Ubuntu 24.04 | x86-64 | `linux-x64` |
| Windows 10/11 (experimental) | x86-64 | `windows-x64` |

Linux packages target glibc 2.39 and ICU 74, not musl or Alpine Linux. Install
the runtime dependencies before running `shermes` on Ubuntu 24.04:

```sh
sudo apt-get update
sudo apt-get install libicu74 libstdc++6
```

Windows packages require the Microsoft Visual C++ x64 Redistributable and use
Windows' built-in ICU. Windows ARM64 is not currently packaged.

## Installation

Choose either a release asset or mise. Versions use calendar dates: for example,
release tag `v2026.9.20` contains assets named `static-hermes-2026.9.20-<platform>.tar.gz`.

### Install with mise

Use mise's [GitHub backend](https://mise.jdx.dev/dev-tools/backends/github.html) to install binary.

```toml
[tools]
"github:ssssota/static-hermes-cli" = { version = "v2026.9.20" }
```

### Download a release asset

Choose an archive for your platform from
[GitHub Releases](https://github.com/ssssota/static-hermes-cli/releases), along
with `SHA256SUMS`. For example, on Apple Silicon macOS:

```sh
version=2026.9.20
platform=darwin-arm64
archive="static-hermes-${version}-${platform}.tar.gz"
release_url="https://github.com/ssssota/static-hermes-cli/releases/download/v${version}"

curl -fL "${release_url}/${archive}" -o "${archive}"
curl -fL "${release_url}/SHA256SUMS" -o SHA256SUMS
awk -v archive="${archive}" '$2 == archive' SHA256SUMS | shasum -a 256 -c -

tar -xzf "${archive}"
export PATH="$PWD/static-hermes-${version}-${platform}/bin:$PATH"
shermes --version
```

Set `version` and `platform` to the release and platform you want. On Linux,
use `sha256sum -c -` in place of `shasum -a 256 -c -`. Add the extracted `bin/`
directory to your shell's PATH configuration to keep it available in new sessions.

Keep the entire extracted directory together: `shermes` locates `include/` and
`lib/` relative to its executable. You can move the directory or symlink
`bin/shermes` onto your PATH.

On Windows, extract the `windows-x64.tar.gz` archive with `tar -xzf`, verify its
SHA-256 with `Get-FileHash`, and add the extracted `bin` directory to PATH.
The executable is `shermes.exe`; the entire extracted directory must stay together.

## Usage

Create a JavaScript file:

```js
// hello.js
print("hello");
```

Emit C source or inspect the intermediate representation without an external
C compiler:

```sh
shermes -O -emit-c -o hello.c hello.js
shermes -O -dump-ir hello.js >hello.ir
```

To compile an object file or native executable, install a C compiler:

- **macOS:** Xcode or Command Line Tools (`xcode-select --install`).
- **Ubuntu 24.04:** `sudo apt-get install clang build-essential libicu-dev`.
- **Windows x64:** install LLVM/Clang and Visual Studio C++ Build Tools with a
  Windows SDK. Run from an x64 Developer PowerShell with `clang.exe` on PATH.
  Use `-o hello.exe` and run `./hello.exe` for the executable example below.

```sh
shermes -O -c -o hello.o hello.js
shermes -O -static-link -o hello hello.js
./hello
```

Use `-static-link` when generating executables. Hermes, JSI, console bindings,
and Boost.Context are linked statically; their headers and libraries are found
automatically. Shared Hermes libraries are not included.

This does not produce a fully static executable. macOS binaries still depend on
system libraries and frameworks; Linux binaries depend on glibc, libstdc++,
libgcc_s, and ICU. macOS packages are ad-hoc signed, not Developer ID signed or
notarized.

Windows links the Hermes libraries statically but still depends on the Microsoft
C/C++ runtime and Windows system DLLs. Generated C uses Clang's MSVC target and
the dynamic CRT (`/MD` equivalent); MinGW libraries are not interchangeable.
Windows packages are unsigned. Use explicit output names ending in `.exe` for
executables and `.obj` for object files.

## Package contents

```text
static-hermes-<version>-<platform>/
├── bin/shermes
├── include/
│   ├── config/libhermesvm-config.h
│   └── hermes/...
├── lib/
│   ├── libboost_context.a
│   ├── libhermesvm_a.a
│   ├── libjsi.a
│   └── libshermes_console_a.a
├── manifest.json
└── share/licenses/...
```

`manifest.json` records the Hermes commit, platform, and build environment.
Each release's notes link directly to its upstream Hermes commit.

Windows packages use `bin/shermes.exe` and `hermesvm_a.lib`, `jsi.lib`,
`shermes_console_a.lib`, and `boost_context.lib` in `lib/`.

## Contributing

See [CONTRIBUTING.md](https://github.com/ssssota/static-hermes-cli/blob/main/CONTRIBUTING.md)
for local builds, validation, Hermes updates, and release procedures.

## License

This project and Hermes are MIT-licensed. See
[LICENSE](https://github.com/ssssota/static-hermes-cli/blob/main/LICENSE).
Packages include licenses and notices for bundled third-party components in
`share/licenses/`.
