//! Native Bilibili support: video / multi-part / collection / series /
//! bangumi downloads driven straight from the public API.
//!
//! ## Why the API instead of the page source
//!
//! Scraping `__playinfo__` out of the HTML means downloading a full web
//! page (hundreds of kilobytes) to answer questions the API answers with a
//! few kilobytes of JSON — and the page source only ever describes the one
//! episode it embeds, never the collection it belongs to. The API path
//! costs two small requests per episode (view + signed playurl) and gives
//! the whole episode list for free, which is what makes "download the
//! entire series" possible at all.
//!
//! ## Layout
//!
//! - [`url`] parses every supported page shape (BV / av / ep / ss /
//!   collection detail / playlist / short link) into a typed target.
//! - [`wbi`] implements the request signature the API demands.
//! - [`api`] performs the HTTP calls and parses responses into typed
//!   structs, classifying error codes into "log in to fix" and "dead end".
//! - [`stream`] converts DASH stream sets into the downloader's candidate
//!   model.
//! - This module orchestrates: resolve → fetch → build collection +
//!   candidates → `MediaInspectionResult`.
//!
//! Every network call merges the user's request context (User-Agent /
//! Cookie / extra headers); a signed-in session is what unlocks 1080P+,
//! 4K and membership episodes, and the high-quality hint surfaces that
//! instead of silently capping the download.

mod api;
mod stream;
mod subtitle;
mod url;
mod wbi;

use ::url::Url;
use anyhow::{bail, Context, Result};
use log::debug;
use nextjson::Value;
use std::time::Duration;

use crate::api::downloader::{
    score_candidates, CandidateCollector, MediaCollection, MediaCollectionEntry,
    MediaInspectionResult, MediaSubtitleTrack, RequestContext,
};
use crate::api::site_adapters::SiteWarning;
use crate::net::SyncHttpClient;

use self::api::{
    BilibiliAccessError, BilibiliApi, CollectionArchive, CollectionMetadata, DashStreams,
    PgcEpisode, PgcSeason, VideoPage, VideoView,
};
use self::subtitle::{SubtitleList, SubtitleTrack};
use self::url::{CollectionKind, Target};

/// Inspect any supported Bilibili page and produce candidates plus the
/// episode list it belongs to.
pub(crate) fn inspect_bilibili(
    raw_url: &str,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let parsed = Url::parse(raw_url).context("Invalid Bilibili URL")?;
    let api = BilibiliApi::new(request_context)?;

    let Some((_, target)) = api.resolve_target(&parsed)? else {
        return Ok(unsupported_page_result(raw_url));
    };
    debug!("Resolved Bilibili target: {target:?}");

    let mut result = match target {
        Target::Video { bvid, aid, page } => inspect_video(&api, bvid, aid, page, request_context),
        Target::Episode { ep_id } => inspect_pgc_episode(&api, ep_id, request_context),
        Target::Season { season_id } => inspect_pgc_season(&api, season_id, request_context),
        Target::Collection {
            mid,
            season_id,
            kind,
        } => inspect_named_collection(&api, mid, season_id, kind, None, request_context),
        Target::Playlist {
            mid,
            season_id,
            current_bvid,
            current_aid,
        } => inspect_playlist(
            &api,
            mid,
            season_id,
            current_bvid,
            current_aid,
            request_context,
        ),
        // `resolve_target` follows short links before returning, so this
        // only triggers if a chain somehow still resolves to one.
        Target::ShortLink { .. } => Ok(unsupported_page_result(raw_url)),
    }?;

    // Failure outcomes cannot always know the canonical page URL; fall
    // back to the user's input so the UI keeps a meaningful URL.
    if result.page_url.is_empty() {
        result.page_url = raw_url.to_string();
    }
    Ok(result)
}

/// A page shape we recognize as Bilibili but cannot resolve (live rooms,
/// activity pages, …). Reported visibly instead of guessing.
fn unsupported_page_result(raw_url: &str) -> MediaInspectionResult {
    MediaInspectionResult {
        page_url: raw_url.to_string(),
        page_title: "Bilibili".to_string(),
        extractor: "bilibili".to_string(),
        candidates: Vec::new(),
        subtitles: Vec::new(),
        warnings: vec![SiteWarning::site(
            "bilibili-unsupported-page",
            "This Bilibili page type is not supported; share a video, bangumi episode, or collection page instead",
        )
        .into_display()],
        auth_required: false,
        challenge_reason: String::new(),
        collection: None,
    }
}

/// `www.bilibili.com/video/{bv,av}…` — a regular video, optionally one
/// part of a multi-part upload, optionally inside a collection.
fn inspect_video(
    api: &BilibiliApi,
    bvid: Option<String>,
    aid: Option<i64>,
    requested_page: Option<u32>,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let view = match api.view(bvid.as_deref(), aid) {
        Ok(view) => view,
        Err(error) => return view_failure_outcome("", "", &error),
    };

    let total_parts = view.pages.len();
    let (part_index, part_warning) = select_part(&view, requested_page);
    let current_part = view.pages.get(part_index);
    let current_cid = current_part.map(|page| page.cid).unwrap_or(view.cid);
    if current_cid <= 0 {
        return Err(anyhow::anyhow!(
            "Bilibili video {} has no playable part",
            view.bvid
        ));
    }

    let part_number = current_part.map(|page| page.page).unwrap_or(1);
    let page_url = url::video_page_url(&view.bvid, part_number, total_parts);
    let collection = build_video_collection(&view, part_index);
    let candidate_title = compose_part_title(&view.title, current_part, total_parts);

    let streams = match api.playurl(&view.bvid, current_cid) {
        Ok(streams) => streams,
        Err(error) => {
            return Ok(playurl_failure_outcome(
                &page_url,
                &view.title,
                &error,
                collection,
            ))
        }
    };

    let mut warnings = Vec::new();
    if let Some(warning) = part_warning {
        warnings.push(warning);
    }
    let subtitles = fetch_subtitles(api, &view.bvid, current_cid, request_context, &mut warnings);
    Ok(ready_result(
        page_url,
        view.title,
        candidate_title,
        streams,
        subtitles,
        collection,
        warnings,
        request_context,
    ))
}

/// `www.bilibili.com/bangumi/play/ep…` — one episode of a PGC season.
fn inspect_pgc_episode(
    api: &BilibiliApi,
    ep_id: i64,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let season = match api.pgc_season(Some(ep_id), None) {
        Ok(season) => season,
        Err(error) => return view_failure_outcome("", "", &error),
    };
    inspect_pgc_episode_in_season(api, &season, Some(ep_id), request_context)
}

/// `www.bilibili.com/bangumi/play/ss…` — a whole PGC season; the focused
/// episode is the first one.
fn inspect_pgc_season(
    api: &BilibiliApi,
    season_id: i64,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let season = match api.pgc_season(None, Some(season_id)) {
        Ok(season) => season,
        Err(error) => return view_failure_outcome("", "", &error),
    };
    inspect_pgc_episode_in_season(api, &season, None, request_context)
}

fn inspect_pgc_episode_in_season(
    api: &BilibiliApi,
    season: &PgcSeason,
    focused_ep_id: Option<i64>,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let current = focused_ep_id
        .and_then(|ep_id| {
            season
                .episodes
                .iter()
                .find(|episode| episode.ep_id == ep_id)
        })
        .or_else(|| season.episodes.first());

    // Extras (trailers, PVs) live outside `episodes`; they still play via
    // their own ep_id, so they are supported when explicitly linked.
    let playable_ep_id = focused_ep_id.or_else(|| current.map(|episode| episode.ep_id));
    let Some(playable_ep_id) = playable_ep_id else {
        return Ok(empty_update_result(
            "",
            &season.title,
            SiteWarning::site(
                "bilibili-season-empty",
                "This season does not expose any playable episodes",
            ),
        ));
    };

    let cid = current.map(|episode| episode.cid).unwrap_or(0);
    let page_url = url::episode_page_url(playable_ep_id);
    let candidate_title = current
        .map(compose_episode_title)
        .unwrap_or_else(|| format!("Episode {playable_ep_id}"));
    let collection = build_pgc_collection(season, current.map(|episode| episode.ep_id));

    let streams = match api.pgc_playurl(playable_ep_id, cid) {
        Ok(streams) => streams,
        Err(error) => {
            return Ok(playurl_failure_outcome(
                &page_url,
                &season.title,
                &error,
                Some(collection),
            ))
        }
    };

    let mut warnings = Vec::new();
    if let Some(episode) = current {
        if !episode.badge.is_empty() {
            warnings.push(SiteWarning::site(
                "bilibili-membership-badge",
                format!(
                    "Episode {} carries a \"{}\" badge; downloading it requires the matching account entitlements",
                    episode.ep_id, episode.badge
                ),
            ));
        }
    }
    let subtitles = current
        .filter(|episode| !episode.bvid.is_empty() && episode.cid > 0)
        .map(|episode| {
            fetch_subtitles(
                api,
                &episode.bvid,
                episode.cid,
                request_context,
                &mut warnings,
            )
        })
        .unwrap_or_default();
    Ok(ready_result(
        page_url,
        season.title.clone(),
        candidate_title,
        streams,
        subtitles,
        Some(collection),
        warnings,
        request_context,
    ))
}

/// `space.bilibili.com/{mid}/channel/…` — a channel collection or
/// uploader series; the focused episode is the first entry.
fn inspect_named_collection(
    api: &BilibiliApi,
    mid: i64,
    season_id: i64,
    kind: CollectionKind,
    current_bvid: Option<String>,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let metadata = CollectionMetadata {
        mid,
        season_id,
        kind,
        title: None,
    };
    let (title, archives) = match api.collection_archives(metadata) {
        Ok(result) => result,
        Err(error) => return view_failure_outcome("", "", &error),
    };
    inspect_archive_entry(api, title, archives, kind, current_bvid, request_context)
}

/// `www.bilibili.com/list/{mid}?sid=…` / `medialist/play/…` — a playlist
/// page whose id may address either a collection or a series.
fn inspect_playlist(
    api: &BilibiliApi,
    mid: Option<i64>,
    season_id: i64,
    current_bvid: Option<String>,
    current_aid: Option<i64>,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let probe = match api.probe_collection_kind(season_id) {
        Ok(probe) => probe,
        Err(error) => return view_failure_outcome("", "", &error),
    };
    let metadata = CollectionMetadata {
        mid: mid.or(probe.mid).unwrap_or(0),
        season_id,
        kind: probe.kind,
        title: probe.title,
    };
    let (title, archives) = match api.collection_archives(metadata) {
        Ok(result) => result,
        Err(error) => return view_failure_outcome("", "", &error),
    };

    // The link itself may pin a video; without one, focus the first entry.
    let current_bvid = current_bvid.or_else(|| {
        current_aid.and_then(|aid| {
            archives
                .iter()
                .find(|archive| archive.aid == aid)
                .map(|archive| archive.bvid.clone())
        })
    });
    inspect_archive_entry(
        api,
        title,
        archives,
        probe.kind,
        current_bvid,
        request_context,
    )
}

/// Shared tail for collection/series inspections: focus an archive entry,
/// resolve its streams, and build the result.
fn inspect_archive_entry(
    api: &BilibiliApi,
    collection_title: String,
    archives: Vec<CollectionArchive>,
    kind: CollectionKind,
    current_bvid: Option<String>,
    request_context: &RequestContext,
) -> Result<MediaInspectionResult> {
    let Some(first) = archives.first() else {
        return Ok(empty_update_result(
            "",
            &collection_title,
            SiteWarning::site(
                "bilibili-collection-empty",
                "This collection does not expose any videos",
            ),
        ));
    };
    let focused_bvid = current_bvid
        .filter(|bvid| archives.iter().any(|archive| &archive.bvid == bvid))
        .unwrap_or_else(|| first.bvid.clone());

    let view = match api.view(Some(&focused_bvid), None) {
        Ok(view) => view,
        Err(error) => return view_failure_outcome("", "", &error),
    };

    let page_url = url::video_page_url(&view.bvid, 1, view.pages.len().max(1));
    let collection = build_archive_collection(&collection_title, &archives, kind, &focused_bvid);

    let streams = match api.playurl(&view.bvid, view.cid) {
        Ok(streams) => streams,
        Err(error) => {
            return Ok(playurl_failure_outcome(
                &page_url,
                &view.title,
                &error,
                Some(collection),
            ))
        }
    };

    let mut warnings = Vec::new();
    let subtitles = fetch_subtitles(api, &view.bvid, view.cid, request_context, &mut warnings);
    Ok(ready_result(
        page_url,
        view.title.clone(),
        view.title,
        streams,
        subtitles,
        Some(collection),
        warnings,
        request_context,
    ))
}

/// Choose the part a request points at: an explicit `?p=` wins when it is
/// inside the part list, otherwise the first part is used with a warning
/// when the requested number was out of range.
fn select_part(view: &VideoView, requested: Option<u32>) -> (usize, Option<SiteWarning>) {
    if view.pages.len() <= 1 {
        return (0, None);
    }
    let Some(requested) = requested else {
        return (0, None);
    };
    match view.pages.iter().position(|page| page.page == requested) {
        Some(index) => (index, None),
        None => (
            0,
            Some(SiteWarning::site(
                "bilibili-part-out-of-range",
                format!(
                    "Part {requested} does not exist in this video ({} parts); the first part is used",
                    view.pages.len()
                ),
            )),
        ),
    }
}

fn build_video_collection(view: &VideoView, part_index: usize) -> Option<MediaCollection> {
    if let Some(season) = &view.season {
        let entries = season
            .episodes
            .iter()
            .enumerate()
            .map(|(position, episode)| MediaCollectionEntry {
                id: format!("{}:{}", episode.bvid, episode.cid),
                index: index_to_i32(position),
                title: collection_entry_title(&season.title, &episode.title, position),
                duration_seconds: episode.duration,
                page_url: url::video_page_url(&episode.bvid, 1, 1),
                available: !episode.bvid.is_empty(),
                unavailable_reason: String::new(),
                current: episode.bvid == view.bvid && part_index == 0,
            })
            .collect();
        return Some(MediaCollection {
            kind: "ugc_season".to_string(),
            title: season.title.clone(),
            entries,
        });
    }

    if view.pages.len() > 1 {
        let total_parts = view.pages.len();
        let entries = view
            .pages
            .iter()
            .enumerate()
            .map(|(position, page)| MediaCollectionEntry {
                id: format!("{}:{}", view.bvid, page.cid),
                index: index_to_i32(position),
                title: compose_part_label(page),
                duration_seconds: page.duration,
                page_url: url::video_page_url(&view.bvid, page.page, total_parts),
                available: page.cid > 0,
                unavailable_reason: String::new(),
                current: position == part_index,
            })
            .collect();
        return Some(MediaCollection {
            kind: "parts".to_string(),
            title: view.title.clone(),
            entries,
        });
    }

    None
}

fn build_pgc_collection(season: &PgcSeason, current_ep_id: Option<i64>) -> MediaCollection {
    let entries = season
        .episodes
        .iter()
        .enumerate()
        .map(|(position, episode)| MediaCollectionEntry {
            id: format!("ep:{}", episode.ep_id),
            index: index_to_i32(position),
            title: compose_episode_title(episode),
            duration_seconds: episode.duration,
            page_url: url::episode_page_url(episode.ep_id),
            available: episode.cid > 0 || !episode.bvid.is_empty(),
            unavailable_reason: episode.badge.clone(),
            current: current_ep_id == Some(episode.ep_id),
        })
        .collect();
    MediaCollection {
        kind: "pgc_season".to_string(),
        title: season.title.clone(),
        entries,
    }
}

fn build_archive_collection(
    title: &str,
    archives: &[CollectionArchive],
    kind: CollectionKind,
    focused_bvid: &str,
) -> MediaCollection {
    let entries = archives
        .iter()
        .enumerate()
        .map(|(position, archive)| MediaCollectionEntry {
            id: format!("{}:0", archive.bvid),
            index: index_to_i32(position),
            title: collection_entry_title(title, &archive.title, position),
            duration_seconds: archive.duration,
            page_url: url::video_page_url(&archive.bvid, 1, 1),
            available: true,
            unavailable_reason: String::new(),
            current: archive.bvid == focused_bvid,
        })
        .collect();
    MediaCollection {
        kind: match kind {
            CollectionKind::Season => "collection".to_string(),
            CollectionKind::Series => "series".to_string(),
        },
        title: title.to_string(),
        entries,
    }
}

/// Title for a candidate of the current part: `video · P2 part-name` for
/// multi-part uploads, the plain video title otherwise.
fn compose_part_title(video_title: &str, part: Option<&VideoPage>, total_parts: usize) -> String {
    match part {
        Some(page) if total_parts > 1 => {
            format!("{} · {}", video_title.trim(), compose_part_label(page))
        }
        _ => video_title.to_string(),
    }
}

/// `P2`, `P2 part-name` — without duplicating a part title that is already
/// just the number.
fn compose_part_label(page: &VideoPage) -> String {
    let label = format!("P{}", page.page);
    let part = page.title.trim();
    if part.is_empty() || part == label || part == page.page.to_string() {
        label
    } else {
        format!("{label} {part}")
    }
}

/// `第1话 启程` — episode title plus long title, each added once.
fn compose_episode_title(episode: &PgcEpisode) -> String {
    let mut segments = Vec::new();
    push_unique_segment(&mut segments, Some(&episode.title));
    push_unique_segment(&mut segments, Some(&episode.long_title));
    if segments.is_empty() {
        format!("Episode {}", episode.ep_id)
    } else {
        segments.join(" ")
    }
}

fn push_unique_segment(segments: &mut Vec<String>, value: Option<&str>) {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return;
    };
    if segments
        .iter()
        .any(|segment| segment == value || segment.contains(value) || value.contains(segment))
    {
        return;
    }
    segments.push(value.to_string());
}

/// Drop a collection-name prefix from an episode title so the UI can pair
/// collection + entry without repeating "空中浩劫 - 空中浩劫 …".
fn collapse_prefix(prefix: &str, title: &str) -> String {
    let title = title.trim();
    let prefix = prefix.trim();
    if prefix.is_empty() {
        return title.to_string();
    }
    let Some(rest) = title.strip_prefix(prefix) else {
        return title.to_string();
    };
    let rest = rest.trim_start_matches(|ch: char| {
        ch.is_whitespace() || matches!(ch, '-' | '·' | ':' | '：' | '|' | '_' | '/')
    });
    if rest.is_empty() {
        title.to_string()
    } else {
        rest.to_string()
    }
}

/// An entry title that is never empty (used for file naming).
fn collection_entry_title(prefix: &str, title: &str, position: usize) -> String {
    let collapsed = collapse_prefix(prefix, title);
    if collapsed.trim().is_empty() {
        format!("Episode {}", index_to_i32(position))
    } else {
        collapsed
    }
}

fn index_to_i32(index: usize) -> i32 {
    i32::try_from(index + 1).unwrap_or(i32::MAX)
}

/// Assemble a result with candidates from a stream set.
#[allow(clippy::too_many_arguments)]
fn ready_result(
    page_url: String,
    page_title: String,
    candidate_title: String,
    streams: DashStreams,
    subtitles: Vec<MediaSubtitleTrack>,
    collection: Option<MediaCollection>,
    mut warnings: Vec<SiteWarning>,
    request_context: &RequestContext,
) -> MediaInspectionResult {
    push_quality_access_hint(&streams, request_context, &mut warnings);

    let mut collector = CandidateCollector::new(&page_url, &page_title, "bilibili");
    stream::collect_stream_candidates(&mut collector, &candidate_title, &streams, &mut warnings);
    let candidates = score_candidates(collector.finish(), request_context);
    if candidates.is_empty() {
        warnings.push(SiteWarning::media(
            "bilibili-no-candidates",
            "The playurl API exposed no downloadable streams for this episode",
        ));
    }

    MediaInspectionResult {
        page_url,
        page_title,
        extractor: "bilibili".to_string(),
        candidates,
        subtitles,
        warnings: warnings
            .into_iter()
            .map(SiteWarning::into_display)
            .collect(),
        auth_required: false,
        challenge_reason: String::new(),
        collection,
    }
}

/// Subtitle tracks for one episode, as the account may read them.
///
/// The list is entitlement-scoped exactly like the streams: an anonymous
/// session receives an empty list, so an empty result is annotated with a
/// sign-in hint instead of being silently indistinguishable from "this
/// video has no subtitles". A failure never breaks the inspection — the
/// episode's streams are what the caller needs; subtitles are metadata.
fn fetch_subtitles(
    api: &BilibiliApi,
    bvid: &str,
    cid: i64,
    request_context: &RequestContext,
    warnings: &mut Vec<SiteWarning>,
) -> Vec<MediaSubtitleTrack> {
    if bvid.is_empty() || cid <= 0 {
        return Vec::new();
    }
    let list = match api.player_subtitles(bvid, cid) {
        Ok(list) => list,
        Err(error) => {
            debug!("Bilibili subtitle lookup failed for {bvid}/{cid}: {error:#}");
            return Vec::new();
        }
    };
    annotate_subtitle_list(&list, request_context, warnings);
    let default_index = list.default_index();
    list.tracks
        .iter()
        .enumerate()
        .map(|(index, track)| MediaSubtitleTrack {
            language: track.language.clone(),
            label: subtitle_label(track),
            url: track.url.clone(),
            selected: default_index == Some(index),
        })
        .collect()
}

fn subtitle_label(track: &SubtitleTrack) -> String {
    if !track.label.is_empty() {
        return track.label.clone();
    }
    if !track.language.is_empty() {
        return track.language.clone();
    }
    "Subtitle".to_string()
}

fn annotate_subtitle_list(
    list: &SubtitleList,
    request_context: &RequestContext,
    warnings: &mut Vec<SiteWarning>,
) {
    if !list.is_empty() || !request_context.cookie.trim().is_empty() {
        return;
    }
    warnings.push(SiteWarning::auth(
        "bilibili-subtitles-sign-in",
        "Bilibili returns no subtitle tracks to anonymous sessions; sign in to receive the episode's subtitles (AI-generated tracks included)",
    ));
}

/// Whether a URL addresses a Bilibili page the subtitle resolver handles.
pub(crate) fn is_bilibili_page(page_url: &str) -> bool {
    let Ok(url) = Url::parse(page_url) else {
        return false;
    };
    let Some(host) = url.host_str() else {
        return false;
    };
    let host = host.to_ascii_lowercase();
    host == "bilibili.com"
        || host.ends_with(".bilibili.com")
        || host == "b23.tv"
        || host.ends_with(".b23.tv")
}

/// The subtitle a download should write next to its video file.
pub(crate) struct ResolvedSubtitle {
    pub label: String,
    pub srt: String,
}

/// Resolve and fetch the subtitle track of a canonical video or episode
/// page (`…/video/BV…?p=n`, `…/bangumi/play/ep…`).
///
/// `preferred_language` carries the account's pick across a series queue:
/// when the episode offers that `lan` tag it wins, otherwise the episode's
/// own default track is used. `None` asks for the default directly.
///
/// `Ok(None)` covers every "nothing to save" outcome — unsupported page
/// shape, no track visible to this session, or an episode without
/// subtitles. Subtitle metadata never blocks a download, so the caller
/// reports it and moves on.
pub(crate) fn resolve_subtitle(
    page_url: &str,
    preferred_language: Option<&str>,
    request_context: &RequestContext,
) -> Result<Option<ResolvedSubtitle>> {
    if !is_bilibili_page(page_url) {
        return Ok(None);
    }
    let parsed = Url::parse(page_url).context("Invalid Bilibili URL")?;
    let api = BilibiliApi::new(request_context)?;
    let Some((_, target)) = api.resolve_target(&parsed)? else {
        return Ok(None);
    };
    let Some((bvid, cid)) = subtitle_target_ids(&api, &target)? else {
        return Ok(None);
    };
    let list = api.player_subtitles(&bvid, cid)?;
    let Some(track) = list.choose(preferred_language).cloned() else {
        return Ok(None);
    };
    let srt = fetch_subtitle_srt(&track, request_context)?;
    Ok(Some(ResolvedSubtitle {
        label: subtitle_label(&track),
        srt,
    }))
}

/// Fetch one subtitle document the caller named explicitly (the URL came
/// from an inspection result), without re-resolving the episode.
pub(crate) fn fetch_subtitle_by_url(
    url: &str,
    request_context: &RequestContext,
) -> Result<ResolvedSubtitle> {
    let url = url.trim();
    if url.is_empty() {
        bail!("Subtitle track URL is empty");
    }
    let track = SubtitleTrack {
        id: 0,
        language: String::new(),
        label: String::new(),
        url: url.to_string(),
    };
    let srt = fetch_subtitle_srt(&track, request_context)?;
    Ok(ResolvedSubtitle {
        label: subtitle_label(&track),
        srt,
    })
}

/// The `(bvid, cid)` pair a subtitle lookup needs, for the page shapes
/// that can produce one.
fn subtitle_target_ids(api: &BilibiliApi, target: &Target) -> Result<Option<(String, i64)>> {
    match target {
        Target::Video { bvid, aid, page } => {
            let view = api.view(bvid.as_deref(), *aid)?;
            let (index, _) = select_part(&view, *page);
            let Some(part) = view.pages.get(index) else {
                return Ok(None);
            };
            if part.cid <= 0 {
                return Ok(None);
            }
            Ok(Some((view.bvid, part.cid)))
        }
        Target::Episode { ep_id } => {
            let season = api.pgc_season(Some(*ep_id), None)?;
            let Some(episode) = season.episodes.iter().find(|item| item.ep_id == *ep_id) else {
                return Ok(None);
            };
            if episode.bvid.is_empty() || episode.cid <= 0 {
                return Ok(None);
            }
            Ok(Some((episode.bvid.clone(), episode.cid)))
        }
        _ => Ok(None),
    }
}

/// Download one subtitle document and return its SRT text.
fn fetch_subtitle_srt(track: &SubtitleTrack, request_context: &RequestContext) -> Result<String> {
    let url = Url::parse(&track.url).context("Subtitle URL is invalid")?;
    let headers = crate::api::downloader::request_headers(&url, request_context)?;
    let client = SyncHttpClient::with_timeouts(Duration::from_secs(10), Duration::from_secs(30))?;
    let (status, _headers, body) = client.get(&track.url, &headers)?;
    if !(200..300).contains(&status) {
        bail!("Subtitle download failed with HTTP {status}");
    }
    let text = String::from_utf8_lossy(&body);
    let payload: Value =
        nextjson::from_str(&text).context("Subtitle document was not valid JSON")?;
    subtitle::body_to_srt(&payload, &subtitle_label(track))
}

/// Qualities the video offers but the current session cannot download are
/// named explicitly (they come straight from `support_formats`), instead
/// of silently capping the selection at 480P.
fn push_quality_access_hint(
    streams: &DashStreams,
    request_context: &RequestContext,
    warnings: &mut Vec<SiteWarning>,
) {
    let locked = stream::locked_quality_tiers(streams);
    if locked.is_empty() {
        return;
    }
    let locked = locked.join(" / ");
    if request_context.cookie.trim().is_empty() {
        warnings.push(SiteWarning::auth(
            "bilibili-login-for-hd",
            format!(
                "This video also offers {locked}; an anonymous session cannot download them. Sign in to a browser session and import its Cookie (a membership account also unlocks the 大会员 tiers)"
            ),
        ));
    } else {
        warnings.push(SiteWarning::auth(
            "bilibili-qualities-locked",
            format!(
                "This video also offers {locked}; the current account cannot download them (membership, region or entitlement gate)"
            ),
        ));
    }
}

/// A view-level failure: access denials become the "authorize" flow,
/// everything else (missing video, bad id) is a hard error.
fn view_failure_outcome(
    page_url: &str,
    page_title: &str,
    error: &anyhow::Error,
) -> Result<MediaInspectionResult> {
    if let Some(access) = error.downcast_ref::<BilibiliAccessError>() {
        return Ok(MediaInspectionResult {
            page_url: page_url.to_string(),
            page_title: page_title.to_string(),
            extractor: "bilibili".to_string(),
            candidates: Vec::new(),
            subtitles: Vec::new(),
            warnings: vec![
                SiteWarning::auth("bilibili-access-denied", error.to_string()).into_display(),
            ],
            auth_required: true,
            challenge_reason: access.0.clone(),
            collection: None,
        });
    }
    Err(anyhow::anyhow!("{error:#}"))
}

/// A playurl failure after metadata succeeded: the collection is still
/// shown, and the reason lands in the warnings.
fn playurl_failure_outcome(
    page_url: &str,
    page_title: &str,
    error: &anyhow::Error,
    collection: Option<MediaCollection>,
) -> MediaInspectionResult {
    let access = error.downcast_ref::<BilibiliAccessError>();
    let warning = match access {
        Some(_) => SiteWarning::auth("bilibili-access-denied", error.to_string()),
        None => SiteWarning::site("bilibili-streams-unavailable", error.to_string()),
    };
    MediaInspectionResult {
        page_url: page_url.to_string(),
        page_title: page_title.to_string(),
        extractor: "bilibili".to_string(),
        candidates: Vec::new(),
        subtitles: Vec::new(),
        warnings: vec![warning.into_display()],
        auth_required: access.is_some(),
        challenge_reason: access.map(|access| access.0.clone()).unwrap_or_default(),
        collection,
    }
}

/// A successful-resolution-but-empty outcome (empty collection, …).
fn empty_update_result(
    page_url: &str,
    page_title: &str,
    warning: SiteWarning,
) -> MediaInspectionResult {
    MediaInspectionResult {
        page_url: page_url.to_string(),
        page_title: page_title.to_string(),
        extractor: "bilibili".to_string(),
        candidates: Vec::new(),
        subtitles: Vec::new(),
        warnings: vec![warning.into_display()],
        auth_required: false,
        challenge_reason: String::new(),
        collection: None,
    }
}

#[cfg(test)]
mod tests {
    use super::collapse_prefix;
    use crate::api::downloader::{MediaInspectionResult, RequestContext};

    #[test]
    fn collapse_prefix_strips_redundant_series_names() {
        assert_eq!(
            collapse_prefix("空中浩劫", "空中浩劫 S23E01 标题"),
            "S23E01 标题"
        );
        // A separator directly after the prefix is dropped too.
        assert_eq!(collapse_prefix("T", "T - Part"), "Part");
        // Not a prefix; the title is untouched.
        assert_eq!(collapse_prefix("A", "B title"), "B title");
        // All-prefix titles stay intact instead of becoming empty.
        assert_eq!(collapse_prefix("Only", "Only"), "Only");
    }

    /// Live end-to-end probe: resolves a real Bilibili URL through the
    /// exact pipeline the app uses (URL parse → WBI-signed API calls →
    /// candidate building). Network-dependent, so it is ignored by
    /// default; enable it manually with:
    ///
    /// ```text
    /// set SEGMERIS_BILIBILI_PROBE_URL=https://www.bilibili.com/video/BV...
    /// cargo test -p rust_lib_segmeris live_bilibili_probe -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "network probe; set SEGMERIS_BILIBILI_PROBE_URL to enable"]
    fn live_bilibili_probe() {
        let Ok(url) = std::env::var("SEGMERIS_BILIBILI_PROBE_URL") else {
            eprintln!("SEGMERIS_BILIBILI_PROBE_URL is not set; nothing to probe");
            return;
        };

        let result: MediaInspectionResult =
            super::inspect_bilibili(&url, &RequestContext::default())
                .expect("live Bilibili inspection must succeed");

        eprintln!("page_url      = {}", result.page_url);
        eprintln!("page_title    = {}", result.page_title);
        eprintln!("candidates    = {}", result.candidates.len());
        for candidate in &result.candidates {
            eprintln!(
                "  - [{}] badge={:?} codec={:?} ({}x{}) audio={} {}",
                candidate.quality_label,
                candidate.quality_badge,
                candidate.codec,
                candidate.width,
                candidate.height,
                candidate.audio_url.is_some(),
                candidate.media_url
            );
        }
        if let Some(collection) = &result.collection {
            eprintln!(
                "collection    = {} · {} · {} entries",
                collection.kind,
                collection.title,
                collection.entries.len()
            );
        }
        eprintln!("subtitles     = {}", result.subtitles.len());
        for track in &result.subtitles {
            eprintln!(
                "  - [{}] {} selected={} {}",
                track.language, track.label, track.selected, track.url
            );
        }
        for warning in &result.warnings {
            eprintln!("warning: {warning}");
        }

        // Exercise the download-time subtitle resolver too: for an
        // anonymous session it must report "nothing to save" instead of
        // failing, which is the contract the download pipeline relies on.
        match super::resolve_subtitle(&result.page_url, None, &RequestContext::default()) {
            Ok(Some(subtitle)) => eprintln!(
                "default subtitle = {} ({} bytes of SRT)",
                subtitle.label,
                subtitle.srt.len()
            ),
            Ok(None) => eprintln!("default subtitle = none for this session"),
            Err(error) => eprintln!("default subtitle = failed: {error:#}"),
        }

        assert_eq!(result.extractor, "bilibili");
        assert!(
            !result.candidates.is_empty(),
            "the probe video should expose at least one stream"
        );
        assert!(
            result
                .candidates
                .iter()
                .any(|candidate| candidate.audio_url.is_some()),
            "the probe video should expose a paired audio track"
        );
    }
}
