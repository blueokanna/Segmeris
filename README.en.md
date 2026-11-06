# Segmeris

[简体中文](README.md)

Segmeris is a Flutter video downloader with a Rust engine for media discovery, HTTP transfer and download tasks. It supports HLS, direct media URLs and Bilibili pages, producing MP4 output. Android uses the system MediaCodec and MediaMuxer APIs and exports finished files to shared storage.

## Features

- **HLS / M3U8:** master playlists, separate audio, AES-128, byte ranges and fMP4 initialization sections, with concurrent segment downloads, retries and verified caches.
- **Bilibili:** BV / av links, b23.tv, multipart videos, collections, series and episodes. Quality tiers, previews, subtitles and CDN alternatives come from API responses. Separate video and audio streams download concurrently.
- **Task controls:** pause or resume transfers and copy download URLs. Separate audio and video produce two links. Completed segments and safely resumable file data can be reused.
- **Media processing:** stream copy where possible, encoding when requested or required by the output container. Desktop uses FFmpeg; Android uses MediaMuxer / MediaCodec; iOS uses AVFoundation / VideoToolbox.
- **Authentication:** Bilibili QR login, an embedded authorization browser and custom request headers. Native credentials use platform secure storage; legacy plaintext values are removed after a verified migration.

## Install and build

Published binaries are available from [Releases](https://github.com/blueokanna/FerrisLoadDownloader/releases).

Building requires Flutter, Rust 1.89 or newer and the Flutter toolchain for the target platform. Desktop media processing needs FFmpeg and ffprobe on PATH. Android does not need FFmpeg. Linux secure storage needs a Secret Service implementation and libsecret-1-dev at build time.

    flutter pub get
    flutter run

Cargokit compiles the Rust library during the Flutter build. After changing the Rust API, regenerate bindings with the flutter_rust_bridge_codegen version specified in rust/Cargo.toml:

    flutter_rust_bridge_codegen generate

Courierust is a versioned crates.io dependency. This repository does not maintain a vendor copy. Changes under development must be tested and published from the separate Courierust repository; release builds must remove local Cargo patches and regenerate the lockfile against the published version.

## Use

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
| BYTERANGE | Validates ranges and lengths, including consecutive implicit offsets |
| DISCONTINUITY | Preserves segment boundaries; Android remuxing rebuilds a continuous timeline |
| Live / unfinished EVENT | Rejected explicitly; continuous recording is not implemented |
| SAMPLE-AES / DRM | Unsupported |

Direct files stream to disk in 64 KiB blocks and are not constrained by the 64 MiB metadata memory limit. Servers without Range support transfer from the beginning. Cross-request resumption requires validators such as ETag or Last-Modified. Playlists are limited to 16 MiB; individual buffered resources are limited to 64 MiB.

## Remuxing and Android duration

Quick conversion copies compressed samples without encoding them again. Fragmented MP4 and concatenated MP4 segments need a rebuilt container: raw concatenation is not a finalized movie. Android checks the movie-header duration against media duration and writes duration when publishing to MediaStore. Failed validation prevents a successful export.

Hardware support depends on the device, driver, resolution and codec. The engine probes available backends and falls back where the platform supports it. FFmpeg processes have timeouts, and unverifiable output duration is an error. Gallery display, synchronization and HDR behavior still require testing on the actual Android devices used for release.

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

    flutter analyze
    flutter test
    cd rust
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --features api-server -- -D warnings
    cargo test --workspace --features api-server
    cargo check -p segmeris-core --no-default-features
    # Verify three fMP4 segments using local FFmpeg
    cargo test fmp4_vod_remux_preserves_all_three_segments -- --ignored
    # Android device/emulator: run gradlew connectedDebugAndroidTest from android/
    # Requires nightly and cargo-fuzz
    cargo +nightly fuzz run hls -- -max_total_time=60

Regular tests use local HTTP fixtures and require neither credentials nor public network access. Ignored site tests contact live services and should run separately. Passing tests does not establish coverage of every CDN, media file or device.

Bug reports should include the platform version, processing mode, redacted logs and a reproducible public sample. Do not submit cookies, SESSDATA, API tokens or private signed links.

See [LICENSE](LICENSE). Download only content you are entitled to save.
