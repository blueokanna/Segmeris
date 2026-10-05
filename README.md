# Segmeris

一个用 Flutter 写的跨平台视频下载器，核心下载与转码逻辑在 Rust 里（通过 `flutter_rust_bridge` 桥接）。

主打 HLS / M3U8 下载：拉取播放列表、并发抓段、AES-128 解密、合并、转封装成 MP4 存到你指定的位置。也能直接下 MP4 / WebM / MKV / DASH 直链，并支持从普通网页、YouTube、Bilibili 页面里自动找出可用的媒体流。B 站走官方 API 直连（view / playurl，WBI 签名随请求实时计算）：单个视频、多 P、UP 合集、系列、番剧整季都能解析，整个系列可以按顺序排队下载。

> 英文版： [README.en.md](README.en.md)

## 它能做什么

- **M3U8 / HLS**：支持主/媒体播放列表、自动选择最高清晰度的变体、AES-128-CBC 解密、带退避重试的并发分片下载。并发失败会自动降级为单线程重试，而不是直接报错。
- **直链下载**：粘贴一个 `.m3u8` 或媒体直链，直接下载，无需先"分析"。粘贴 YouTube / Bilibili 页面地址也会自动解析出可下载的流。
- **页面分析**：可选地先分析网页，列出候选流并按清晰度/码率排序，再选一个下载。
- **Bilibili 原生支持**：不经网页抓取，直接用 view / playurl 接口解析（WBI 签名实时计算），支持 BV/av、多 P 选段、合集（ugc_season）、UP 系列、番剧（ep/ss）、b23.tv 短链和分享文本。分析页会把整个系列列出来：点选某一集单独下，或一键把整季排进下载队列。下载时保留 playurl 返回的备用 CDN 地址；当前节点失败会自动按顺序切换到官方提供的镜像，不需要重新分析（少数官方边缘，如 COS 镜像，只支持 TLS 1.2 且协商时不带 RFC 8446 的降级哨兵、并会在自己的 ChangeCipherSpec 之前先发一个 NewSessionTicket：这类节点会自动切换到专用 TLS 1.2 兼容连接（只报 TLS 1.2、只报 P-256），握手侧实现 RFC 7627 扩展主密钥与 RFC 5077 票据，因此这些官方镜像照样能下，不需要跳过）。清晰度档位与角标（`1080P 高码率` / `4K 超高清` / `大会员` / `60帧`）直接取自 playurl 的 `support_formats`，并标注编码（AVC / HEVC / AV1）；登录后（填入浏览器 Cookie）解锁 1080P 高码率、1080P 60帧、4K 超高清、HDR 真彩、杜比视界、8K 超高清和 Hi-Res 无损 / 杜比全景声音轨。未登录时界面会点名列出这条视频本来提供、但当前会话拿不到的那些清晰度，而不是含糊地只说"只能 480P"。番剧里需要会员/购买的集数，接口有时会回一个六分钟的试看片段（响应里的 `is_preview`）：程序把它如实标成 `试看片段 6:01` 并附一条说明原因与出路的提示，而不是把它当整集交给你——否则你只会拿到一段莫名其妙的短视频。
- **Bilibili 字幕**：下载时通过 `x/player/v2` 取该集字幕轨（`lan` / `lan_doc` / `subtitle_url`），默认选账号当前语言、其次非"自动生成"的那条，把 `.bcc` JSON 转成标准 SRT 存成与视频同名的 `.srt`；分析页会列出该集所有字幕轨并标出将被保存的那条。字幕列表与清晰度同样是服务端按权益下发的（匿名返回空列表，界面会提示登录），程序不猜测、不伪造语言。
- **转封装 / 转码**：桌面端用 FFmpeg（自动探测 NVENC / AMF / Intel QSV / VAAPI / VideoToolbox）；Android 端用系统 `MediaCodec` 硬件编解码，不依赖 FFmpeg。设备自带的 MP4 muxer 若无法直接封装某档编码（例如只提供 AV1 / HEVC 的档位、或旧系统不支持该编码的封装），会自动用硬件编码器把视频轨重编为 AVC 再与原始音轨封装，而不是直接报错。
- **多任务**：下载进行中你可以继续改地址、改文件名再开一个新任务，互不干扰。
- **授权会话**：有些站点需要登录才能下。你可以手动填入 Cookie / User-Agent / Referer / Origin / 自定义请求头，也可以打开内置浏览器登录后一键导入。程序不会绕过 Cloudflare、验证码、DRM、防盗链签名或限流——这些限制本身就不该被绕。

## 工程结构

```
lib/            Flutter 界面（Material 3，动态取色，多语言）
rust/           Rust 核心
  src/api/      下载管线（HLS/DASH/直链）、站点适配、FFmpeg、Android JNI
  src/api_server/ 可选的 HTTP API 服务（Docker）
  src/crypto/   自研 AES-128-CBC 与 SHA-256（依赖标准库）
  src/hls.rs    自研 HLS 播放列表解析器（带资源上限）
  src/net.rs    同步 HTTP 客户端（courierust 引擎：TLS 1.2/1.3、Mozilla 根证书集 + 兼容锚点 + 可选额外信任锚；对缺少 RFC 8446 降级哨兵的不合规 TLS 1.2 边缘节点自动改用专用 TLS 1.2 兼容连接重试）
  vendor/       vendored courierust（TLS 引擎补丁：RFC 7627 扩展主密钥、ChangeCipherSpec 之前的 RFC 5077 票据；改了什么、为什么改见 vendor/PATCHES.md）
android/        Android 宿主：MediaCodec 转码器、MediaStore 导出、前台服务
```

## 快速开始

```bash
flutter pub get
flutter run
```

Rust 库由 `rust_builder`（Cargokit）在 Flutter 构建时自动编译，一般不需要手动干预。

桌面端转码需要 FFmpeg 在 `PATH` 里；Android 不需要。

### 重新生成 FRB 绑定（仅在改动 Rust API 时需要）

```bash
flutter_rust_bridge_codegen generate
```

要求 codegen 版本与 `rust/Cargo.toml` 里的 `flutter_rust_bridge` 一致（目前为 2.13.0）。

## 使用

1. 把链接粘贴到「资源地址」。
   - `.m3u8` 或媒体直链：直接点下载。
   - 网页地址：可以先「分析」，选好候选流再下载。
2. 填「输出文件」名，可选指定保存目录。
3. 「下载选项」里可调并发数、重试次数、视频/音频码率（0 = 保持源码率）。
4. 点「下载」。想先看候选就点「分析」。
5. 完成后会显示保存路径并记入历史。

需要登录的站点：打开设置里的授权浏览器，自己完成登录后导入会话，后续分析与下载都会复用这个授权上下文。

### 受管控网络（私有 CA / TLS 拦截）

默认只信任内置的 Mozilla 根证书集。若网络环境会做 TLS 拦截（企业代理、部分杀毒软件），把拦截方的根证书导出为 PEM / DER 文件，用环境变量告诉程序额外信任它：

```bash
SEGMERIS_EXTRA_CA_FILE=/path/to/ca.pem
# 多个文件用系统路径分隔符连接（Windows 用分号，Unix 用冒号）；不设置时信任集不变
```

这只是一个信任入口，不改变任何校验逻辑：证书链、主机名、有效期检查照常执行。

### Bilibili 系列下载

粘贴视频 / 番剧 / 合集（合集里任意一集的链接也可以），点「分析」：

- 结果顶部会出现该链接所属的剧集列表，并标明类型（多 P 视频 / 合集 / 番剧 / 系列）。
- 点列表里的某一集即可切换到该集；此时点「下载」只下这一集。
- 点「下载全部」会把整个系列按顺序排进任务队列：逐集解析、逐集下载、逐集导出；某一集失败只影响该集，可在任务卡片里单独重试。
- 每一集都会在开始下载时才解析播放地址，长时间批量下载不会因为 CDN 签名过期而中途失败。
- 候选列表里的清晰度名称、角标和编码来自 playurl 响应本身：`support_formats` 给出官方档位名（`1080P 高清` / `1080P 高码率` / `1080P 60帧` / `4K 超高清` / `HDR 真彩` / `杜比视界` / `8K 超高清`）与角标（`大会员` / `高码率` / `60帧`），DASH 流给出 `codecid` 与 RFC 6381 编码串（AVC / HEVC / AV1）。同一档位有多个编码时保留兼容性最好的那个（AVC > HEVC > AV1），并在卡片上标出编码。
- 高清档位（1080P 高码率 / 1080P 60帧 / 4K 超高清 / HDR 真彩 / 杜比视界 / 8K 超高清）以及 Hi-Res 无损、杜比全景声音轨需要账号权限：在授权上下文里填入自己浏览器登录后的 Cookie（至少含 SESSDATA）。接口只返回账号实际有权限的档位，这里不做任何绕过；未登录时界面会点名列出这条视频本来提供、但当前会话拿不到的那些清晰度。
- 为什么"匿名拿不到 4K"不是本程序的限制：同一条视频，接口的 `accept_quality` / `support_formats` 会照实列出 `4K 超高清`、`8K 超高清`，但 `dash.video` 只包含该会话**有权访问**的流——实测匿名会话拿到的是 `480P 标清 / 360P 流畅` 两条。清晰度是服务端策略，客户端再怎么改参数也拿不到；本项目也不会去用共享的客户端密钥或他人凭据冒充身份。想拿高清，唯一正路是导入自己的登录 Cookie（大会员账号再解锁 `大会员` 档位）。
- 字幕：下载完成后，引擎会把字幕写成与视频同名的 `.srt`（`<视频名>.srt`）。分析卡片上可以直接选：`自动`（按本集默认轨）、某一具体字幕轨、或 `不下载字幕`。默认轨的选择顺序是"账号当前语言 → 非自动生成 → 列表第一条"，界面会在默认轨上标 `默认`。**单个下载**按你选中的那条轨的 URL 精确取；**「下载全部」**则把你选的那条轨的**语言**带到每一集（精确 URL 只属于它来自的那一集，换集就失效），哪一集没有该语言就回落到它自己的默认轨。字幕列表按权益下发：匿名返回空列表（界面提示登录）——所以字幕和 4K 一样，登录是前提而不是可绕过的开关。Android 上视频导出到下载目录时，`.srt` 会跟着一起导出。

## Android 转码说明

Android 端没有 FFmpeg，转码完全靠系统 `MediaCodec`：

- **解码/编码都优先硬件**（按厂商名评分：高通、联发科、海思、三星等），没有可用硬件编码器时才回退软件编码器。
- **HLS 逐段处理**：不再把 TS 字节硬拼成一个文件（那样每段的时间戳会重置，导致 MediaCodec 只解出前几秒）。现在把每一段独立喂给解码器，跨段连续重建时间戳，等价于 FFmpeg 的 concat demuxer。重建只在真正的时间戳断层（回退超过 500ms）时触发，绝不碰带 B 帧流里 GOP 内部正常的回摆——把那些回摆当断层重写，正是时间轴被拉长、播放帧率减半的元凶。
- **纯转封装优先**：码率为 0 时先尝试无损 remux（视频/音频直接搬进 MP4）；失败或时长被截断时才做硬件重编码。
- **输出自检**：转完会用 `MediaExtractor` / `MediaMetadataRetriever` 验证轨道存在、时长达标，不产出"只有前几秒"的废文件。时长双向校验：明显短于播放列表（截断）或明显长于播放列表（编码器把时间轴拉长，例如 30 分钟变 60 分钟）都会判失败并重试。
- 编码器按分辨率自适应默认码率、实测帧率设 `KEY_FRAME_RATE` / `KEY_OPERATING_RATE`（按帧/秒传入，避免编码器重排时间轴）、无 B 帧，尽量减少播放时的卡顿；不用实时优先级（离线批量转码按实时喂帧反而会让部分厂商编码器按墙钟重打时间戳）。

## iOS 转码说明（Apple A / M 系列硬件）

iOS 没有 FFmpeg、也没有软件 H.264 编码器，转码走原生 `AVFoundation` / `VideoToolbox`（`ios/Runner/VideoToolboxBridge.m`）：

- **AVAssetWriter + H.264 自动使用硬件编码器**——A 系列（iPhone/iPad）和 M 系列（Mac）芯片都会命中 VideoToolbox，这是 iOS 上"正确调用硬件"的唯一途径。
- **旋转保留**：输出带上 `preferredTransform`，竖屏素材不会被横过来。
- **音频处理**：AAC 直接 passthrough（不重编码）；非 AAC 自动转 AAC，保证 MP4 兼容。
- **时长自检**：转码/合并后对照 HLS 期望时长校验，截断立即报错而不是产出废文件。
- **超时兜底**：Rust 侧用 `ios_videotoolbox_timeout` 做墙钟上限，原生侧内部也有有界等待，硬件挂起不会卡死下载。

桌面端（Windows/macOS/Linux x86 与 Apple Silicon）仍由 FFmpeg 驱动：自动探测 NVENC / AMF / QSV / VAAPI / VideoToolbox，探测失败回退 CPU libx264。

## Web / WASM

浏览器里跑不了 Rust 引擎，所以 Web 版把下载/分析交给 **Segmeris API 服务**（即 Docker 镜像里的同一个服务器）：

```bash
# 本地起 API 服务（多架构：amd64 / arm64 / armv7）
docker compose --profile api up -d
```

- 构建：`flutter build web --release`（JS）或 `flutter build web --release --wasm`（WASM）。
- 网页端在「设置」里填入 API 地址（默认 `http://localhost:3000`）；非本机地址强制要求 `https`，避免会话凭据明文传输。
- 分析（`POST /inspect`）、下载（`POST /download` + 轮询 `GET /status/:id`）与原生端共用同一套引擎，界面一致。

## Docker API

容器里跑的是真正的下载器（不是模拟进度）。接口：

- `GET /health`
- `POST /inspect`（返回页面/直链的候选流列表，Web 端分析用）
- `POST /download`（可直接给 `url`，或给 `media_url` / `audio_url` 指定精确流）
- `GET /status/:task_id`
- `GET /tasks`

```bash
docker build -f Dockerfile.api -t segmeris-api .
docker run --rm -p 3000:3000 -e DOWNLOAD_DIR=/app/downloads \
  -v $(pwd)/downloads:/app/downloads segmeris-api
```

**API 安全（默认开启）**：

- **SSRF 防护**：API 是网络暴露面，默认拒绝会解析到内网/回环/链路本地地址的目标（云元数据端点、Docker 内网、宿主机 loopback 都挡在门外）。确有需要（如从 NAS 下载）时设 `FERRISLOAD_ALLOW_PRIVATE_NETWORKS=1`。
- **可选 Bearer 鉴权**：设 `FERRISLOAD_API_TOKEN=xxx` 后，除 `GET /health` 外的所有端点都要求 `Authorization: Bearer xxx`，防止公开端口被当成开放下载代理。Web 端在设置里填入同样的令牌即可。
- 非 root 运行、HEALTHCHECK、TLS 校验、路径穿越消毒、请求体上限等保持不变。

CI（GitHub Actions）会构建并推送 `linux/amd64`、`linux/arm64`、`linux/arm/v7` 三架构镜像到 GHCR。

## 安全与隐私

- 只允许 `http/https` 目标，网络层与解析层都有 scheme 白名单（防 SSRF / 本地文件读取）。
- 自定义请求头做了 CR/LF 注入校验；Cookie 等凭据只在内存里，不落盘。
- HLS 密钥、DASH 片段 URL 同样强制 `http/https`。
- TLS 校验默认全开：courierust 自研 TLS 栈对证书链、主机名、有效期逐项校验，信任集是内置 Mozilla 根证书 + GlobalSign Root CA R1 兼容锚点（B 站等站点的实际下发链会引用它）；受管控网络用 `SEGMERIS_EXTRA_CA_FILE` 追加自己的根证书，除此之外不放宽任何校验。
- 输出文件名做了路径穿越消毒。
- Web 端把会话凭据转给 API 服务时，非本机地址强制 HTTPS（`ApiDownloadEngine` 传输安全校验）。
- CI 每天/每次提交跑安全扫描：`cargo audit`（Rust 漏洞）、`flutter pub outdated`（Dart 依赖）、Trivy（容器漏洞 + 密钥 + 配置错误）。
- 请只下载你拥有或已获授权的资源。

## 验证

```bash
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml
cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets --locked -- -D warnings
```

CI 还会构建 Web（JS + WASM）等跨平台产物，并对 Rust/Dart/容器依赖做安全扫描。iOS（arm64，未签名）只在推送 `v*` tag 发版时构建，手动触发默认跳过（取消勾选 `skip_ios` 可构建）；iOS 或 Docker（`skip_docker`）被跳过 / 失败时都不会阻塞 Release 发布。

## License

见 [LICENSE](LICENSE)。
