# 构建与发布

发布入口是 `.github/workflows/release.yml`。工作流锁定构建提交，检查签名和运行时依赖，生成清单，将产物上传到草稿，核对每个上传结果后才公开 GitHub Release。

## 触发规则

| 事件 | 行为 |
| --- | --- |
| 推送 `main` | 版本、身份、Rust/Flutter 测试、安全扫描、API 容器构建与健康检查 |
| Pull request | 同上，额外验证 Windows release bundle；不使用发布签名或发布权限 |
| 推送 `testchain` | 构建所有应用产物供 Actions 下载；不创建 Release |
| 推送 `vMAJOR.MINOR.PATCH` | 构建所有应用、发布容器、公开完整 Release |
| 手动运行，不填 `tag_name` | 构建产物，不创建 Release |
| 手动运行，填写 `tag_name` | 标签已存在时须指向所选提交。标签缺失时，所有计划内检查和构建通过后，工作流在该提交上创建标签。可以跳过 iOS 归档或容器发布 |

`prepare` 记录实际提交 SHA，其余任务都 checkout 同一个 SHA。发布前还会重新核对远端标签，避免构建期间标签被移动。`pubspec.yaml`、Rust、本地桥接包及平台版本必须一致，标签必须等于 `v<应用版本>`；校验由 `scripts/check_versions.py` 和 `scripts/release.py` 执行。

每次版本发布应更新 `pubspec.yaml` 的版本与正整数构建号，并同步第一方包、平台版本及 lockfile。提交推送后，可在 **Actions → Validate, build and release → Run workflow** 选择分支并填写 `tag_name`，例如 `v1.1.0`。工作流使用仓库的 `GITHUB_TOKEN` 创建缺失标签，避免再次触发标签推送工作流。不要为同一版本覆盖既有公开 Release 或移动标签。

## Android 签名

在仓库 **Settings → Secrets and variables → Actions** 配置以下四个 secrets：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 正式 JKS/PKCS12 keystore 文件的 Base64 |
| `ANDROID_KEY_ALIAS` | 正式签名密钥 alias |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |
| `ANDROID_STORE_PASSWORD` | keystore 密码 |

缺少任何一个值时，Android 打包任务明确失败。CI 不会把调试证书签出的 APK 当作正式安装包。`release_android.py` 生成 Java Properties 时正确转义密码中的换行、反斜杠和 Unicode；证书验证用环境变量传密码，不在命令行或日志中输出密码。无论构建成功或失败，任务最后都会清理临时 keystore 和配置。

每个 APK 必须通过应用 ID、`versionName`、`versionCode`、非 debuggable、签名证书指纹、Rust/Flutter 原生库、ABI 和 16 KiB 对齐检查。从 1.1.0 起，各 ABI 使用同一构建号，起点 5001 高于 1.0.8 拆分 APK 的最高构建号 4001。后续更新须继续递增。正式签名密钥应长期保留；更换密钥会影响用户覆盖安装现有应用。

## 产物契约

| 文件名 | 内容与安装边界 |
| --- | --- |
| `Segmeris-android-arm64-v8a.apk` | 正式签名的 Android arm64 安装包 |
| `Segmeris-android-armeabi-v7a.apk` | 正式签名的 Android ARM 32 位安装包 |
| `Segmeris-android-x86_64.apk` | 正式签名的 Android x64 安装包 |
| `Segmeris-windows-x64-setup.exe` | 当前用户安装器，提供开始菜单入口与卸载。CI 静默安装后核对主程序和运行库的哈希，然后执行卸载。 |
| `Segmeris-windows-x64.zip` | Windows x64 便携目录，包含 Flutter、Rust、插件、VC++ runtime DLL 和 Microsoft 签名的 WebView2 安装引导程序；解压整个目录运行 |
| `Segmeris-linux-x64.tar.gz` | Ubuntu 22.04 上构建的 x64 应用目录，包含 Flutter/Rust/插件及非系统动态库；系统依赖清单随包附带 |
| `Segmeris-macos-x64.zip` | Intel macOS `.app`，未使用 Developer ID 分发签名或公证 |
| `Segmeris-macos-arm64.zip` | Apple Silicon macOS `.app`，未使用 Developer ID 分发签名或公证 |
| `Segmeris-web-js.zip` | 浏览器 JavaScript 部署目录；下载依赖另行部署的 Segmeris API |
| `Segmeris-web-wasm.zip` | 浏览器 WebAssembly 部署目录；需支持相应运行时的浏览器和 Segmeris API |
| `Segmeris-ios-arm64-unsigned.ipa` | 可选的未签名 `Payload/*.app` 归档；需要合法 Apple 签名身份与 provisioning profile 后才能安装 |

Windows 安装器与主程序当前未使用 Authenticode 分发证书。WebView2 引导程序需要联网，离线部署应另行取得 Microsoft 官方离线运行时。Linux 包不是 `.deb`，仍需要 GTK3、glibc、系统图形驱动和 Secret Service；详细依赖记录在包内 `SYSTEM-DEPENDENCIES.txt`。Windows 和 Linux 发布任务从锁定的 FFmpeg 与 x264 源码构建 FFmpeg/ffprobe，随包附上源码、许可证和构建参数。macOS 用户另行安装媒体工具。需要 yt-dlp 的站点依赖外部安装。

macOS 和 iOS 构建会验证包 ID、版本、Flutter framework、Rust FFI 符号及 Mach-O 架构。上述检查不等于 Apple 分发签名、公证或设备实测；Release 说明会明确保留这些安装边界。

Android CI 使用签名后的 x86_64 APK，在一次性 Android 35 模拟器中分别以亮色和暗色冷启动，并等待首页设置按钮出现在无障碍树中。

Windows 和 Linux CI 还会通过真实打包后的 Rust 动态库运行 `test/native_runtime_test.dart`，验证 Dart→Rust 的 FFI 流错误传播，防止只打包 UI 而遗漏原生引擎。

## 发布完整性与权限

普通任务只有 `contents: read`。`release-gate` 和最终 Release 任务获得 `contents: write`，分别用于创建手动请求的新标签和发布 Release。容器发布任务获得 `packages: write`。所有 checkout 禁止持久化凭据，发布 API 只向 GitHub 官方 API 域发送 token，拒绝重定向。用户输入先通过严格版本格式和提交检查，不拼进 shell 代码。

`release-gate` 要求所有计划内任务成功。失败、取消或意外跳过都会阻止公开 Release；手动明确跳过的 iOS/容器任务有单独的预期状态。产物收集只接受精确的文件名集合，拒绝重复、缺失、额外文件、空文件和符号链接，避免把密钥或其他工作目录内容上传。

最终 Release 包含：

- 所有计划内的应用归档/APK。
- `release-manifest.json`：实际版本、构建号、文件名、字节数及 SHA-256。
- `SHA256SUMS`：每个应用产物和 manifest 的校验和。

上传使用文件流，避免把整个安装包读入内存。上传后核对 GitHub 返回的文件大小；GitHub 返回 digest 时还核对 SHA-256。所有文件确认成功后，才把草稿改为公开。上传中途失败会留下未公开草稿供维护者检查；脚本拒绝覆盖任何已有同标签 Release，重试前应核对并移除失败草稿，或发布一个新的版本。不要删除已经被用户下载的正式版本来覆盖内容。

自动更新读取 Release body 中机器可读的 `segmeris-release` 版本/构建号标记。标记由实际 `pubspec.yaml` 生成；完整协议和更新检查边界见 [app-updates.md](app-updates.md)。

## 工作流验证

本地可执行：

```text
python scripts/check_versions.py
python scripts/check_app_identity.py
python -m unittest discover -s scripts/tests -p 'test_*.py'
actionlint .github/workflows/release.yml
flutter test --no-pub test/app/app_update_test.dart
```

发布测试覆盖版本/标签约束、任务状态 gate、产物缺失与重复、文件篡改、正式证书要求、APK metadata、草稿上传失败以及公开发布顺序。它们不代替 GitHub 的实际跨平台编译、证书配置、商店审核或真机安装测试。

工作流使用核实过的官方 action 版本对应的完整提交 SHA，避免浮动标签改变既有发布流程。核实入口包括 [checkout releases](https://github.com/actions/checkout/releases)、[upload-artifact releases](https://github.com/actions/upload-artifact/releases)、[download-artifact releases](https://github.com/actions/download-artifact/releases)、[setup-java releases](https://github.com/actions/setup-java/releases) 和 [Flutter action releases](https://github.com/subosito/flutter-action/releases)。Runner 标签采用 [GitHub 官方托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)；Flutter 版本与仓库实际验证的 SDK 一致，升级依赖后应重新完成对应平台构建。
