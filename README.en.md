# Segmeris 1.0.8 - [简体中文](README.md)

<p align="center">
  <img src="https://raw.githubusercontent.com/blueokanna/Segmeris/main/assets/playstore.png" width="20%" />
</p>

Segmeris is a Flutter video downloader with a Rust engine for media discovery, HTTP transfer and download tasks. It supports HLS, direct media URLs and Bilibili pages, producing MP4 output. Android uses the system MediaCodec and MediaMuxer APIs and exports finished files to shared storage.

## Features

- **HLS / M3U8:** master playlists, separate audio, AES-128, byte ranges and fMP4 initialization sections, with concurrent segment downloads, retries and verified caches.
- **Bilibili:** BV / av links, b23.tv, multipart videos, collections, series and episodes. Quality tiers, previews, subtitles and CDN alternatives come from API responses. Separate video and audio streams download concurrently.
- **Task controls:** pause or resume transfers and copy download URLs. Separate audio and video produce two links. Completed segments and safely resumable file data can be reused.
- **Media processing:** stream copy where possible, encoding when requested or required by the output container. Desktop uses FFmpeg; Android uses MediaMuxer / MediaCodec; iOS uses AVFoundation / VideoToolbox.
- **Authentication:** Bilibili QR login, an embedded authorization browser and custom request headers. Native credentials use platform secure storage; legacy plaintext values are removed after a verified migration.
- **Interface:** Material 3 components, the 2021 typography scale, dynamic colors and AMOLED themes. Download settings expand on demand; narrow screens and large text use a single column, while wide screens keep a bounded content width. Animations respect the system reduced-motion setting.

The application ID is `com.blue.segmeris`. Android package identity, Kotlin namespace, manifest components and Rust JNI class lookup use the same identifier. CI checks both source metadata and the final APK package ID and version. Android is a priority platform: codec capabilities select the hardware path, while emulator tests do not replace validation on vendor devices.

## Install and build

Published binaries are available from [Releases](https://github.com/blueokanna/Segmeris/releases).

Build with Flutter 3.47.9 (Dart 3.13.7), Rust 1.89 or newer and the toolchain for the target platform. Desktop media processing needs FFmpeg and ffprobe on PATH. Android does not need FFmpeg. Linux secure storage needs a Secret Service implementation and libsecret-1-dev at build time.

Android builds use JDK 17, AGP 9.1.1 and Gradle 9.3.1 to read API 37.0 SDK metadata. Foreground services respect system background time limits: the timeout callback stops the service and releases its wake lock. Indefinite background execution is not guaranteed.

On Windows, run `powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1`. The script downloads a pinned NuGet CLI from the official package endpoint, with Microsoft's public .NET feed as a fallback. Downloads have timeouts; SHA-256 and Authenticode signatures are verified. The tool is cached under `build/tools/nuget` and added only to the current process PATH. CI uses the same script, including Windows builds for pull requests.

    flutter pub get --enforce-lockfile
    flutter run

Cargokit compiles the Rust library during the Flutter build. After changing the Rust API, regenerate bindings with the flutter_rust_bridge_codegen version specified in rust/Cargo.toml:

    flutter_rust_bridge_codegen generate

Courierust is pinned to the published crates.io release **1.1.1**, without a vendor copy or local path patch. Commit both `rust/Cargo.lock` and `pubspec.lock`; CI builds against these locks. The app, Rust core and Flutter bridge use **1.0.8**. Third-party dependencies retain their own versions. Release tags must match `v1.0.8`; `scripts/check_versions.py` checks package and tag consistency.

## Use

The theme selector supports mouse dragging, wheel and trackpad scrolling, a visible scrollbar and previous/next buttons on desktop.

1. Paste a media URL or page address. Analyze a page to choose quality, codec and subtitles.
2. Set the filename, directory and download options. A bitrate of 0 requests stream copy; incompatible containers or codecs may still require encoding.
3. Start the task. Its card provides pause, resume and actual stream URLs. Pause is available during transfer, not conversion or export.
4. Android exports to public Downloads. Desktop writes to the selected path. Subtitles are saved as a separate SRT with the same basename.

Pause takes effect at network read boundaries. An outstanding connection or read must first return or time out. If the server closes an idle connection, resuming validates the partial file or requests the current segment again. Copied URLs can expire and may still require the original authorization headers.

Bilibili series are processed in order, resolving each episode when its turn begins. Login exposes only the formats and episodes available to that account. Preview clips are identified explicitly.

## HLS coverage

| Input | Behavior |
| --- | --- |
| Finalized VOD playlist | Downloads through ENDLIST; selects the highest-bandwidth available master variant |
| AES-128 | Decrypts with the declared key and IV; decryption errors fail the task |
| EXT-X-MAP | Caches init sections with their declaration-time keys; each fMP4 part is independently readable |
| BYTERANGE | Checks the Content-Range and actual length of 206 responses, including consecutive implicit offsets |
| DISCONTINUITY | Preserves segment boundaries; Android remuxing rebuilds a continuous timeline |
| Live / unfinished EVENT | Rejected explicitly; continuous recording is not implemented |
| SAMPLE-AES / DRM | Unsupported |

Direct files stream to disk in 64 KiB blocks and are not constrained by the 64 MiB metadata memory limit. Servers without Range support transfer from the beginning. Cross-request resumption requires validators such as ETag or Last-Modified. Playlists are limited to 16 MiB; individual buffered resources are limited to 64 MiB.

Segment failures preserve the underlying error. Requests can retry on 408, 429 and server errors; other 4xx responses fail immediately. Mismatched ranges, missing Content-Range headers and incorrect segment lengths are rejected before entering the verified cache.

## Remuxing and Android duration

Quick conversion copies compressed samples without encoding them again. Fragmented MP4 and concatenated MP4 segments need a rebuilt container: raw concatenation is not a finalized movie. Android checks the movie-header duration against media duration and writes duration when publishing to MediaStore. Failed validation prevents a successful export.

Hardware support depends on the device, driver, resolution and codec. The engine probes available backends and falls back where the platform supports it. FFmpeg processes have timeouts, and unverifiable output duration is an error. Gallery display, synchronization and HDR behavior still require testing on the actual Android devices used for release.

## Hardware encoding

Stream copy preserves the compressed video and does not invoke a hardware encoder. Encoding is used when the requested bitrate or media conversion requires it. Hardware encoding does not accelerate HTTP downloads.

| Platform | Implemented path | Requirements |
| --- | --- | --- |
| Windows / Linux, NVIDIA | FFmpeg `h264_nvenc` | A supported GPU, driver and FFmpeg build |
| Windows / Linux, AMD | FFmpeg `h264_amf`; Linux can also use `h264_vaapi` | A working AMF runtime or VAAPI driver |
| Windows / Linux, Intel | FFmpeg `h264_qsv`; Linux can also use `h264_vaapi` | A working Intel media driver |
| Linux SoCs | FFmpeg `h264_v4l2m2m` | A kernel driver exposing a stateful V4L2 M2M H.264 **encoder**, with access to its `/dev/video*` nodes |
| Linux, Rockchip MPP | FFmpeg `h264_rkmpp` | An FFmpeg build with the MPP encoder, matching MPP libraries and device access |
| Android | Native MediaCodec + MediaMuxer | Firmware exposing compatible H.264 Surface encoding |
| macOS, including Apple silicon | FFmpeg `h264_videotoolbox` | A usable VideoToolbox encoder; software fallback is disabled for the hardware probe |
| iOS / iPadOS | Native AVFoundation + VideoToolbox | H.264 session initialization; hardware selection can be checked on iOS 17.4 and later |
| HarmonyOS NEXT | Not implemented | Requires a separate native application, HarmonyOS SDK integration and device validation |

Android codec selection is not restricted to a vendor whitelist. Amlogic, Allwinner, Qualcomm, Rockchip, MediaTek and Huawei Kirin devices use the codecs their Android-compatible firmware exposes. Android 10 and later provide hardware flags; older versions require codec-name heuristics. Neither is a guarantee that a particular resolution or bitrate works: the pipeline validates capabilities, tries initialization and can fall back to a compatible software encoder. A HarmonyOS device that runs the Android APK uses this Android path; it is not a native HarmonyOS NEXT port.

Linux support is determined by the kernel and userspace API, not the SoC brand. A decoder-only driver, stateless V4L2 decoding interface or vendor SDK such as Rockchip MPP is not interchangeable with V4L2 M2M encoding. MPP encoding is available through an externally supplied FFmpeg build exposing `h264_rkmpp`, such as [ffmpeg-rockchip](https://github.com/nyanmisaka/ffmpeg-rockchip/wiki/Encoder); merely having an MPP decoder is insufficient. Segmeris does not bundle that build or directly link vendor MPP, CedarX or OpenMAX libraries. VAAPI currently uses `/dev/dri/renderD128`. Containers also need explicit device access and matching drivers; the default Docker image does not configure GPU passthrough.

The desktop capability panel lists every encoder that passes a three-frame 720p test, in selection order. Failed probes are shown separately; they can indicate missing hardware, drivers, FFmpeg support, permissions or temporarily busy resources. They do not mean the application only supports the first GPU vendor shown. Android reports advertised capabilities; iOS checks session initialization and reports hardware availability as unknown before iOS 17.4. AVFoundation manages encoder selection for actual iOS exports. These checks do not replace end-to-end tests on the target device. No all-vendor hardware validation is claimed.

Platform references: [Android MediaCodecInfo](https://developer.android.com/reference/android/media/MediaCodecInfo), [Apple hardware encoder selection](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder), [HarmonyOS native video encoding](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/video-encoding/).

An isolated HarmonyOS port was attempted with SDK 26.0.0.105 and the OHOS Flutter 3.47.7 preview. Compilation failed because `material_ui 1.10.0` does not handle `TargetPlatform.ohos`; the current dependencies also lack OHOS implementations for the Rust bridge, secure storage and file selection. Installing the SDK or generating an `ohos` directory does not complete native support. No HAP has passed validation, and OpenHarmony API 11 remains untested.

If the NVIDIA probe reports `Driver does not support the required nvenc API version`, FFmpeg requires a newer NVENC interface than the installed driver exposes. The capability panel preserves the actual error. Update the driver or point `FERRISLOAD_FFMPEG_PATH` at a compatible build; installing newer FFmpeg does not update the driver's API. Intel QSV accepts NV12 software frames and handles upload internally, avoiding texture-pool initialization failures on some drivers.

## Web and Docker API

The web app delegates analysis and downloads to the API; files remain on the server. Configure the server URL and token in Settings. Non-local endpoints require HTTPS. Browser credentials are held only for the current page session.

    docker compose --profile api up -d

| Method | Path | Purpose |
| --- | --- | --- |
| GET | /health | Health check |
| POST | /inspect | Discover media |
| POST | /download | Create a task |
| GET | /status/:id | Query progress |
| GET | /tasks | List tasks |
| POST | /tasks/:id/pause | Pause transfer |
| POST | /tasks/:id/resume | Resume transfer |

See [Docker documentation](DOCKER_README.md) for deployment and request formats.

The API blocks private, loopback, link-local and reserved destinations by default, including IPv4-mapped IPv6. Enforcement covers redirects, segments, keys and init sections and uses the resolved address actually passed to the connection. Set FERRISLOAD_ALLOW_PRIVATE_NETWORKS=1 only for trusted internal sources such as a NAS. Configure FERRISLOAD_API_TOKEN and restrict inbound access for exposed deployments.

TLS certificate validation remains enabled. Managed networks can add PEM / DER trust anchors through SEGMERIS_EXTRA_CA_FILE; multiple filenames use the operating system's path separator.

## Diagnosing network errors

Playlist retrieval and FFmpeg processing are separate stages. Switching to “FFmpeg stream copy” cannot fix an HTTP or TLS failure before the playlist is retrieved. Errors retain the TLS cause chain. Permanent HTTP failures such as 401, 403 and 404 return immediately; 408, 429 and 5xx responses remain retryable.

Inspect a response through the same network implementation without starting Flutter:

```sh
cargo run --manifest-path rust/Cargo.toml --locked --bin http_probe -- "https://example.com/video.m3u8"
```

`http_probe` prints the status, response size, hostname and selected response headers. It does not print cookies, response bodies or URL query parameters. Non-2xx responses produce a failing exit status.

TLS uses Mozilla roots by default. When Courierust cannot anchor a cross-signed chain, the client retries with rustls / WebPKI against the same trust set. Signature, hostname and validity checks stay enabled, and reconnection uses the IP already checked by the address policy. Retired roots are not restored for compatibility. `SEGMERIS_EXTRA_CA_FILE` adds only the trust explicitly configured by the deployment operator.

The `oss-hqwx-video.hqwx.com` issue URL checked on 2026-11-08 returned **HTTP 404 / NoSuchKey**, with `x-oss-cdn-auth: success`. The origin reports that the object does not exist. The client cannot restore it; obtain a current link from the source page. The application preserves this cause and stops the failed playlist request before selecting a transcoding backend.

## Source layout and checks

    lib/src/app/                  Download backends, platform bridge and credentials
    lib/src/home/                 Task state and UI
    rust/src/api/downloader.rs    Pipeline and platform backend coordination
    rust/src/api/downloader/hls.rs HLS resources, decryption, caching and assembly
    rust/src/net/                 Courierust streaming adapter and regression tests
    rust/src/api/downloader/transfer.rs Streaming files, resumption and CDN fallback
    rust/src/download_control.rs  Cooperative task control
    rust/src/media_probe.rs       MP4 structure validation
    rust/src/process.rs           Child process supervision
    rust/src/api/bilibili/        Bilibili API, stream selection and subtitles
    android/app/src/main/kotlin/  Android media processing and storage
    rust/fuzz/                    HLS parser fuzzing

    python scripts/check_versions.py
    flutter analyze
    flutter test
    cd rust
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --features api-server --locked -- -D warnings
    cargo test --workspace --features api-server --locked
    cargo check -p segmeris-core --no-default-features --locked
    # Verify three fMP4 segments using local FFmpeg
    cargo test fmp4_vod_remux_preserves_all_three_segments -- --ignored
    # Android device/emulator: run gradlew connectedDebugAndroidTest from android/
    # Requires nightly and cargo-fuzz
    cargo +nightly fuzz run hls -- -max_total_time=60

Regular tests use local HTTP fixtures and require neither credentials nor public network access. Ignored site tests contact live services and should run separately. Passing tests does not establish coverage of every CDN, media file or device.

Bug reports should include the platform version, processing mode, redacted logs and a reproducible public sample. Do not submit cookies, SESSDATA, API tokens or private signed links.

See [LICENSE](LICENSE). Download only content you are entitled to save.
