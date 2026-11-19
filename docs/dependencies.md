# 依赖版本核验

核验日期为 2026-11-19。版本来自 pub.dev 与 crates.io 的官方 API，再由 Pub、Cargo 在实际 SDK 与上游约束下解析。这里的“最新”指已发布、未撤回的稳定版本；不把预发布版本、被撤回版本或强制覆盖约束的结果当作可交付升级。

本次逐项对照了三个 Cargo 清单与三个 Pub 清单。按注册表和包名去重后，51 项第三方直接依赖均与各自注册表的最新稳定版一致。应用、Rust 桥接包、核心库和 fuzz 包的项目版本统一为 `1.1.0`。

## 工具链与锁文件

- 验证环境：Flutter 3.50.0、Dart 3.14.0、Rust 1.99.1，Windows x64。
- `rust/Cargo.toml`、`rust/core/Cargo.toml`、`rust/fuzz/Cargo.toml` 均使用 Rust 2024；主工作区使用 resolver 3，声明 `rust-version = "1.89"`。最低版本是依赖解析边界，本次没有在 Rust 1.89 上单独重跑全部测试。
- 应用与 Flutter Rust 插件的 Dart 下限为 3.14.0、Flutter 下限为 3.50.0。独立 Cargokit 工具的 Dart 下限为 3.11.0。
- Dart/Rust 两侧 `flutter_rust_bridge` 固定为 2.13.0，与生成代码保持一致。单独升级一侧会破坏桥接协议。
- 提交并使用应用 `pubspec.lock`、Rust 主工作区及 fuzz 的 `Cargo.lock`、Cargokit 工具的 `pubspec.lock`。`rust_builder/pubspec.lock` 已重新解析，但仍遵循该插件现有的忽略规则；应用锁文件覆盖插件的运行时依赖。
- Cargokit 临时 runner 通过 path 依赖加载工具，不采用工具包自身锁文件。其直接依赖保持精确版本，避免运行时自动跨 API 升级；间接依赖仍由 runner 解析。

## 应用直接依赖

每一项均查询 `https://pub.dev/api/packages/<name>` 的 `latest` 元数据。Flutter SDK 自带的 `flutter`、`flutter_localizations`、`flutter_test` 随 SDK 固定。

| 包 | 本次版本 | 官方来源 |
| --- | --- | --- |
| flutter_rust_bridge | 2.13.0 | [pub.dev](https://pub.dev/packages/flutter_rust_bridge) |
| material_ui | 1.11.1 | [pub.dev](https://pub.dev/packages/material_ui) |
| dynamic_color | 2.1.0 | [pub.dev](https://pub.dev/packages/dynamic_color) |
| file_picker | 13.4.0 | [pub.dev](https://pub.dev/packages/file_picker) |
| flutter_inappwebview | 6.1.5 | [pub.dev](https://pub.dev/packages/flutter_inappwebview) |
| http | 1.6.0 | [pub.dev](https://pub.dev/packages/http) |
| package_info_plus | 10.2.2 | [pub.dev](https://pub.dev/packages/package_info_plus) |
| permission_handler | 13.0.2 | [pub.dev](https://pub.dev/packages/permission_handler) |
| flutter_secure_storage | 11.2.0 | [pub.dev](https://pub.dev/packages/flutter_secure_storage) |
| shared_preferences | 2.5.6 | [pub.dev](https://pub.dev/packages/shared_preferences) |
| path_provider | 2.1.6 | [pub.dev](https://pub.dev/packages/path_provider) |
| qr_flutter | 4.1.0 | [pub.dev](https://pub.dev/packages/qr_flutter) |
| url_launcher | 6.3.3 | [pub.dev](https://pub.dev/packages/url_launcher) |
| flutter_lints | 6.0.0 | [pub.dev](https://pub.dev/packages/flutter_lints) |

未使用的 `cupertino_icons` 已移除。旧 `flutter_launcher_icons` 配置引用了用户已替换的 `assets/playstore.png`，因此移除该生成器依赖和旧配置；当前品牌资源采用仓库内的专用生成流程。新 `SegmerisLight.jpg`、`SegmerisDark.jpg` 与字体、字体许可资源均保留在应用资源声明中。

## Rust 直接依赖

每一项均查询 `https://crates.io/api/v1/crates/<name>`，选择未 yanked 的稳定版本。

| 包 | 本次版本 | 官方来源 |
| --- | --- | --- |
| anyhow | 1.0.104 | [crates.io](https://crates.io/crates/anyhow) |
| flutter_rust_bridge | 2.13.0 | [crates.io](https://crates.io/crates/flutter_rust_bridge) |
| hex | 0.4.3 | [crates.io](https://crates.io/crates/hex) |
| jni | 0.22.4 | [crates.io](https://crates.io/crates/jni) |
| log | 0.4.35 | [crates.io](https://crates.io/crates/log) |
| env_logger | 0.11.11 | [crates.io](https://crates.io/crates/env_logger) |
| regex | 1.13.2 | [crates.io](https://crates.io/crates/regex) |
| nextjson | 0.1.5 | [crates.io](https://crates.io/crates/nextjson) |
| tzcraft | 0.1.2 | [crates.io](https://crates.io/crates/tzcraft) |
| courierust | 1.1.3 | [crates.io](https://crates.io/crates/courierust) |
| webpki-root-certs | 1.0.12 | [crates.io](https://crates.io/crates/webpki-root-certs) |
| rustls | 0.23.46 | [crates.io](https://crates.io/crates/rustls) |
| url | 2.5.8 | [crates.io](https://crates.io/crates/url) |
| dashmap | 6.2.1 | [crates.io](https://crates.io/crates/dashmap) |
| indicatif | 0.18.6 | [crates.io](https://crates.io/crates/indicatif) |
| uuid | 1.29.3 | [crates.io](https://crates.io/crates/uuid) |
| android_logger | 0.15.1 | [crates.io](https://crates.io/crates/android_logger) |
| rustbinary | 0.1.10 | [crates.io](https://crates.io/crates/rustbinary) |
| libfuzzer-sys | 0.4.13 | [crates.io](https://crates.io/crates/libfuzzer-sys) |

`nextjson` 0.1.5 没有 `std` feature，已移除过时的 feature 声明及 core 的 feature 转发。Rust 实现同时适配该版本的错误类型和容器反序列化支持，避免仅改版本号而留下编译错误。

## 构建工具

Flutter Rust 插件直接依赖更新为 `plugin_platform_interface` 2.1.8；开发工具为 `ffi` 2.2.0、`ffigen` 23.0.0、`flutter_lints` 6.0.0。

Cargokit 的直接依赖固定为：`logging` 1.3.0、`path` 1.9.1、`version` 3.0.2、`collection` 1.19.1、`ed25519_edwards` 0.3.2、`hex` 0.2.0、`yaml` 3.1.4、`source_span` 1.10.2、`github` 9.26.0、`args` 2.7.0、`crypto` 3.0.8、`convert` 3.1.2、`http` 1.6.0、`toml` 0.18.0。开发工具为 `lints` 6.1.0、`test` 1.33.0。所有版本均通过同一 pub.dev API 核验。

## 保留的间接依赖约束

应用执行 `flutter pub outdated --json` 后，下列五项的 Current、Upgradable、Resolvable 相同，Latest 更高。它们不能通过当前依赖图合法升级；仓库没有用 `dependency_overrides` 绕过限制。

| 包 | 当前可解析版本 | 官方更高版本 | 原因 |
| --- | --- | --- | --- |
| cross_file | 0.3.5+5 | 0.4.0 | `file_picker` 13.4.0 及平台实现约束为 `^0.3.5+4`。 |
| jni_flutter | 1.0.4+1 | 1.1.0 | 1.1.0 要求 `jni ^1.2.0`；[jni 1.2.0 官方元数据](https://pub.dev/api/packages/jni/versions/1.2.0)标记 `retracted: true`。当前可用稳定 `jni` 为 1.1.2。 |
| material_color_utilities | 0.13.0 | 0.13.1 | Flutter SDK 精确固定 0.13.0。 |
| qr | 3.0.3 | 4.0.1 | `qr_flutter` 4.1.0 约束为 `^3.0.1`。 |
| test_api | 0.7.14 | 0.7.15 | Flutter Test 依赖具体内部实现，SDK 精确固定 0.7.14。 |

Cargo 的同一版本线仍保留 `generic-array` 0.14.7，虽然 0.14.9 已发布。依赖链是 `flutter_rust_bridge_macros → md-5 → digest → crypto-common`；`crypto-common` 0.1.7 明确要求 `generic-array =0.14.7`。这是上游精确约束，不能通过应用层锁文件升级消除。Cargo 还可能同时保留不同主版本的同名依赖，这是各上游的兼容性边界，不代表直接依赖漏升。

## 本次检查

- 主工作区在线 `cargo update` 成功，报告已经选择 Rust 1.89 约束下可解析的最高版本；`cargo update --locked --verbose` 再次确认无锁文件变更，并指出上述 `generic-array` 约束。
- fuzz 在线 `cargo update` 成功，更新 `cc` 至 1.11.2，并锁定当前本地包版本。
- `cargo metadata --locked --no-deps` 确认三个项目 crate 均为 edition 2024、版本 1.1.0。
- 应用、Flutter Rust 插件、Cargokit 均已成功执行 `pub upgrade`。插件的一次 registry socket 错误经重试成功，未降低版本或替换来源。
- Flutter Rust 插件分析通过，无问题；Cargokit 分析没有 error/warning，存在 19 条原有文件头文档注释 lint 信息。升级后的 Cargokit 命令入口已实际编译运行 `--help`，所有子命令正常注册。
- Cargokit `dart pub outdated --json` 返回空列表；应用只剩上表的五个受约束项。

2026-11-19 对应用与 Cargokit 的 Pub 锁文件、主工作区与 fuzz 的 Cargo 锁文件执行了 OSV 批量查询。去重后的 328 个公开包版本没有匹配到已知公告。该查询覆盖锁文件中的第三方包，不涵盖应用逻辑、系统组件或尚未披露的问题。安装包构建、运行时回归、签名及平台测试必须使用这些锁文件继续验证；后续升级也需要重新执行相同检查。

日常复核命令：

```sh
flutter pub outdated
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
cargo update --manifest-path rust/Cargo.toml
cargo test --locked --manifest-path rust/Cargo.toml --workspace --lib
cargo check --locked --manifest-path rust/Cargo.toml --features api-server
```

查看落后依赖时，先用 `cargo tree --invert <包>@<版本>` 或 `flutter pub deps` 找到约束来源，再决定是否升级直接依赖、等待上游修复或迁移 API。不要手工编辑生成的锁文件。
