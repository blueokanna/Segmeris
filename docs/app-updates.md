# 应用更新

主应用在首页加载时创建 `AppUpdateController`，读取当前安装包的版本号和构建号，然后在后台检查 GitHub Releases。主页和设置页共用同一个控制器。主页只提示可用更新，设置页支持手动检查、查看发行说明和打开匹配当前设备的安装包。

## 版本与资产契约

当前版本由 `PackageInfo.fromPlatform().version` 和 `.buildNumber` 读取。比较遵循 SemVer 数字和预发布标识符优先级，忽略普通 build metadata 的优先级；当发行的语义版本相同且双方都有数值 build number 时，再比较构建号。稳定版可替换本机预发布版；远端 draft、prerelease 和带 SemVer 预发布标识的版本均不提示。

官方 release body 可携带下面的单行机器标记，CI 应从 `pubspec.yaml` 动态生成，版本必须与 tag 一致：

```text
<!-- segmeris-release {"version":"1.1.0","build_number":1} -->
```

无该标记时仍能比较不同语义版本；不会假定相同版本的发行具有更高构建号。该标记不会显示在发行说明卡片中。

资产匹配同时接受 `Segmeris-{suffix}` 和 `Segmeris-{releaseTag}-{suffix}`。优先级如下；任何其他平台或未知 ABI 只提供官方发行页面，不猜测兼容性。

| 进程平台 / ABI | 匹配 suffix（按优先顺序） |
| --- | --- |
| Android arm64 | `android-arm64-v8a.apk` |
| Android arm | `android-armeabi-v7a.apk` |
| Android x64 | `android-x86_64.apk` |
| Windows x64 | `windows-x64-setup.exe`，`windows-x64.zip` |
| Linux x64 | `linux-x64.tar.gz` |
| macOS arm64 | `macos-arm64-unsigned.zip`，`macos-arm64.zip` |
| macOS x64 | `macos-x64-unsigned.zip`，`macos-x64.zip` |

ABI 通过 `dart:ffi` 的 `Abi.current()` 获取；Rosetta 下运行的 x64 应用选择 x64 资产，不能简单根据宿主 OS 推测 CPU。iOS 不提供未签名 IPA 的直接安装链接。资产必须非空、状态为 `uploaded`，URL 中的 tag 和文件名必须一致，重复资产名会使该发行无效。`SHA256SUMS` 的存在是提供直接下载链接的必要条件，不代表本模块已验证其内容。

## 网络、缓存和安全边界

- 唯一网络入口是 `https://api.github.com/repos/blueokanna/Segmeris/releases?per_page=100`，只读取公开数据，固定请求头中没有 Authorization、Cookie 或下载服务凭据。
- 禁止 HTTP 重定向。响应总超时 12 秒，超过 4 MiB 则拒绝；使用 `BytesBuilder` 累积数据。超时、失败与 dispose 均触发 `AbortableRequest` 取消实际连接/响应流。
- 官方页面/下载链接必须是 HTTPS、`github.com`、默认 HTTPS 端口、精确 owner/repo/tag/资产路径，无 userinfo、query 或 fragment。拒绝编码的斜杠、反斜杠、路径穿越。只有用户点击后的 `url_launcher` 调用能够打开链接。
- 成功检查的时间、公开发行元数据和 ETag 保存在 SharedPreferences 的 `segmeris.app_update.success.v1`。自动检查使用 24 小时缓存；缓存里的官方 URL 仍重新校验。ETag 通过 `If-None-Match` 重新校验，304 只在已存在对应缓存时有效。
- 网络错误、非预期 HTTP、无效 JSON、超时均不会写入成功检查时间。存储错误最多等待 2 秒，之后继续网络检查或保留内存成功缓存；未来时间戳和损坏缓存不会永久禁用检查。
- 手动检查绕过 24 小时缓存，但仍遵守 GitHub 的 `Retry-After` / `X-RateLimit-Reset`。403/429 以及成功响应中的剩余额度为零会设置独立 `retry_at`；该字段跨重启保留且不伪装成成功检查。无可用限流头时等待 1 小时；不可信的超长/损坏期限不被永久保存。
- 同时发起的检查共享同一个在途请求。控制器释放后不会发送迟到的通知；控制器拥有并释放服务/HTTP client。
- 每次最多考察 GitHub 返回的最近 100 个发行；它会按版本号选最新稳定版本，而非信任发布时间排序。极端情况下，最新 100 条全部为预发布时不会自动翻页，用户仍可查看仓库发布列表。

## 验证

```text
flutter test --no-pub --timeout 30s test/app/app_update_test.dart
flutter analyze --no-pub lib/src/app/app_update.dart lib/src/app/app_update_widgets.dart lib/src/app/app_update_platform_io.dart lib/src/app/app_update_platform_stub.dart test/app/app_update_test.dart
```

测试使用 fake HTTP、时钟、存储和浏览器 opener，不会访问 GitHub，不会下载或执行安装包。覆盖 SemVer/build、draft/prerelease、安全 URL、无 token、平台 ABI、checksums 门槛、缓存/ETag、HTTP/离线/超时/限流、真实 abort 信号、dispose、主页安静失败、设置重试及仅用户点击后打开下载链接。
