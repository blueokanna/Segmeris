//! Bilibili API client: request signing, response parsing, and error
//! classification.
//!
//! Every request goes through [`BilibiliApi::get_json`] with the shared
//! browser-grade header set (User-Agent / Referer / optional Cookie from
//! the user's request context), so passing an authorized session is a
//! pure configuration concern.
//!
//! Response *shapes* live in typed structs ([`VideoView`], [`DashStreams`],
//! …); the `parse_*` functions are network-free and unit tested against
//! captured payload shapes.

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use log::debug;
use nextjson::Value;

use crate::api::downloader::RequestContext;
use crate::net::SyncHttpClient;

use super::subtitle::{self, SubtitleList};
use super::url::{CollectionKind, Target};
use super::wbi;

const API_BASE: &str = "https://api.bilibili.com";
/// `fnval=4048` asks for DASH with everything layered on: HDR, 4K, Dolby
/// audio, Dolby Vision, 8K and AV1 (bits 16|64|128|256|512|1024|2048).
/// The server still only returns what the account may access.
const FNVAL: i64 = 4048;
/// `qn=127` requests the highest possible quality.
const QN: i64 = 127;
/// WBI keys rotate daily; refresh well inside that window. A stale key
/// only costs one failed signature, so a conservative TTL is fine.
const WBI_KEY_TTL: Duration = Duration::from_secs(30 * 60);
const MAX_REDIRECT_HOPS: usize = 6;
/// Safety ceiling for collection listings: 40 pages × 30 entries.
const MAX_COLLECTION_PAGE_SIZE: usize = 30;
const MAX_COLLECTION_PAGES: usize = 40;

/// An access denial that logging in (a valid Cookie) can plausibly fix:
/// risk control, missing permissions, membership-only content, region
/// restrictions. The inspection pipeline turns this into the "authorize
/// in browser" flow instead of a dead-end error.
#[derive(Debug)]
pub(crate) struct BilibiliAccessError(pub String);

impl std::fmt::Display for BilibiliAccessError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for BilibiliAccessError {}

/// A parsed view (metadata + part list + optional collection membership).
#[derive(Clone, Debug)]
pub(crate) struct VideoView {
    pub bvid: String,
    pub title: String,
    pub cid: i64,
    pub pages: Vec<VideoPage>,
    pub season: Option<UgcSeason>,
}

#[derive(Clone, Debug)]
pub(crate) struct VideoPage {
    pub cid: i64,
    pub page: u32,
    pub title: String,
    pub duration: f64,
}

#[derive(Clone, Debug)]
pub(crate) struct UgcSeason {
    pub title: String,
    pub episodes: Vec<SeasonEpisode>,
}

#[derive(Clone, Debug)]
pub(crate) struct SeasonEpisode {
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub duration: f64,
}

/// A parsed PGC (bangumi / documentary / movie) season.
#[derive(Clone, Debug)]
pub(crate) struct PgcSeason {
    pub title: String,
    pub episodes: Vec<PgcEpisode>,
}

#[derive(Clone, Debug)]
pub(crate) struct PgcEpisode {
    pub ep_id: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub long_title: String,
    pub duration: f64,
    /// Membership / payment badge text from the API, shown as an
    /// informational marker (downloadability still depends on the
    /// account's actual entitlements).
    pub badge: String,
}

/// One entry of a channel collection or uploader series.
#[derive(Clone, Debug)]
pub(crate) struct CollectionArchive {
    pub aid: i64,
    pub bvid: String,
    pub title: String,
    pub duration: f64,
}

/// One media stream inside a DASH manifest.
#[derive(Clone, Debug)]
pub(crate) struct DashMedia {
    pub quality_id: i64,
    pub bandwidth: i64,
    pub codec_id: i64,
    /// RFC 6381 codec string as sent by the API (e.g. `hev1.1.6.L150.90`);
    /// empty for entries that omit it.
    pub codecs: String,
    pub mime_type: String,
    pub width: i64,
    pub height: i64,
    /// Frames per second of the encoded stream; 0 when unreported.
    pub frame_rate: f64,
    pub url: String,
    pub backup_urls: Vec<String>,
}

/// One entry of the playurl `support_formats` list: the official product
/// naming this account sees for a quality tier. `description` is what the
/// web player renders (`1080P 高码率`), `badge` is the corner marker
/// (`大会员`, `高码率`, `60帧`, …) and `display` the short form
/// (`1080P`). The list names the tiers the *video* offers; whether the
/// signed-in account may download them is decided by the DASH manifest.
#[derive(Clone, Debug)]
pub(crate) struct SupportFormat {
    pub quality_id: i64,
    /// `new_description`, e.g. `1080P 高码率`; empty on legacy payloads
    /// that only carry the short form.
    pub description: String,
    /// `display_desc`, e.g. `1080P`; empty when absent.
    pub display: String,
    /// `superscript`, e.g. `60帧`; empty when the tier carries none.
    pub badge: String,
}

impl SupportFormat {
    /// The best name this entry itself provides, independent of the
    /// built-in table.
    pub(crate) fn name(&self) -> Option<&str> {
        [self.description.as_str(), self.display.as_str()]
            .into_iter()
            .find(|text| !text.is_empty())
    }
}

/// The stream set of a single episode.
#[derive(Clone, Debug, Default)]
pub(crate) struct DashStreams {
    pub video: Vec<DashMedia>,
    pub audio: Vec<DashMedia>,
    pub flac: Option<DashMedia>,
    pub dolby: Option<DashMedia>,
    /// Progressive (non-DASH) fallback streams when the API exposes no
    /// DASH manifest (very old or restricted uploads).
    pub progressive: Vec<DashMedia>,
    /// Official naming per quality tier, straight from `support_formats`.
    pub formats: Vec<SupportFormat>,
    /// `is_preview` on the response: the server answered with the 试看
    /// preview fragment instead of the whole episode. The API's own flag is
    /// surfaced so the UI can say what the user is actually getting, instead
    /// of handing over a six-minute file labelled as the full episode.
    pub preview: bool,
    /// Length of that fragment, from `durl[*].length` (milliseconds in the
    /// API), when the response reports one.
    pub preview_seconds: Option<f64>,
}

impl DashStreams {
    /// Official naming for a quality tier, when the playurl response
    /// advertised one.
    pub(crate) fn format_for(&self, quality_id: i64) -> Option<&SupportFormat> {
        self.formats
            .iter()
            .find(|format| format.quality_id == quality_id)
    }
}

/// Static WBI keys, cached process-wide because they are derived from a
/// daily rotating pair and every signed request needs them.
static WBI_KEYS: OnceLock<Mutex<Option<CachedWbiKeys>>> = OnceLock::new();

#[derive(Clone)]
struct CachedWbiKeys {
    img_key: String,
    sub_key: String,
    fetched_at: Instant,
}

pub(crate) struct BilibiliApi {
    http: SyncHttpClient,
    redirect_probe: SyncHttpClient,
    headers: Vec<(String, String)>,
}

impl BilibiliApi {
    pub(crate) fn new(request_context: &RequestContext) -> Result<Self> {
        let http = SyncHttpClient::with_timeouts(Duration::from_secs(10), Duration::from_secs(30))?;
        let redirect_probe = SyncHttpClient::without_redirects()?;
        let base = url::Url::parse("https://www.bilibili.com/")?;
        let headers = crate::api::downloader::request_headers(&base, request_context)?;
        Ok(Self {
            http,
            redirect_probe,
            headers,
        })
    }

    fn get_json(&self, url: &str) -> Result<Value> {
        let (status, _, body) = self.http.get(url, &self.headers)?;
        if !(200..300).contains(&status) {
            bail!("Bilibili API returned HTTP {status} for {url}");
        }
        nextjson::from_slice::<Value>(&body)
            .with_context(|| format!("Failed to parse Bilibili API response from {url}"))
    }

    /// Fetch the rotating `wbi` key pair (cached for [`WBI_KEY_TTL`]).
    fn wbi_keys(&self) -> Result<(String, String)> {
        let cache = WBI_KEYS.get_or_init(|| Mutex::new(None));
        {
            let guard = cache
                .lock()
                .map_err(|_| anyhow::anyhow!("WBI key cache is poisoned"))?;
            if let Some(keys) = guard.as_ref() {
                if keys.fetched_at.elapsed() < WBI_KEY_TTL {
                    return Ok((keys.img_key.clone(), keys.sub_key.clone()));
                }
            }
        }

        let payload = self.get_json(&format!("{API_BASE}/x/web-interface/nav"))?;
        let wbi_img = payload
            .pointer("/data/wbi_img")
            .context("Bilibili nav response did not include wbi keys")?;
        let img_url = wbi_img
            .get("img_url")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let sub_url = wbi_img
            .get("sub_url")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let img_key = wbi::key_from_wbi_url(img_url)
            .context("Bilibili nav response carried an unparsable img_url")?;
        let sub_key = wbi::key_from_wbi_url(sub_url)
            .context("Bilibili nav response carried an unparsable sub_url")?;

        let mut guard = cache
            .lock()
            .map_err(|_| anyhow::anyhow!("WBI key cache is poisoned"))?;
        *guard = Some(CachedWbiKeys {
            img_key: img_key.clone(),
            sub_key: sub_key.clone(),
            fetched_at: Instant::now(),
        });
        debug!("Refreshed Bilibili WBI keys");
        Ok((img_key, sub_key))
    }

    /// Build a fully signed API URL for `path` and `params`.
    fn signed_url(&self, path: &str, params: &[(String, String)]) -> Result<String> {
        let (img_key, sub_key) = self.wbi_keys()?;
        let mixin_key = wbi::mixin_key(&img_key, &sub_key)
            .context("Bilibili WBI keys were too short to derive a mixin key")?;
        let wts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs())
            .unwrap_or(0);
        let query = wbi::signed_query(&mixin_key, params, wts);
        Ok(format!("{API_BASE}{path}?{query}"))
    }

    /// A plain (unsigned) API URL.
    fn plain_url(path: &str, params: &[(String, String)]) -> String {
        let mut url =
            url::Url::parse(&format!("{API_BASE}{path}")).expect("static API base parses");
        url.query_pairs_mut()
            .extend_pairs(params.iter().map(|(k, v)| (k, v)));
        url.to_string()
    }

    /// Resolve a `b23.tv` / `bili2233.cn` short link into its final URL by
    /// following redirects manually (the HTTP engine hides the final URL,
    /// and redirect targets are exactly what we need).
    pub(crate) fn resolve_short_link(&self, short_url: &str) -> Result<url::Url> {
        let mut current = url::Url::parse(short_url).context("Invalid short link URL")?;

        for _ in 0..MAX_REDIRECT_HOPS {
            if !matches!(current.scheme(), "http" | "https") {
                bail!("Short link redirected to unsupported scheme: {current}");
            }

            let (status, headers, body) = self
                .redirect_probe
                .get(current.as_str(), &self.headers)
                .with_context(|| format!("Failed to resolve short link {current}"))?;

            if (300..400).contains(&status) {
                let location = headers
                    .iter()
                    .find(|(name, _)| name.eq_ignore_ascii_case("location"))
                    .map(|(_, value)| value.trim().to_string())
                    .context("Short link redirect had no Location header")?;
                current = current
                    .join(&location)
                    .with_context(|| format!("Invalid short link redirect target: {location}"))?;
                continue;
            }

            if (200..300).contains(&status) {
                let html = String::from_utf8_lossy(&body);
                let target = extract_page_url_from_html(&html)
                    .context("Short link page did not expose a Bilibili URL")?;
                return url::Url::parse(&target).context("Short link exposed an invalid URL");
            }

            bail!("Short link resolution failed with HTTP {status}");
        }

        bail!("Short link exceeded {MAX_REDIRECT_HOPS} redirect hops");
    }

    /// `x/web-interface/wbi/view` — video metadata, parts and collection
    /// membership for a regular video.
    pub(crate) fn view(&self, bvid: Option<&str>, aid: Option<i64>) -> Result<VideoView> {
        let mut params = Vec::new();
        if let Some(bvid) = bvid {
            params.push(("bvid".to_string(), bvid.to_string()));
        } else if let Some(aid) = aid {
            params.push(("aid".to_string(), aid.to_string()));
        } else {
            bail!("A video id (bvid or aid) is required");
        }
        let url = self.signed_url("/x/web-interface/wbi/view", &params)?;
        parse_view_payload(&self.get_json(&url)?)
    }

    /// `x/player/wbi/playurl` — DASH streams for one part of a video.
    pub(crate) fn playurl(&self, bvid: &str, cid: i64) -> Result<DashStreams> {
        let url = self.signed_url(
            "/x/player/wbi/playurl",
            &[
                ("bvid".to_string(), bvid.to_string()),
                ("cid".to_string(), cid.to_string()),
                ("qn".to_string(), QN.to_string()),
                ("fnver".to_string(), "0".to_string()),
                ("fnval".to_string(), FNVAL.to_string()),
                ("fourk".to_string(), "1".to_string()),
            ],
        )?;
        parse_playurl_payload(&self.get_json(&url)?, "/data")
    }

    /// `x/player/v2` — subtitle tracks for one episode.
    ///
    /// The endpoint answers anonymous requests (with an empty track list);
    /// it is not WBI-signed on the web player either. PGC episodes are
    /// addressed through their `bvid`/`cid` — `ep_id` alone is rejected
    /// with `-400` by this endpoint.
    pub(crate) fn player_subtitles(&self, bvid: &str, cid: i64) -> Result<SubtitleList> {
        let url = Self::plain_url(
            "/x/player/v2",
            &[
                ("bvid".to_string(), bvid.to_string()),
                ("cid".to_string(), cid.to_string()),
            ],
        );
        subtitle::parse_player_subtitles(&self.get_json(&url)?)
    }

    /// `pgc/view/web/season` — a whole PGC season addressed by episode or
    /// season id.
    pub(crate) fn pgc_season(
        &self,
        ep_id: Option<i64>,
        season_id: Option<i64>,
    ) -> Result<PgcSeason> {
        let mut params = Vec::new();
        if let Some(ep_id) = ep_id {
            params.push(("ep_id".to_string(), ep_id.to_string()));
        } else if let Some(season_id) = season_id {
            params.push(("season_id".to_string(), season_id.to_string()));
        } else {
            bail!("An episode id or season id is required");
        }
        let url = Self::plain_url("/pgc/view/web/season", &params);
        parse_pgc_season_payload(&self.get_json(&url)?)
    }

    /// `pgc/player/web/playurl` — DASH streams for one PGC episode.
    ///
    /// Tries `ep_id` first; a parameter-level rejection falls back to
    /// `cid`, which the API also accepts.
    pub(crate) fn pgc_playurl(&self, ep_id: i64, cid: i64) -> Result<DashStreams> {
        let attempt = |key: &str, value: i64| -> Result<DashStreams> {
            let url = Self::plain_url(
                "/pgc/player/web/playurl",
                &[
                    (key.to_string(), value.to_string()),
                    ("qn".to_string(), QN.to_string()),
                    ("fnver".to_string(), "0".to_string()),
                    ("fnval".to_string(), FNVAL.to_string()),
                    ("fourk".to_string(), "1".to_string()),
                ],
            );
            parse_playurl_payload(&self.get_json(&url)?, "/result")
        };

        match attempt("ep_id", ep_id) {
            Ok(streams) => Ok(streams),
            Err(error) if is_parameter_error(&error) && cid > 0 => {
                debug!("PGC playurl rejected ep_id ({error}); retrying with cid");
                attempt("cid", cid)
            }
            Err(error) => Err(error),
        }
    }

    /// Probe whether `sid` addresses a channel collection or an uploader
    /// series: `x/series/series` succeeds only for series ids.
    pub(crate) fn probe_collection_kind(&self, season_id: i64) -> Result<CollectionProbe> {
        let url = Self::plain_url(
            "/x/series/series",
            &[("series_id".to_string(), season_id.to_string())],
        );
        let payload = self.get_json(&url)?;
        let code = payload.get("code").and_then(Value::as_i64).unwrap_or(-1);
        if code == 0 {
            return Ok(CollectionProbe {
                kind: CollectionKind::Series,
                title: payload
                    .pointer("/data/meta/name")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                mid: payload.pointer("/data/meta/mid").and_then(Value::as_i64),
            });
        }
        Ok(CollectionProbe {
            kind: CollectionKind::Season,
            title: None,
            mid: None,
        })
    }

    /// All entries of a channel collection or uploader series (paged
    /// through to the end, bounded by [`MAX_COLLECTION_PAGES`]).
    pub(crate) fn collection_archives(
        &self,
        metadata: CollectionMetadata,
    ) -> Result<(String, Vec<CollectionArchive>)> {
        match metadata.kind {
            CollectionKind::Season => self.season_archives(metadata),
            CollectionKind::Series => self.series_archives(metadata),
        }
    }

    fn season_archives(
        &self,
        metadata: CollectionMetadata,
    ) -> Result<(String, Vec<CollectionArchive>)> {
        let mut archives = Vec::new();
        let mut title = metadata.title.unwrap_or_default();

        for page in 1..=MAX_COLLECTION_PAGES {
            let url = Self::plain_url(
                "/x/polymer/web-space/seasons_archives_list",
                &[
                    ("mid".to_string(), metadata.mid.to_string()),
                    ("season_id".to_string(), metadata.season_id.to_string()),
                    ("sort_reverse".to_string(), "false".to_string()),
                    (
                        "page_size".to_string(),
                        MAX_COLLECTION_PAGE_SIZE.to_string(),
                    ),
                    ("page_num".to_string(), page.to_string()),
                ],
            );
            let payload = self.get_json(&url)?;
            ensure_api_ok(&payload)?;
            let data = payload
                .get("data")
                .context("Collection listing had no data")?;

            if title.is_empty() {
                title = data
                    .pointer("/meta/title")
                    .or_else(|| data.pointer("/meta/name"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
            }

            let batch = parse_archive_list(data.pointer("/archives"));
            let total = data
                .pointer("/page/total")
                .and_then(Value::as_i64)
                .unwrap_or(archives.len() as i64);
            let fetched = batch.len();
            archives.extend(batch);
            if fetched < MAX_COLLECTION_PAGE_SIZE || (archives.len() as i64) >= total {
                break;
            }
        }

        Ok((title, archives))
    }

    fn series_archives(
        &self,
        metadata: CollectionMetadata,
    ) -> Result<(String, Vec<CollectionArchive>)> {
        let mut archives = Vec::new();
        let title = metadata.title.unwrap_or_default();

        if metadata.mid <= 0 {
            bail!("Uploader series requires a valid mid");
        }

        for page in 1..=MAX_COLLECTION_PAGES {
            let url = Self::plain_url(
                "/x/series/archives",
                &[
                    ("mid".to_string(), metadata.mid.to_string()),
                    ("series_id".to_string(), metadata.season_id.to_string()),
                    ("only_normal".to_string(), "true".to_string()),
                    ("sort".to_string(), "desc".to_string()),
                    ("ps".to_string(), MAX_COLLECTION_PAGE_SIZE.to_string()),
                    ("pn".to_string(), page.to_string()),
                ],
            );
            let payload = self.get_json(&url)?;
            ensure_api_ok(&payload)?;
            let data = payload.get("data").context("Series listing had no data")?;

            let batch = parse_archive_list(data.pointer("/archives"));
            let total = data
                .pointer("/page/total")
                .and_then(Value::as_i64)
                .unwrap_or(archives.len() as i64);
            let fetched = batch.len();
            archives.extend(batch);
            if fetched < MAX_COLLECTION_PAGE_SIZE || (archives.len() as i64) >= total {
                break;
            }
        }

        Ok((title, archives))
    }
}

/// Inputs for [`BilibiliApi::collection_archives`].
#[derive(Clone, Debug)]
pub(crate) struct CollectionMetadata {
    pub mid: i64,
    pub season_id: i64,
    pub kind: CollectionKind,
    pub title: Option<String>,
}

/// Result of [`BilibiliApi::probe_collection_kind`]: which read API the id
/// belongs to, plus metadata the probe already fetched.
#[derive(Clone, Debug)]
pub(crate) struct CollectionProbe {
    pub kind: CollectionKind,
    pub title: Option<String>,
    pub mid: Option<i64>,
}

/// Whether an error is a parameter-level rejection that another parameter
/// spelling could fix.
fn is_parameter_error(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<BilibiliApiCodeError>()
        .map(|api| api.0 == -400)
        .unwrap_or(false)
}

/// A Bilibili API `code != 0` rejection, kept typed so callers can react
/// to specific codes.
#[derive(Debug)]
struct BilibiliApiCodeError(i64);

impl std::fmt::Display for BilibiliApiCodeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "Bilibili API error {}", self.0)
    }
}

impl std::error::Error for BilibiliApiCodeError {}

/// Reject a payload whose `code` is not 0, translating well-known codes
/// into actionable messages (and access errors into
/// [`BilibiliAccessError`]).
fn ensure_api_ok(payload: &Value) -> Result<()> {
    let code = payload.get("code").and_then(Value::as_i64).unwrap_or(0);
    if code == 0 {
        return Ok(());
    }
    let message = payload
        .get("message")
        .or_else(|| payload.get("msg"))
        .and_then(Value::as_str)
        .unwrap_or("unknown error");

    let (display, login_may_help) = classify_api_error(code, message);
    if login_may_help {
        Err(BilibiliAccessError(display).into())
    } else {
        Err(anyhow::Error::new(BilibiliApiCodeError(code)).context(display))
    }
}

fn classify_api_error(code: i64, message: &str) -> (String, bool) {
    let detail = |hint: &str| format!("Bilibili error {code}: {message} ({hint})");
    match code {
        -352 => (
            detail("risk control rejected the request; sign in to a browser session and paste its Cookie, or retry later"),
            true,
        ),
        -412 => (
            detail("requests were intercepted; wait a few minutes, or configure a browser Cookie"),
            true,
        ),
        -403 => (detail("access denied; this may require the account that owns the content"), true),
        -2 | -23 => (detail("content is restricted in this region or context"), true),
        -10403 | 10403 => (
            detail("region-restricted or membership-only content; a signed-in session with the required entitlements is needed"),
            true,
        ),
        -101 => (detail("login required for this stream"), true),
        -404 => (detail("the content does not exist or was removed"), false),
        -400 => (detail("request parameters were rejected"), false),
        -509 => (detail("rate limited; retry later"), false),
        62002 => (detail("the upload was hidden by its owner"), false),
        62004 => (detail("the upload is under review"), false),
        87007 => (detail("this content is only playable in the mobile app"), false),
        87008 => (detail("this content is only playable in the official client"), false),
        10003 | 147002 => (detail("the content does not exist"), false),
        _ => (detail("unexpected API error"), false),
    }
}

fn parse_view_payload(payload: &Value) -> Result<VideoView> {
    ensure_api_ok(payload)?;
    let data = payload.get("data").context("View response had no data")?;

    let bvid = data
        .get("bvid")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let title = data
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let cid = data.get("cid").and_then(Value::as_i64).unwrap_or(0);

    let pages = data
        .get("pages")
        .and_then(Value::as_array)
        .map(|pages| {
            pages
                .iter()
                .filter_map(|page| {
                    let cid = page.get("cid").and_then(Value::as_i64)?;
                    Some(VideoPage {
                        cid,
                        page: page
                            .get("page")
                            .and_then(Value::as_i64)
                            .unwrap_or(1)
                            .clamp(1, i64::from(u32::MAX)) as u32,
                        title: page
                            .get("part")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        duration: page.get("duration").and_then(Value::as_f64).unwrap_or(0.0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    if bvid.is_empty() || cid <= 0 {
        bail!("Bilibili view response did not expose a usable video");
    }

    let season = data
        .pointer("/ugc_season/sections")
        .and_then(Value::as_array)
        .and_then(|sections| {
            let episodes = sections
                .iter()
                .flat_map(|section| {
                    section
                        .get("episodes")
                        .and_then(Value::as_array)
                        .map(Vec::as_slice)
                        .unwrap_or_default()
                })
                .filter_map(|episode| {
                    let episode_bvid = episode
                        .get("bvid")
                        .and_then(Value::as_str)
                        .filter(|value| !value.is_empty())?;
                    Some(SeasonEpisode {
                        bvid: episode_bvid.to_string(),
                        cid: episode.get("cid").and_then(Value::as_i64).unwrap_or(0),
                        title: episode
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        duration: episode
                            .pointer("/arc/duration")
                            .and_then(Value::as_f64)
                            .unwrap_or(0.0),
                    })
                })
                .collect::<Vec<_>>();
            if episodes.is_empty() {
                return None;
            }
            Some(UgcSeason {
                title: data
                    .pointer("/ugc_season/title")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                episodes,
            })
        });

    Ok(VideoView {
        bvid,
        title,
        cid,
        pages,
        season,
    })
}

fn parse_pgc_season_payload(payload: &Value) -> Result<PgcSeason> {
    ensure_api_ok(payload)?;
    let result = payload
        .get("result")
        .or_else(|| payload.get("data"))
        .context("PGC season response had no result")?;

    let title = result
        .pointer("/season_title")
        .or_else(|| result.pointer("/title"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let episodes = result
        .get("episodes")
        .and_then(Value::as_array)
        .map(|episodes| {
            episodes
                .iter()
                .filter_map(|episode| {
                    let ep_id = episode
                        .get("id")
                        .or_else(|| episode.get("ep_id"))
                        .and_then(Value::as_i64)?;
                    Some(PgcEpisode {
                        ep_id,
                        bvid: episode
                            .get("bvid")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        cid: episode.get("cid").and_then(Value::as_i64).unwrap_or(0),
                        title: episode
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        long_title: episode
                            .get("long_title")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        duration: episode
                            .get("duration")
                            .and_then(Value::as_f64)
                            .unwrap_or(0.0),
                        badge: episode
                            .pointer("/badge_info/text")
                            .or_else(|| episode.get("badge"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    if title.is_empty() || episodes.is_empty() {
        bail!("PGC season response did not expose a usable season");
    }
    Ok(PgcSeason { title, episodes })
}

/// Parse the DASH manifest out of a playurl payload. `root` selects where
/// the stream object lives (`/data` for UGC, `/result` for PGC), with a
/// `/video_info` variant tolerated for the PGC v2 shape.
fn parse_playurl_payload(payload: &Value, root: &str) -> Result<DashStreams> {
    ensure_api_ok(payload)?;

    let container = payload.pointer(root);
    let stream_root = container
        .map(|node| {
            if node.get("dash").is_none() && node.get("durl").is_none() {
                node.get("video_info").unwrap_or(node)
            } else {
                node
            }
        })
        .or_else(|| payload.pointer(&format!("{root}/video_info")))
        .context("Playurl response had no stream object")?;

    let marker = |pointer: &str| {
        [Some(stream_root), container]
            .into_iter()
            .flatten()
            .find_map(|node| node.pointer(pointer))
    };

    let mut streams = DashStreams::default();

    if let Some(dash) = stream_root.get("dash") {
        streams.video = parse_dash_media_list(dash.get("video"));
        streams.audio = parse_dash_media_list(dash.get("audio"));
        streams.flac = dash.pointer("/flac/audio").and_then(parse_dash_media);
        streams.dolby = dash
            .pointer("/dolby/audio")
            .and_then(Value::as_array)
            .and_then(|audios| audios.iter().find_map(parse_dash_media));
    }
    streams.formats = parse_support_formats(stream_root.get("support_formats"));
    streams.preview = marker("/is_preview").and_then(Value::as_i64).unwrap_or(0) != 0;

    // Progressive fallback (`durl`): one muxed file, no separate audio.
    if streams.video.is_empty() && streams.audio.is_empty() {
        if let Some(durl) = stream_root.get("durl").and_then(Value::as_array) {
            for entry in durl {
                if let Some(media) = parse_dash_media(entry) {
                    streams.progressive.push(media);
                }
            }
        }
    }

    if streams.preview {
        // `durl[*].length` is milliseconds; the preview fragment is the first
        // (and, in every response seen in the field, only) entry.
        streams.preview_seconds = stream_root
            .pointer("/durl/0/length")
            .and_then(Value::as_i64)
            .filter(|milliseconds| *milliseconds > 0)
            .map(|milliseconds| milliseconds as f64 / 1000.0);
    }

    if streams.video.is_empty() && streams.progressive.is_empty() {
        // `code: 0` with the entitlement check spelled out but no stream at
        // all is a real shape for gated episodes: name the gate instead of
        // the generic "no streams".
        let preview_gate = streams.preview
            || marker("/play_check/play_detail")
                .and_then(Value::as_str)
                .is_some_and(|detail| detail.contains("PREVIEW"));
        if preview_gate {
            bail!(
                "Bilibili answered with the 试看 (preview) entitlement and no downloadable fragment for this session; \
                 the full stream needs the matching account entitlements (membership, purchase or region)"
            );
        }
        bail!("Playurl response did not contain any playable streams");
    }

    Ok(streams)
}

fn parse_dash_media_list(value: Option<&Value>) -> Vec<DashMedia> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(parse_dash_media).collect())
        .unwrap_or_default()
}

/// Parse the `support_formats` list: the official quality naming for the
/// account that made the request. Entries without a quality id or any
/// usable text are skipped rather than invented; the legacy `format`
/// container codes (`hdflv2`, `flv720`) are never used as names.
fn parse_support_formats(value: Option<&Value>) -> Vec<SupportFormat> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(parse_support_format).collect())
        .unwrap_or_default()
}

fn parse_support_format(value: &Value) -> Option<SupportFormat> {
    let quality_id = value.get("quality").and_then(Value::as_i64).unwrap_or(0);
    if quality_id <= 0 {
        return None;
    }
    let read = |key: &str| {
        value
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty() && !looks_like_legacy_format_code(text))
            .map(str::to_string)
            .unwrap_or_default()
    };
    let format = SupportFormat {
        quality_id,
        description: read("new_description"),
        display: read("display_desc"),
        badge: value
            .get("superscript")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or_default()
            .to_string(),
    };
    format.name()?;
    Some(format)
}

/// Legacy `format` values are opaque container codes (`hdflv2`, `flv720`)
/// that must never be shown as a quality name.
fn looks_like_legacy_format_code(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "flv" | "mp4" | "hdflv2" | "flv720" | "flv480"
    ) || lower.starts_with("flv")
}

fn parse_dash_media(value: &Value) -> Option<DashMedia> {
    let (url, backup_urls) = choose_stream_urls(value)?;
    Some(DashMedia {
        quality_id: value.get("id").and_then(Value::as_i64).unwrap_or(0),
        bandwidth: value.get("bandwidth").and_then(Value::as_i64).unwrap_or(0),
        codec_id: value
            .get("codecid")
            .or_else(|| value.get("codec_id"))
            .and_then(Value::as_i64)
            .unwrap_or(0),
        codecs: value
            .get("codecs")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        mime_type: value
            .get("mime_type")
            .or_else(|| value.get("mimeType"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        width: value.get("width").and_then(Value::as_i64).unwrap_or(0),
        height: value.get("height").and_then(Value::as_i64).unwrap_or(0),
        frame_rate: value
            .get("frameRate")
            .or_else(|| value.get("frame_rate"))
            .and_then(Value::as_f64)
            .unwrap_or(0.0),
        url,
        backup_urls,
    })
}

/// Pick the preferred URL and preserve the remaining API-provided mirrors.
///
/// `upos-*` CDN hosts are direct and consistently fast; the rotated
/// `mcdn`/P2P hosts some responses carry as the primary URL are slower.
/// Every alternate is retained so a failed CDN can be retried without
/// asking the API for a new signed URL.
fn choose_stream_urls(value: &Value) -> Option<(String, Vec<String>)> {
    let mut candidates = Vec::new();
    for key in ["base_url", "baseUrl", "url"] {
        if let Some(url) = value.get(key).and_then(Value::as_str) {
            candidates.push(url.to_string());
        }
    }
    for key in ["backup_url", "backupUrl"] {
        if let Some(list) = value.get(key).and_then(Value::as_array) {
            candidates.extend(list.iter().filter_map(Value::as_str).map(str::to_string));
        }
    }

    let mut normalized = Vec::new();
    for candidate in candidates {
        let candidate = normalize_stream_url(&candidate);
        let Ok(parsed) = url::Url::parse(&candidate) else {
            continue;
        };
        if parsed.scheme() != "https" || parsed.host_str().is_none() {
            continue;
        }
        if !normalized.contains(&candidate) {
            normalized.push(candidate);
        }
    }

    let primary_index = normalized
        .iter()
        .position(|candidate| {
            url::Url::parse(candidate)
                .ok()
                .and_then(|url| url.host_str().map(str::to_ascii_lowercase))
                .is_some_and(|host| host.starts_with("upos-"))
        })
        .or_else(|| (!normalized.is_empty()).then_some(0))?;
    let primary = normalized.remove(primary_index);
    let backup_urls = normalized.into_iter().take(8).collect();
    Some((primary, backup_urls))
}

fn normalize_stream_url(url: &str) -> String {
    let url = url.trim();
    if let Some(rest) = url.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = url.strip_prefix("http://") {
        // Bilibili streams are TLS-capable everywhere; upgrading avoids
        // mixed-content and downgrade issues without changing identity.
        format!("https://{rest}")
    } else {
        url.to_string()
    }
}

impl BilibiliApi {
    /// Resolve any page URL into a [`Target`], following short links.
    pub(crate) fn resolve_target(&self, url: &url::Url) -> Result<Option<(url::Url, Target)>> {
        let Some(mut target) = super::url::parse_target(url) else {
            return Ok(None);
        };
        let mut current = url.clone();
        for _ in 0..3 {
            let short = match &target {
                Target::ShortLink { url: short } => short.clone(),
                _ => return Ok(Some((current, target))),
            };
            current = self.resolve_short_link(&short)?;
            let Some(next) = super::url::parse_target(&current) else {
                return Ok(None);
            };
            target = next;
        }
        bail!("Short link resolution did not settle on a page URL");
    }
}

/// Pull the first Bilibili page URL out of a tiny redirect-hop HTML page.
fn extract_page_url_from_html(html: &str) -> Option<String> {
    let mut search = html;
    while let Some(index) = search.find("http") {
        let candidate = &search[index..];
        let end = candidate
            .find(|ch: char| {
                ch == '"' || ch == '\'' || ch == '<' || ch == '>' || ch.is_whitespace()
            })
            .unwrap_or(candidate.len());
        let candidate = &candidate[..end];
        if (candidate.contains("bilibili.com")
            || candidate.contains("b23.tv")
            || candidate.contains("bili2233.cn"))
            && !candidate.contains("fe-static")
        {
            if let Ok(parsed) = url::Url::parse(candidate) {
                return Some(parsed.to_string());
            }
        }
        search = &search[index + end..];
    }
    None
}

fn parse_archive_list(value: Option<&Value>) -> Vec<CollectionArchive> {
    value
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| {
                    let bvid = entry.get("bvid").and_then(Value::as_str)?;
                    if bvid.is_empty() {
                        return None;
                    }
                    Some(CollectionArchive {
                        aid: entry.get("aid").and_then(Value::as_i64).unwrap_or(0),
                        bvid: bvid.to_string(),
                        title: entry
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        duration: entry.get("duration").and_then(Value::as_f64).unwrap_or(0.0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::{
        classify_api_error, ensure_api_ok, extract_page_url_from_html, normalize_stream_url,
        parse_pgc_season_payload, parse_playurl_payload, parse_view_payload,
    };
    use nextjson::Value;

    fn parse_json(text: &str) -> Value {
        nextjson::from_str::<Value>(text).expect("fixture must be valid JSON")
    }

    #[test]
    fn parses_view_payload_with_pages_and_season() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "0",
                "data": {
                    "bvid": "BV1QQ4y1T7Eu",
                    "aid": 997835904,
                    "cid": 995678901,
                    "title": "Fixture Video",
                    "duration": 854,
                    "pages": [
                        {"cid": 995678901, "page": 1, "part": "P1 Intro", "duration": 854},
                        {"cid": 995678902, "page": 2, "part": "P2 Main", "duration": 1200}
                    ],
                    "ugc_season": {
                        "id": 3369187,
                        "title": "Fixture Collection",
                        "sections": [
                            {
                                "id": 1,
                                "title": "正片",
                                "episodes": [
                                    {
                                        "id": 1,
                                        "bvid": "BV1QQ4y1T7Eu",
                                        "cid": 995678901,
                                        "title": "Episode 1",
                                        "arc": {"duration": 854}
                                    },
                                    {
                                        "id": 2,
                                        "bvid": "BV1AA411c7mD",
                                        "cid": 995678999,
                                        "title": "Episode 2",
                                        "arc": {"duration": 900}
                                    }
                                ]
                            }
                        ]
                    }
                }
            }"#,
        );

        let view = parse_view_payload(&payload).expect("view must parse");
        assert_eq!(view.bvid, "BV1QQ4y1T7Eu");
        assert_eq!(view.title, "Fixture Video");
        assert_eq!(view.pages.len(), 2);
        assert_eq!(view.pages[1].page, 2);
        assert_eq!(view.pages[1].title, "P2 Main");

        let season = view.season.expect("season present");
        assert_eq!(season.title, "Fixture Collection");
        assert_eq!(season.episodes.len(), 2);
        assert_eq!(season.episodes[1].bvid, "BV1AA411c7mD");
        assert_eq!(season.episodes[1].duration, 900.0);
    }

    #[test]
    fn parses_playurl_payload_with_dash_variants() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "0",
                "data": {
                    "dash": {
                        "duration": 854,
                        "video": [
                            {
                                "id": 80,
                                "base_url": "http://mcdn.example/video-1080p.m4s?sign=1",
                                "backup_url": [
                                    "https://upos-sz-mirror.example/video-1080p.m4s?sign=2",
                                    "https://upos-sz-backup.example/video-1080p.m4s?sign=3"
                                ],
                                "bandwidth": 2200000,
                                "codecid": 7,
                                "codecs": "avc1.640032",
                                "mime_type": "video/mp4",
                                "width": 1920,
                                "height": 1080
                            },
                            {
                                "id": 112,
                                "base_url": "https://upos-sz-mirror.example/video-1080p-plus.m4s?sign=3",
                                "backup_url": [],
                                "bandwidth": 6000000,
                                "codecid": 12,
                                "codecs": "hev1.1.6.L120.90",
                                "mime_type": "video/mp4",
                                "width": 1920,
                                "height": 1080
                            }
                        ],
                        "audio": [
                            {
                                "id": 30280,
                                "base_url": "https://upos-sz-mirror.example/audio-192k.m4s?sign=4",
                                "backup_url": [],
                                "bandwidth": 192000,
                                "codecid": 0,
                                "codecs": "mp4a.40.2",
                                "mime_type": "audio/mp4"
                            }
                        ],
                        "flac": {
                            "display": true,
                            "audio": {
                                "id": 30251,
                                "base_url": "https://upos-sz-mirror.example/audio-hires.m4s?sign=5",
                                "backup_url": [],
                                "bandwidth": 1500000,
                                "codecid": 0,
                                "codecs": "fLaC",
                                "mime_type": "audio/mp4"
                            }
                        },
                        "dolby": {
                            "type": 2,
                            "audio": [
                                {
                                    "id": 30250,
                                    "base_url": "https://upos-sz-mirror.example/audio-dolby.m4s?sign=6",
                                    "backup_url": [],
                                    "bandwidth": 448000,
                                    "codecid": 0,
                                    "codecs": "ec-3",
                                    "mime_type": "audio/mp4"
                                }
                            ]
                        }
                    },
                    "support_formats": [
                        {
                            "quality": 112,
                            "format": "hdflv2",
                            "new_description": "1080P 高码率",
                            "display_desc": "1080P",
                            "superscript": "高码率",
                            "codecs": ["av01.0.08M.08.0.110.01.01.01.0", "avc1.640032"]
                        },
                        {
                            "quality": 80,
                            "format": "flv",
                            "new_description": "1080P 高清",
                            "display_desc": "1080P",
                            "superscript": ""
                        },
                        {
                            "quality": 64,
                            "format": "flv720",
                            "superscript": ""
                        },
                        {
                            "quality": 16,
                            "format": "mp4",
                            "display_desc": "360P",
                            "superscript": ""
                        }
                    ]
                }
            }"#,
        );

        let streams = parse_playurl_payload(&payload, "/data").expect("playurl must parse");
        assert_eq!(streams.video.len(), 2);
        // The primary mcdn URL is http; the upos backup is TLS and upos.
        assert_eq!(
            streams.video[0].url,
            "https://upos-sz-mirror.example/video-1080p.m4s?sign=2"
        );
        assert_eq!(
            streams.video[0].backup_urls,
            vec![
                "https://mcdn.example/video-1080p.m4s?sign=1",
                "https://upos-sz-backup.example/video-1080p.m4s?sign=3"
            ]
        );
        assert_eq!(streams.video[0].codecs, "avc1.640032");
        assert_eq!(streams.video[0].frame_rate, 0.0);
        assert_eq!(streams.audio.len(), 1);
        assert_eq!(streams.audio[0].quality_id, 30280);
        assert_eq!(
            streams.flac.as_ref().map(|flac| flac.quality_id),
            Some(30251)
        );
        assert_eq!(
            streams.dolby.as_ref().map(|dolby| dolby.quality_id),
            Some(30250)
        );

        // `support_formats` keeps the official naming. An entry carrying
        // only the legacy container code is dropped; a short display form
        // is kept but never outranks the built-in official table.
        assert_eq!(streams.formats.len(), 3);
        let plus = streams.format_for(112).expect("112 must be named");
        assert_eq!(plus.description, "1080P 高码率");
        assert_eq!(plus.display, "1080P");
        assert_eq!(plus.badge, "高码率");
        let hd = streams.format_for(80).expect("80 must be named");
        assert_eq!(hd.description, "1080P 高清");
        assert!(hd.badge.is_empty());
        assert!(streams.format_for(64).is_none());
        assert_eq!(
            streams.format_for(16).and_then(|format| format.name()),
            Some("360P")
        );
    }

    #[test]
    fn parses_live_frame_rate_and_codec_metadata() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "data": {
                    "support_formats": [
                        {
                            "quality": 116,
                            "format": "hdflv2",
                            "new_description": "1080P 60帧",
                            "display_desc": "1080P",
                            "superscript": "60帧"
                        }
                    ],
                    "dash": {
                        "video": [
                            {
                                "id": 116,
                                "base_url": "https://upos-sz-mirror.example/video-1080p60.m4s",
                                "backup_url": [],
                                "bandwidth": 6000000,
                                "codecid": 12,
                                "codecs": "hev1.1.6.L150.90",
                                "mime_type": "video/mp4",
                                "width": 1920,
                                "height": 1080,
                                "frameRate": 60.0
                            }
                        ],
                        "audio": []
                    }
                }
            }"#,
        );

        let streams = parse_playurl_payload(&payload, "/data").expect("playurl must parse");
        assert_eq!(streams.video[0].frame_rate, 60.0);
        assert_eq!(streams.video[0].codecs, "hev1.1.6.L150.90");
        assert_eq!(
            streams.format_for(116).map(|format| format.badge.as_str()),
            Some("60帧")
        );
    }

    #[test]
    fn parses_progressive_fallback_payload() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "0",
                "data": {
                    "timelength": 640000,
                    "durl": [
                        {"url": "https://upos.example/progressive-1.mp4", "backup_url": [], "order": 1},
                        {"url": "https://upos.example/progressive-2.mp4", "backup_url": [], "order": 2}
                    ]
                }
            }"#,
        );

        let streams = parse_playurl_payload(&payload, "/data").expect("durl must parse");
        assert_eq!(streams.progressive.len(), 2);
    }

    #[test]
    fn reads_the_preview_flag_and_fragment_length() {
        // The shape `ep1994063` answers with: `is_preview` plus a single
        // `durl` part whose `length` is milliseconds.
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "success",
                "result": {
                    "is_preview": 1,
                    "durl": [
                        {"url": "https://upos.example/part.mp4", "backup_url": [], "length": 360680, "size": 15805817}
                    ]
                }
            }"#,
        );
        let streams = parse_playurl_payload(&payload, "/result").expect("preview must parse");
        assert!(streams.preview);
        assert_eq!(streams.preview_seconds, Some(360.68));

        // A normal episode is not a preview and carries no fragment length.
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "success",
                "result": {
                    "dash": {"video": [{"id": 32, "baseUrl": "https://upos.example/v.m4s"}]}
                }
            }"#,
        );
        let streams = parse_playurl_payload(&payload, "/result").expect("dash must parse");
        assert!(!streams.preview);
        assert_eq!(streams.preview_seconds, None);
    }

    #[test]
    fn descends_into_the_pgc_v2_video_info_shape() {
        // `/pgc/player/web/v2/playurl` nests the stream object under
        // `video_info`; the parser must not mistake the wrapper for an empty
        // response.
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "success",
                "result": {
                    "play_check": {"play_detail": "PLAY_PREVIEW"},
                    "video_info": {
                        "is_preview": 1,
                        "durl": [
                            {"url": "https://upos.example/v2.mp4", "backup_url": [], "length": 6000}
                        ]
                    }
                }
            }"#,
        );
        let streams = parse_playurl_payload(&payload, "/result").expect("v2 shape must parse");
        assert_eq!(streams.progressive.len(), 1);
        assert!(streams.preview);
        assert_eq!(streams.preview_seconds, Some(6.0));
    }

    #[test]
    fn names_the_preview_gate_when_no_stream_can_be_served() {
        // A gated episode answers `code: 0` with the preview check spelled
        // out and no stream at all; the error must name that gate.
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "success",
                "result": {
                    "play_check": {"play_detail": "PLAY_PREVIEW"},
                    "video_info": {"accept_format": "mp4", "durl": []}
                }
            }"#,
        );
        let error = parse_playurl_payload(&payload, "/result")
            .expect_err("an empty gated payload must not parse as a stream set");
        let message = format!("{error:#}");
        assert!(
            message.contains("试看"),
            "the error must name the preview gate: {message}"
        );

        // Without any preview signal the generic message stays.
        let payload = parse_json(r#"{"code": 0, "message": "success", "result": {"durl": []}}"#);
        let error = parse_playurl_payload(&payload, "/result").expect_err("empty payload");
        assert!(format!("{error:#}").contains("did not contain any playable streams"));
    }

    #[test]
    fn parses_pgc_payload_from_result_root() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "message": "success",
                "result": {
                    "season_id": 28747,
                    "season_title": "Fixture Season",
                    "episodes": [
                        {
                            "id": 327577,
                            "bvid": "BV1fixture01",
                            "cid": 111111,
                            "title": "第1话",
                            "long_title": "启程",
                            "duration": 1440,
                            "badge": ""
                        },
                        {
                            "id": 327578,
                            "bvid": "BV1fixture02",
                            "cid": 111112,
                            "title": "第2话",
                            "long_title": "风暴",
                            "duration": 1500,
                            "badge_info": {"text": "会员"}
                        }
                    ]
                }
            }"#,
        );

        let season = parse_pgc_season_payload(&payload).expect("pgc season must parse");
        assert_eq!(season.title, "Fixture Season");
        assert_eq!(season.episodes.len(), 2);
        assert_eq!(season.episodes[0].ep_id, 327577);
        assert_eq!(season.episodes[1].badge, "会员");
    }

    #[test]
    fn maps_known_api_errors() {
        let (message, login) = classify_api_error(-352, "风控校验失败");
        assert!(message.contains("-352"));
        assert!(login);

        let (message, login) = classify_api_error(-404, "啥都木有");
        assert!(message.contains("does not exist"));
        assert!(!login);

        let (message, login) = classify_api_error(-10403, "抱歉您不符合观看条件");
        assert!(message.contains("membership"));
        assert!(login);

        let (_, login) = classify_api_error(87008, "仅限客户端");
        assert!(!login);
    }

    #[test]
    fn ensure_api_ok_rejects_and_classifies() {
        let ok = parse_json(r#"{"code": 0}"#);
        ensure_api_ok(&ok).expect("code 0 passes");

        let risk_controlled = parse_json(r#"{"code": -352, "message": "risk"}"#);
        let error = ensure_api_ok(&risk_controlled).expect_err("must reject");
        assert!(error.downcast_ref::<super::BilibiliAccessError>().is_some());

        let missing = parse_json(r#"{"code": -404, "message": "nope"}"#);
        let error = ensure_api_ok(&missing).expect_err("must reject");
        assert!(error.downcast_ref::<super::BilibiliAccessError>().is_none());
    }

    #[test]
    fn normalizes_stream_urls() {
        assert_eq!(
            normalize_stream_url("http://mcdn.example/a.m4s"),
            "https://mcdn.example/a.m4s"
        );
        assert_eq!(
            normalize_stream_url("//upos.example/a.m4s"),
            "https://upos.example/a.m4s"
        );
        assert_eq!(
            normalize_stream_url("https://upos.example/a.m4s"),
            "https://upos.example/a.m4s"
        );
    }

    #[test]
    fn extracts_page_urls_from_hop_html() {
        let html = r#"<html><head><meta http-equiv="refresh" content="0;url=https://www.bilibili.com/video/BV1xx411c7mD?share_source=short_link"></head></html>"#;
        assert_eq!(
            extract_page_url_from_html(html).as_deref(),
            Some("https://www.bilibili.com/video/BV1xx411c7mD?share_source=short_link")
        );
        assert_eq!(
            extract_page_url_from_html(r#"<a href="https://i0.hdslb.com/bfs/face.jpg">x</a>"#),
            None
        );
    }

    /// Live smoke test against the production API. It is ignored by
    /// default — run it explicitly after touching the request path:
    ///
    /// ```text
    /// cargo test --lib bilibili_live_smoke -- --ignored --nocapture
    /// ```
    ///
    /// It drives the exact code the app uses (cookie-free request context →
    /// WBI signing → typed parsing → error classification) for a public UGC
    /// video and for the PGC episode from the field report, so a change that
    /// breaks signing or parsing shows up before the app does. Nothing is
    /// downloaded and no credentials are involved; whether a PGC episode's
    /// streams are gated is an account property the test only reports.
    #[test]
    #[ignore = "hits the live Bilibili API"]
    fn bilibili_live_smoke() {
        use crate::api::downloader::RequestContext;

        let api =
            super::BilibiliApi::new(&RequestContext::default()).expect("HTTP client must build");

        let view = api
            .view(Some("BV1GJ411x7h7"), None)
            .expect("anonymous view must resolve a public video");
        assert!(!view.title.is_empty(), "view returned an empty title");
        assert!(
            view.cid > 0 || !view.pages.is_empty(),
            "view returned no playable part"
        );
        println!(
            "view ok: {} ({} part(s)) title={}",
            view.bvid,
            view.pages.len().max(1),
            view.title
        );

        let cid = view.pages.first().map(|page| page.cid).unwrap_or(view.cid);
        let streams = api
            .playurl(&view.bvid, cid)
            .expect("playurl must resolve for a public video");
        assert!(
            !streams.video.is_empty(),
            "playurl returned no video streams"
        );
        println!(
            "playurl ok: {} video tier(s), {} audio track(s), {} official format name(s)",
            streams.video.len(),
            streams.audio.len(),
            streams.formats.len()
        );
        for media in &streams.video {
            println!(
                "  qn={} codec={} {}x{} bandwidth={}",
                media.quality_id, media.codec_id, media.width, media.height, media.bandwidth
            );
        }

        // The episode from the field report: the metadata endpoint must
        // answer even anonymously.
        match api.pgc_season(Some(1994063), None) {
            Ok(season) => println!(
                "pgc ok: {} ({} episode(s))",
                season.title,
                season.episodes.len()
            ),
            Err(error) => println!("pgc outcome: {error:#}"),
        }

        // Media handshake: every official mirror of the selected stream is
        // tried with the exact headers the downloader sends (Referer /
        // Origin / Cookie / UA), in the same order the runtime fallback
        // uses. At least one must answer, and only the first byte of each
        // is requested.
        let stream = streams.video.first().expect("playurl returned no stream");
        let page = url::Url::parse("https://www.bilibili.com/").expect("static page URL parses");
        let headers = crate::api::downloader::request_headers(&page, &RequestContext::default())
            .expect("download headers must build");
        let client = crate::net::SyncHttpClient::with_timeouts(
            std::time::Duration::from_secs(10),
            std::time::Duration::from_secs(30),
        )
        .expect("HTTP client must build");
        let mut mirrors = vec![stream.url.clone()];
        mirrors.extend(stream.backup_urls.iter().cloned());
        let mut working_mirror = None;
        for url in &mirrors {
            let host = url::Url::parse(url)
                .ok()
                .and_then(|parsed| parsed.host_str().map(str::to_string))
                .unwrap_or_else(|| "<unparseable>".to_string());
            match client.get_range(url, &headers, 0, 0) {
                Ok((status, _, body)) if status == 206 || status == 200 => {
                    println!(
                        "media handshake ok: HTTP {status}, {} byte(s) from {host}",
                        body.len()
                    );
                    working_mirror = Some(host);
                    break;
                }
                Ok((status, _, _)) => println!("media mirror {host} answered HTTP {status}"),
                Err(error) => {
                    println!("media mirror {host} failed: {}", error.root_cause())
                }
            }
        }
        assert!(
            working_mirror.is_some(),
            "no Bilibili CDN mirror answered the media range request"
        );
    }
}
