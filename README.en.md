# Segmeris

A cross-platform media downloader with a Flutter UI and a Rust core (bridged via `flutter_rust_bridge`).

It focuses on HLS / M3U8: fetch the playlist, download segments concurrently, decrypt AES-128 streams when needed, merge, and remux/transcode into an MP4 saved wherever you choose. Direct MP4 / WebM / MKV / DASH links work too, and it can pull usable streams out of ordinary web pages, YouTube, and Bilibili. Bilibili goes through the official API (view / playurl with live WBI signing): single videos, multi-part uploads, collections, uploader series and whole bangumi seasons all resolve, and an entire series can be queued for download in order.

> 中文版： [README.md](README.md)

## What it does

- **HLS / M3U8** — master and media playlists, automatic best-variant selection, AES-128-CBC decryption, bounded-concurrency segment downloads with backoff retries, and an automatic single-threaded fallback instead of failing on the first hiccup.
- **Direct download** — paste an `.m3u8` or a media link and hit download; no separate analyze step needed. YouTube / Bilibili page URLs are auto-resolved to a downloadable stream.
- **Optional page analysis** — list candidate streams ranked by resolution/bitrate, then pick one. Pressing download first opens a **quality picker** listing every stream this analysis reached (tier name, official badge, codec, resolution); when the session can only reach a 试看 preview fragment, the picker says so and puts "Open auth browser" right next to it, instead of letting a six-minute file land unnoticed.
- **Native Bilibili support** — no page scraping: the official view / playurl API is used directly (WBI signature computed per request), covering BV/av ids, multi-part uploads, uploader collections, series, bangumi (ep/ss), b23.tv short links and share text. Analysis lists the whole series: pick one episode to download alone, or queue every episode in order. Downloads retain the alternate CDN URLs returned by playurl and automatically try those official mirrors in order if a node fails, without requiring a new analysis (a few official edges — the COS mirrors — speak TLS 1.2 only, omit the RFC 8446 downgrade sentinel when negotiating it, and send a NewSessionTicket before their own ChangeCipherSpec; such nodes are switched to a dedicated TLS 1.2 compatibility connection — TLS 1.2 only, P-256 only — whose handshake implements the RFC 7627 extended master secret and RFC 5077 tickets, so those official mirrors download fine instead of being skipped). Quality tiers and badges (`1080P 高码率` / `4K 超高清` / `大会员` / `60帧`) come from playurl's `support_formats`, tagged with the codec (AVC / HEVC / AV1); signing in (by pasting your browser Cookie) unlocks 1080P 高码率, 1080P 60帧, 4K 超高清, HDR 真彩, Dolby Vision, 8K 超高清 plus Hi-Res lossless / Dolby Atmos audio. Anonymous sessions get the tiers this video offers but the session cannot reach listed by name, instead of a vague "480P only". For membership-gated episodes the API sometimes answers with a six-minute preview fragment (`is_preview`): it is labelled `试看片段 6:01` with a note explaining the gate and the way out, instead of being handed over as if it were the episode — which would just look like a mysteriously short download.
- **Bilibili subtitles** — at download time `x/player/v2` provides the episode's tracks (`lan` / `lan_doc` / `subtitle_url`); the default is the account's own language, then the first track whose label is not auto-generated, and the `.bcc` JSON is converted into a standard SRT saved as `<video name>.srt`. The analysis card lists every track and marks the one that will be saved. Like the streams, the track list is entitlement-scoped (anonymous sessions receive an empty list and are told to sign in), and nothing about the language is inferred or invented.
- **Remux / transcode** — FFmpeg on desktop (auto-detects NVENC / AMF / Intel QSV / VAAPI / VideoToolbox); Android uses the system `MediaCodec` hardware codecs, no FFmpeg required. When the device's MP4 muxer cannot package a codec directly (AV1 / HEVC-only tiers, older systems), the video track is automatically re-encoded to AVC with the hardware encoder and muxed with the untouched audio instead of failing.
- **Multiple concurrent tasks** — while a download runs you can edit the URL or file name and start another independent task.
- **Authorized sessions** — for login-gated sites, provide Cookie / User-Agent / Referer / Origin / custom headers manually or via the built-in authorization browser. It does not bypass Cloudflare, CAPTCHAs, DRM, anti-leech signatures, or rate limits — those shouldn't be bypassed.
- **Bilibili QR sign-in** — log in through Bilibili's own QR flow (`passport-login/web/qrcode`), with no embedded browser involved: scan, confirm on your phone, and the app holds your account's session. A single device is enough too: the dialog can hand the authorization link to that phone's browser instead (see Usage). That is the legitimate route to full episodes and high tiers — afterwards the server issues the tier list your account is entitled to (a membership account adds the `大会员` tiers), and the output is still a standard MP4. Nothing is cracked and nobody else's credentials are used.

## Layout

```
lib/            Flutter UI (Material 3, dynamic color, i18n)
rust/           Rust core
  src/api/      download pipelines (HLS/DASH/direct), site adapters, FFmpeg, Android JNI
  src/api_server/  optional HTTP API (Docker)
  src/crypto/   self-contained AES-128-CBC and SHA-256
  src/hls.rs    self-contained HLS playlist parser (resource-bounded)
  src/net.rs    synchronous HTTP client (courierust engine: TLS 1.2/1.3, Mozilla root set + compatibility anchors + optional extra trust anchors; a non-compliant TLS 1.2 edge without the RFC 8446 downgrade sentinel is retried over a dedicated TLS 1.2 compatibility connection)
  vendor/       vendored courierust (TLS engine patches: RFC 7627 extended master secret, RFC 5077 ticket before ChangeCipherSpec; what and why in vendor/PATCHES.md)
android/        Android host: MediaCodec transcoder, MediaStore export, foreground service
```

## Getting started

```bash
flutter pub get
flutter run
```

The Rust library is compiled automatically by the `rust_builder` package (Cargokit) during the Flutter build.

Desktop transcoding needs `ffmpeg` on `PATH`; Android does not.

### Regenerating FRB bindings (only when you change the Rust API)

```bash
flutter_rust_bridge_codegen generate
```

The codegen version must match `flutter_rust_bridge` in `rust/Cargo.toml` (currently 2.13.0).

## Usage

1. Paste a link into **Source URL**.
   - An `.m3u8` or direct media link can be downloaded immediately.
   - For a web page, run **Analyze** first and pick a candidate, or download directly.
2. Set the **Output file** name and optionally a save directory.
3. Tune **Download options** (concurrency, retries, video/audio bitrate; `0` keeps the source bitrate).
4. Press **Download**. Analyze first if you want to pick from candidates.
5. The saved path is shown and recorded in **History**.

For login-gated sites there are two sign-in routes, and both keep the session on this device so it survives a restart ("Clear session" deletes the stored one):

- **QR login** (Bilibili): the app asks the official passport endpoint for a QR code and you confirm it in the Bilibili app. **One phone is enough**: "Open in browser" in that dialog hands the authorization link to this phone's browser — the one already signed in to Bilibili — where you confirm it, and the app imports the session as soon as its two-second poll sees the confirmation. The link can also be copied elsewhere.
- **Authorization browser**: it opens the site's **sign-in entry** (Bilibili's passport page) rather than the media page, because a media page can render as a blank document inside a WebView without reporting any error. The address bar accepts any address, and "Open in system browser" / "Copy link" are always available, so a WebView that paints nothing is never a dead end.

### Managed networks (private CAs / TLS inspection)

Only the built-in Mozilla root set is trusted by default. When the network performs TLS interception (corporate proxies, some anti-virus products), export the intercepting root as a PEM / DER file and point the program at it:

```bash
SEGMERIS_EXTRA_CA_FILE=/path/to/ca.pem
# separate multiple files with the platform path separator (semicolon on Windows, colon on Unix); unset keeps the default trust set
```

This only adds a trust entry; chain, hostname and validity verification run exactly as before.

### Bilibili series downloads

Paste a video / bangumi / collection link (a link to any single episode inside a collection works too) and press **Analyze**:

- The episode list of the containing series appears above the candidates, labeled with its kind (multi-part video / collection / bangumi / series).
- Tap an episode to switch to it; **Download** then fetches just that one.
- **Download all** queues the whole series in order: each episode is resolved and downloaded one after another, and a failure only affects that episode — retry it individually from its task card.
- Streams are resolved at download time, not at analysis time, so a long queue never fails on expired CDN signatures.
- Candidate names, badges and codecs come from the playurl response itself: `support_formats` provides the official tier names (`1080P 高清` / `1080P 高码率` / `1080P 60帧` / `4K 超高清` / `HDR 真彩` / `杜比视界` / `8K 超高清`) and corner badges (`大会员` / `高码率` / `60帧`), while the DASH manifest provides `codecid` and the RFC 6381 codec string (AVC / HEVC / AV1). When a tier ships several encodings the most compatible one is kept (AVC > HEVC > AV1) and the codec is shown on the card.
- High qualities (1080P 高码率 / 1080P 60帧 / 4K 超高清 / HDR 真彩 / Dolby Vision / 8K 超高清) plus Hi-Res lossless and Dolby Atmos audio follow the account's entitlements: paste your signed-in browser Cookie (SESSDATA at minimum) into the authorization context. The API only returns what the account may actually access; nothing is bypassed, and an anonymous session is told by name which tiers this video offers but the session cannot reach.
- "Anonymous gets no 4K" is not this app's limit: for the same video the API honestly lists `4K 超高清` / `8K 超高清` in `accept_quality` / `support_formats`, while `dash.video` only contains the streams **that session may access** — measured on an anonymous session it is `480P 标清 / 360P 流畅`. Quality is a server-side policy; no client-side parameter changes it, and this project will not impersonate an app with a shared client secret or borrow someone else's credentials. The only legitimate route to high quality is importing your own signed-in Cookie (a membership account adds the `大会员` tiers).
- Why a download can come out six minutes long: a membership/purchase-gated bangumi episode is served to a session **without that entitlement** as a single 试看 preview fragment (the API's own `is_preview` flag — measured on `ep1994063`: a 360-second progressive MP4 with no `dash` object at all). That is not a parsing or quality problem: the same episode returns its full DASH tier list for an entitled account. The fragment is labelled `试看片段 6:01`, the reason is named on the analysis card and in the quality picker, and "Open auth browser" sits next to it; nothing pretends the fragment is the episode, and no membership gate is bypassed.
- Quality picker: pressing download lists every stream this analysis reached (`1080P 高码率` / `4K 超高清` / `HDR 真彩` / `8K 超高清` …, with codec and official badge). The tier list is issued per account entitlement — the same link shows a different list to an anonymous and a signed-in session, and the app reports exactly that list rather than padding or inventing entries. What comes out is still a standard MP4.
- **Download all** opens the same tier picker first, and the picked tier travels to every episode: each one is resolved right before it starts and matched by tier name + codec + protocol, then by tier name, then by the same height, then by the nearest height, then by that episode's best stream. One episode lacking your tier never stalls the queue, and its task card shows the tier that episode **actually** used.
- Episode durations: the bangumi endpoint reports `duration` in **milliseconds** (measured on `ep1994063`: `3120000`, i.e. 52 minutes) while the UGC endpoint reports seconds. The list converts before rendering, so a 52-minute episode is no longer printed as `866:40:00`.
- Subtitles: after a download the engine writes the chosen track next to the video as `<video name>.srt`. The candidates card lets you pick `Auto` (the episode's own default), one concrete track, or `No subtitles`; the track that `Auto` resolves to is marked `Default`, and its priority order is "the account's own language → the first non-auto-generated track → the first track". A **single download** uses the exact URL of the track you picked; **Download all** carries that track's **language** to every episode instead, because an exact URL only belongs to the episode it came from — an episode without that language falls back to its own default track. The track list is entitlement-scoped like the streams (anonymous sessions get an empty list and a sign-in hint), so subtitles need a signed-in session too — there is no switch to bypass that. On Android the `.srt` is exported alongside the video.

## How Android transcoding works

There is no FFmpeg on Android; everything goes through `MediaCodec`:

- **Hardware first for both decode and encode** (codecs are scored by vendor: Qualcomm, MediaTek, HiSilicon, Samsung, …), falling back to a software encoder only when no hardware AVC encoder works.
- **Segment-by-segment HLS** — we no longer byte-concatenate TS segments (their PTS resets at every boundary, which made MediaCodec decode only the first few seconds). Each segment is fed to the decoder independently and the timeline is re-based continuously across segments — the equivalent of FFmpeg's concat demuxer. Re-basing only fires on a real discontinuity (a 500 ms backward jump), never on the ordinary intra-GOP PTS reordering of B-frame streams: rewriting those timestamps is exactly what stretched timelines and halved playback frame rates on B-frame content.
- **Stream-copy remux first** — at bitrate 0 we try a lossless remux into MP4; only fall back to a hardware re-encode when that fails or the output is truncated.
- **A/V sync** — both tracks have to ride one clock. Each track used to be rebased on *its own* first sample, which deletes the offset the source keeps between its tracks (the empty edit plus `media_time` shift of a Bilibili DASH video track, or the few hundred milliseconds a TS audio track starts later); the transcode path was worse, leaving the re-encoded video on source timestamps while the copied audio started at zero. Both tracks now share one origin — the earlier of their two first samples — and a per-segment timestamp discontinuity is measured once by the video pass and reused verbatim by the audio pass, so the two can no longer slide apart. The Rust stream-copy remuxer does the same for HLS TS: it rebuilds the video timeline from a frame grid and counts AAC frames for audio, then writes each track's start as a standard `edts`/`elst` empty edit in `moov`, restoring the source's own A/V offset (measured: a source 478.67 ms apart comes out 479 ms apart — the quantization limit of the 1 ms movie timescale).
- **Self-checking output** — after conversion, `MediaExtractor` / `MediaMetadataRetriever` verify the tracks and duration exist, so a broken "first few seconds only" file never ships. Duration is checked both ways: an output much shorter than the playlist (truncation) or much longer (an encoder that stretched the timeline, e.g. 30 min becoming 60 min) is rejected and retried.
- Encoder bitrate is scaled to resolution, the real frame rate is measured for `KEY_FRAME_RATE` / `KEY_OPERATING_RATE` (passed in frames per second so the codec does not re-time the timeline), and B-frames are disabled to reduce playback stutter. Realtime priority is deliberately not used: this is an offline batch transcode, and realtime priority makes some vendor encoders re-stamp output against the wall clock, stretching the timeline.

## Docker API

The container runs the real downloader (not simulated progress). Endpoints:

- `GET /health`
- `POST /inspect` — analyze a page/direct link and return the candidate streams (used by the Web UI)
- `POST /download` — pass `url`, or specify exact streams via `media_url` / `audio_url`
- `GET /status/:task_id`
- `GET /tasks`

```bash
docker build -f Dockerfile.api -t segmeris-api .
docker run --rm -p 3000:3000 -e DOWNLOAD_DIR=/app/downloads \
  -v $(pwd)/downloads:/app/downloads segmeris-api
```

`api-builder` copies exactly what the Rust build needs: `rust/Cargo.toml`, `rust/Cargo.lock`, `rust/core` and `rust/vendor/courierust` first, to warm the dependency layer, then the whole `rust/` tree with the real sources. Both halves matter — `Cargo.toml` patches `courierust` onto `rust/vendor/courierust`, and `net.rs` compiles `rust/assets/GlobalSign-Root-CA-R1.der` into the binary with `include_bytes!`; without either file the image build fails outright. `.dockerignore` keeps `**/target/` out of the build context.

CI (GitHub Actions) builds and pushes the three-architecture image (`linux/amd64`, `linux/arm64`, `linux/arm/v7`) to GHCR.

## Security & privacy

- Only `http/https` targets; scheme allow-lists at both the network and parsing layers (SSRF / local-file protection).
- Custom request headers are validated against CR/LF injection; the session (Cookie / User-Agent / Referer / Origin / custom headers) is written to the app's private storage so a sign-in survives a restart. The Android manifest sets `allowBackup="false"`, keeping credentials out of cloud backup and device transfer, and "Clear session" deletes them.
- HLS keys and DASH segment URLs are forced to `http/https` as well.
- TLS verification is always on: the courierust stack validates the chain, host name and validity window, trusting the built-in Mozilla root set plus a GlobalSign Root CA R1 compatibility anchor (real chains served by sites like Bilibili reference it). Managed networks add their own root through `SEGMERIS_EXTRA_CA_FILE`; nothing else is relaxed.
- Output file names are sanitized against path traversal.
- Download only content you own or are authorized to access.

## Validation

CI's `validate` job runs exactly this, in this order:

```bash
# The minimum supported Rust version (MSRV 1.88.0) must build too
cd rust
cargo check --workspace --all-targets --locked
cargo check -p segmeris-core --no-default-features --locked
cd ..

# stable: format, lints, tests, packaging
cd rust
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo package -p segmeris-core --locked --allow-dirty
cd ..

flutter analyze
flutter test
```

The public-internet round trips are `#[ignore]`d because they need network access and really download tens to hundreds of MB; run them with:

```bash
cd rust && cargo test --lib -- --ignored --nocapture
```

`m3u8_api_server` — the binary the Docker image runs — is compiled behind the `api-server` feature, which has its own lint entry point:

```bash
cd rust && cargo clippy --workspace --all-targets --features api-server --locked -- -D warnings
```

Android-only code (the JNI bridge) is `cfg`-gated out of the desktop `cargo check`, so cross-check the target directly — that is what catches a `jni` 0.22 upgrade (`EnvUnowned` rewrite) breaking the bridge:

```bash
cd rust
NDK=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/bin
CC_aarch64_linux_android=$NDK/aarch64-linux-android24-clang \
AR_aarch64_linux_android=$NDK/llvm-ar \
cargo check --target aarch64-linux-android --locked
```

`flutter build apk` does not fail when the Rust compile fails: cargokit logs the errors, Gradle carries on and packages the `jniLibs` left by the previous build (reproduced locally with `jni = "0.22.4"` — the compile failed and an APK came out anyway). CI therefore greps the build log for `Cargokit BuildTool failed` / `could not compile` and asserts the APK really embeds `librust_lib_segmeris.so`.

CI also builds the Web artifacts (JS + WASM) and scans Rust / Dart / container dependencies. The iOS job (arm64, unsigned) only runs for `v*` tags — a manual trigger skips it unless `skip_ios` is unchecked — and a skipped or failed iOS / Docker (`skip_docker`) job never blocks a release.

Locally, running `flutter test` or a debug build and then a release build can fail with `package dev.flutter.plugins.integration_test does not exist`: `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` is a build artifact (git-ignored), the debug step wrote it for the dev dependency set, and the release step trusts its timestamp and keeps it. Delete that file and build again — it is regenerated for the release plugin set.

## License

See [LICENSE](LICENSE).
