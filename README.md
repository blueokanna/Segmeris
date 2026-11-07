# Segmeris 1.0.8 - [English](README.en.md)

<p align="center">
  <img src="https://raw.githubusercontent.com/blueokanna/Segmeris/main/assets/playstore.png" width="20%" />
</p>

Segmeris 是一个 Flutter 视频下载器，使用 Rust 处理媒体解析、网络传输和下载任务。支持 HLS、媒体直链与 Bilibili 页面，输出 MP4；Android 通过系统 MediaCodec / MediaMuxer 处理媒体并导出到公共存储。

## 功能

- **HLS / M3U8**：主播放列表、独立音轨、AES-128、字节范围与 fMP4 初始化段；并发下载、失败重试、校验后的分片缓存。
- **Bilibili**：BV / av、b23.tv、多 P、合集、系列与番剧。清晰度、试看片段、字幕和可用 CDN 均来自接口实际响应。分离音视频同时下载，失败时尝试接口提供的备用地址。
- **任务控制**：传输阶段可以暂停、继续并复制下载链接。分离音视频会复制两条链接；已完成分片和可安全续传的文件数据可复用。
- **媒体处理**：优先转封装，按需转码。桌面端使用 FFmpeg；Android 使用 MediaMuxer / MediaCodec；iOS 使用 AVFoundation / VideoToolbox。
- **登录**：支持 Bilibili 扫码、内置授权浏览器和手动请求头。原生客户端通过系统安全存储保存会话，旧版明文凭据在成功迁移后删除。
- **界面**：Material 3 组件、2021 字体排版规范、动态配色与 AMOLED 主题。下载参数按需展开，窄屏与大字体采用单列布局，宽屏限制内容宽度；动画适配系统“减少动画”设置。

## 安装与构建

从 [Releases](https://github.com/blueokanna/Segmeris/releases) 获取已发布版本。

源码构建使用 Flutter 3.47.9（Dart 3.13.7）、Rust 1.89 或更新的 stable，以及目标平台的构建工具链。桌面端请将 FFmpeg 和 ffprobe 放入 PATH；Android 不需要 FFmpeg。Linux 的安全存储还需要 Secret Service，编译时安装 libsecret-1-dev。

Windows 使用 `powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1` 构建。脚本从 NuGet 官方包接口获取固定版本的 CLI，失败时尝试微软公开 .NET 包源；每次下载有超时限制，并验证 SHA-256 与 Authenticode 签名。工具缓存在 `build/tools/nuget`，只修改当前进程的 PATH。CI 与本地使用同一脚本，PR 也会构建 Windows 包。

    flutter pub get --enforce-lockfile
    flutter run

Rust 库由 Cargokit 随 Flutter 构建。修改 Rust 对外接口后，使用与 rust/Cargo.toml 一致的 flutter_rust_bridge_codegen 版本重新生成绑定：

    flutter_rust_bridge_codegen generate

Courierust 固定为 crates.io 发布的 **1.1.1**，仓库不维护 vendor 副本或本机路径补丁。提交 `rust/Cargo.lock` 与 `pubspec.lock`，CI 使用锁文件构建。应用、Rust core 和 Flutter 桥接包统一为 **1.0.8**；第三方依赖保留各自版本。发布标签必须为 `v1.0.8`，`scripts/check_versions.py` 会检查包版本与标签是否一致。

## 使用

1. 粘贴媒体链接或页面地址。页面可先分析，再选择清晰度、编码与字幕。
2. 设置文件名、目录和下载选项。码率设为 0 表示优先保留原始编码；容器不兼容时仍可能需要转码。
3. 开始下载。在任务卡片中暂停、继续或复制实际流地址。转码和导出阶段不提供暂停。
4. Android 完成后导出到公共 Downloads 目录；桌面端写入指定路径。字幕另存为同名 SRT。

暂停在网络读取边界生效；正在等待的连接或读取会先返回或超时。服务器断开暂停中的连接后，继续下载会按校验信息续传或重新请求当前分片。链接可能带有有效期和访问限制，复制链接不等于复制登录权限。

Bilibili 系列按顺序处理，每集开始前重新解析地址。登录只能获得当前账号实际拥有的清晰度和剧集权限；试看片段会明确标注。

## HLS 支持范围

| 项目 | 行为 |
| --- | --- |
| 完整 VOD 播放列表 | 下载至 ENDLIST；主列表选择可用的最高带宽变体 |
| AES-128 | 按密钥和 IV 解密；解密失败终止，不保存为成功产物 |
| EXT-X-MAP | 缓存初始化段；保留声明时的密钥，每个 fMP4 分片可独立读取 |
| BYTERANGE | 核对 206 响应的 Content-Range 和实际长度；支持连续省略偏移的范围 |
| DISCONTINUITY | 保留分段边界；Android 转封装重建连续时间轴 |
| 直播 / EVENT 未结束 | 明确拒绝；目前不提供持续录制 |
| SAMPLE-AES / DRM | 不支持 |

普通大文件以 64 KiB 块写盘，不受元数据读取的 64 MiB 内存上限限制。不支持 Range 的服务器从头传输；跨请求续传需要 ETag 或 Last-Modified 等校验信息。播放列表解析上限为 16 MiB，单个内存资源读取上限为 64 MiB。

分片请求保留底层错误信息。408、429 和服务端错误可重试，其他 4xx 直接失败；收到不匹配的字节区间、缺失的 Content-Range 或错误的分片长度时，不写入成功缓存。

## 转封装与 Android 时长

快速模式复制压缩后的音视频样本，不重新编码。fMP4 与多个 MP4 分片需要重建完整容器，不能把分片拼接结果直接当作最终 MP4。Android 会检查电影头时长与媒体时长，并在 MediaStore 发布时写入时长；检查失败的文件不会作为成功任务导出。

硬件编码能力取决于设备、驱动、分辨率和编码格式。程序会探测可用后端；硬件路径失败时按平台能力回退。FFmpeg 子进程有超时控制，输出时长无法验证时会报错。具体 Android 机型的相册显示、音画同步与 HDR 行为，仍应使用真机媒体样本验收。

## Web 与 Docker API

Web 界面将分析和下载交给 API 服务，文件保存在服务端。设置中配置 API 地址和令牌；非本机服务必须使用 HTTPS。浏览器凭据仅保留在当前页面会话中。

    docker compose --profile api up -d

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | /health | 健康检查 |
| POST | /inspect | 分析媒体 |
| POST | /download | 创建下载 |
| GET | /status/:id | 查询进度 |
| GET | /tasks | 列出任务 |
| POST | /tasks/:id/pause | 暂停传输 |
| POST | /tasks/:id/resume | 继续传输 |

部署与请求格式见 [Docker 文档](DOCKER_README.md)。

API 默认阻止私有、回环、链路本地及保留地址，包括 IPv4 映射 IPv6。检查覆盖重定向、分片、密钥和初始化段，并约束实际连接使用的解析地址。仅在需要访问可信 NAS 等内网来源时启用 FERRISLOAD_ALLOW_PRIVATE_NETWORKS=1。对外部署请配置 FERRISLOAD_API_TOKEN，并限制网络入口。

TLS 保持证书验证。受管控网络可用 SEGMERIS_EXTRA_CA_FILE 指定额外 PEM / DER 根证书；多个路径使用操作系统的路径分隔符。

## 网络错误排查

播放列表下载和 FFmpeg 处理是两个阶段。播放列表尚未取得时，切换“FFmpeg stream copy”不能修复 HTTP 或 TLS 错误。日志会保留 TLS 错误链；HTTP 401、403、404 等确定性失败直接返回，408、429 和 5xx 仍允许重试。

可用同一套网络实现检查响应，不需要启动 Flutter：

```sh
cargo run --manifest-path rust/Cargo.toml --locked --bin http_probe -- "https://example.com/video.m3u8"
```

`http_probe` 输出状态码、响应大小、主机和少量响应头，不输出 Cookie、响应正文或 URL 查询参数。非 2xx 响应以失败退出。

TLS 默认使用 Mozilla 根证书。Courierust 无法锚定交叉签名链时，客户端以相同信任集重新执行 rustls / WebPKI 验证；仍检查签名、主机名和有效期，重连使用已经通过地址策略的 IP。不会通过关闭验证或恢复已退役根证书解决兼容问题。`SEGMERIS_EXTRA_CA_FILE` 仅用于部署方明确配置的额外信任。

2026-11-08 复核的 `oss-hqwx-video.hqwx.com` issue 链接返回 **HTTP 404 / NoSuchKey**，响应头显示 `x-oss-cdn-auth: success`。源站报告对象不存在；客户端不能恢复这个对象，需要从原页面取得当前有效链接。程序会保留该错误原因，并在选择转码后端之前终止失败的播放列表请求。

## 工程与验证

    lib/src/app/                  下载后端、平台桥接、设置与凭据
    lib/src/home/                 任务状态与界面
    rust/src/api/downloader.rs    下载流程与平台后端调度
    rust/src/api/downloader/hls.rs HLS 资源、解密、缓存与合并
    rust/src/api/downloader/transfer.rs 流式写盘、续传与 CDN 回退
    rust/src/net/                 Courierust 流式传输适配与回归测试
    rust/src/download_control.rs  任务暂停控制
    rust/src/media_probe.rs       MP4 结构检查
    rust/src/process.rs           子进程监督与超时
    rust/src/api/bilibili/        Bilibili 接口、流选择与字幕
    android/app/src/main/kotlin/  Android 媒体处理与公共存储
    rust/fuzz/                    HLS 解析器模糊测试

    python scripts/check_versions.py
    flutter analyze
    flutter test
    cd rust
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --features api-server --locked -- -D warnings
    cargo test --workspace --features api-server --locked
    cargo check -p segmeris-core --no-default-features --locked
    # 使用本机 FFmpeg 验证三段 fMP4 的完整时长
    cargo test fmp4_vod_remux_preserves_all_three_segments -- --ignored
    # Android 真机或模拟器：在 android 目录运行 gradlew connectedDebugAndroidTest
    # 需要 nightly 与 cargo-fuzz
    cargo +nightly fuzz run hls -- -max_total_time=60

常规测试使用本地 HTTP 服务，不需要登录或访问公网。标记 ignored 的站点测试会访问真实服务，应单独运行；通过单元测试不代表所有 CDN、视频和设备都已覆盖。

提交问题时请提供平台版本、处理模式、脱敏日志和可复现的公开样本。不要提交 Cookie、SESSDATA、API Token 或带私人授权的链接。

许可证见 [LICENSE](LICENSE)。请只下载有权保存的内容。
