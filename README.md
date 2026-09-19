# static-hermes-cli

Static Hermes の `shermes` と、macOS / Linux ネイティブ実行ファイルの生成に必要な
ヘッダー・静的ライブラリを、再配置可能な prebuilt toolchain として配布します。

GitHub Releases には次の4種類のアーカイブを公開します。

- `static-hermes-<version>-darwin-arm64.tar.gz`
- `static-hermes-<version>-darwin-x64.tar.gz`
- `static-hermes-<version>-linux-arm64.tar.gz`
- `static-hermes-<version>-linux-x64.tar.gz`

Hermes は `hermes` サブモジュールの commit に固定し、macOSのRelease buildではXcode 16.4と
macOS SDK 15.5を使用します。各アーカイブの `manifest.json` に commit、Xcode、SDK、
対象プラットフォーム、最低macOSバージョンを記録します。現在の最低対応バージョンは
macOS 13.0 です。
Linux版は Ubuntu 24.04 / Clang 18 でビルドし、manifest に Ubuntu、glibc、ICU の
バージョンを記録します。Linux版の動作対象は Ubuntu 24.04（glibc 2.39 / ICU 74）です。
Alpine Linux（musl）向けのバイナリではありません。

## 含まれるもの

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

`shermes` は実行中の自身のパスから `../include` と `../lib` を解決します。
ビルドマシンの Xcode、SDK、Hermes build directory の絶対パスは使いません。
別ディレクトリへの移動や、`PATH` 上に置いたシンボリックリンクからの起動にも対応します。

## インストール

[Releases](https://github.com/ssssota/static-hermes-cli/releases) からCPUに合う
アーカイブと `SHA256SUMS` を取得し、checksumを検証して展開します。

```sh
shasum -a 256 -c SHA256SUMS
tar -xzf static-hermes-0.1.0-darwin-arm64.tar.gz
export PATH="$PWD/static-hermes-0.1.0-darwin-arm64/bin:$PATH"
shermes --version
```

macOS の `-emit-c` と `-dump-ir` はアーカイブだけで動作します。
Linux では実行時に `libicu74` と `libstdc++6` が必要です。

```sh
shermes -O -emit-c -o app.c app.js
shermes -O -dump-ir app.js >app.ir
```

`-c` と `-static-link` は外部Cコンパイラを起動するため、対象Macに Xcode または
Command Line Tools が必要です。Hermesのヘッダーとライブラリはアーカイブ内のものを
自動的に使用します。Boost.Contextのパスを `-Wc` で追加する必要はありません。
Linux で `-c` / `-static-link` を使う場合は、Clang、C/C++ 開発環境、ICU開発用ファイルを
インストールします（Ubuntu 24.04）:

```sh
sudo apt-get update
sudo apt-get install clang build-essential libicu-dev
```

```sh
shermes -O -c -o app.o app.js
shermes -O -static-link -o app app.js
./app
```

配布対象は静的リンクモードです。Hermesの動的ライブラリは同梱していないため、
実行ファイルを生成するときは `-static-link` を指定してください。生成物はHermes runtime、
JSI、console、Boost.Contextを静的リンクしますが、macOS標準の
`libSystem`、`libc++`、CoreFoundation、Foundationには動的に依存します。
Linux では glibc、libstdc++、libgcc_s、ICU に動的に依存します。
`-static-link` は Hermes runtime の静的リンクを意味し、完全静的バイナリの生成ではありません。

## ローカルビルド

必要なものは macOS、XcodeまたはCommand Line Tools、CMake、Ninja、Python 3、Gitです。
clone後にHermesサブモジュールも初期化してください。

```sh
git submodule update --init hermes
./scripts/build.sh
PACKAGE_VERSION=0.1.0 ./scripts/package.sh
./scripts/test-package.sh dist/static-hermes-0.1.0-*.tar.gz
```

Hermesのサブモジュールのcommitまたはパッチを変更した後は、`CLEAN=1 ./scripts/build.sh`
を実行します。ビルドはサブモジュールを変更せず、`.build/hermes-src` に展開してから
配布用パッチを適用します。
`CMAKE_BIN`、`NINJA_BIN`、`PYTHON_BIN`、`BUILD_JOBS` でローカルのツールと並列数を
上書きできます。

### Linux（Docker）

Docker があれば macOS / Linux のどちらからでも実行できます。

```sh
git submodule update --init hermes
PACKAGE_VERSION=0.1.0 ./scripts/build-linux.sh
```

`hermes` サブモジュールと親リポジトリ（Git metadataを含む）を読み取り専用でマウントし、
コンテナ内でビルド・パッケージ作成・再配置テストを行います。
成果物は `dist/`、ビルドキャッシュは `.build/linux-arm64/` または `.build/linux-x64/`
に保存します。サブモジュールの未コミット変更はビルドには含まれません。

デフォルトは Docker ホストのCPUアーキテクチャです。別CPU向けには次のように指定します。
Docker 側で対象アーキテクチャのエミュレーションが必要で、ビルドには時間がかかります。

```sh
DOCKER_PLATFORM=linux/amd64 PACKAGE_VERSION=0.1.0 ./scripts/build-linux.sh
DOCKER_PLATFORM=linux/arm64 PACKAGE_VERSION=0.1.0 ./scripts/build-linux.sh
```

`BUILD_ROOT`、`DIST_DIR`、`BUILD_JOBS`、`CLEAN=1` も使用できます。
Ubuntu 24.04 上で直接ビルドする場合は、`docker/Dockerfile.linux` に記載した依存パッケージを
インストールして、macOSと同じ `build.sh` → `package.sh` → `test-package.sh` を実行できます。

## リリース

`v` で始まるtagをpushすると、GitHub Actionsが macOS / Linux の arm64 / x64 を
それぞれネイティブrunnerでビルドします。Linux job はローカルと同じ `build-linux.sh` を
Docker 上で実行します。各アーカイブは次を実行してからReleaseへ公開されます。

- 別パスへ移動したtoolchainで `--version`、`-emit-c`、`-dump-ir`、`-c` を確認
- `-static-link` で実行ファイルを生成し、その実行結果を確認
- Unicode正規化、配列処理、例外処理の実行結果を確認
- macOS は `otool -L`、Linux は `ldd` / `readelf` で共有ライブラリ依存と検索パスを確認
- アーキテクチャ、SHA-256、macOS の ad-hocコード署名を確認

```sh
git tag v0.1.0
git push origin v0.1.0
```

## 署名とNotarization

現在のmacOS公開物は ad-hoc 署名です。Developer ID署名とApple Notary Serviceへの提出には
配布者の証明書と認証情報が必要なため、このリポジトリの標準workflowには含めていません。
一般公開時にGatekeeper警告をなくす場合は、証明書をGitHub Actions secretsで管理する
署名・Notarization jobを追加してください。

## 対象外

- Linuxでの完全静的リンク、musl / Alpine Linux向けビルド
- lean VM（このHermes revisionではconsole bindingとの組み合わせが未対応）
- macOS SDKやclangそのものの同梱
- Hermesの共有ライブラリを使う動的リンク配布

Hermes本体はMIT Licenseです。配布アーカイブにはHermesと、静的リンクされる第三者
コンポーネントのライセンス／noticeを同梱します。
