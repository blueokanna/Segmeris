use std::collections::HashMap;

use nextjson::{NsonDeserialize, NsonSerialize};
use tzcraft::Zoned;

use crate::api::downloader::{
    HeaderEntry, MediaCandidate, MediaCollection, MediaInspectionResult, MediaSubtitleTrack,
    RequestContext, SubtitleMode,
};

#[derive(Debug, Clone, NsonDeserialize)]
pub struct DownloadRequest {
    pub url: String,
    pub media_url: Option<String>,
    pub audio_url: Option<String>,
    pub output_filename: Option<String>,
    pub concurrency: Option<u32>,
    pub retries: Option<u32>,
    pub video_bitrate: Option<u32>,
    pub audio_bitrate: Option<u32>,
    pub keep_temp: Option<bool>,
    pub subtitle: Option<SubtitleSelectionJson>,
    pub request_context: Option<ApiRequestContext>,
}

/// Subtitle choice as it travels over HTTP.
///
/// `mode` is the discriminant (`auto` / `off` / `track` / `language`) and
/// `value` carries the track URL or the `lan` tag. One shape instead of
/// four optional fields keeps the payload unambiguous, and unknown modes
/// are rejected instead of silently falling back to a default.
#[derive(Debug, Clone, NsonDeserialize)]
pub struct SubtitleSelectionJson {
    pub mode: String,
    pub value: Option<String>,
}

impl SubtitleSelectionJson {
    /// Validate the payload and split it into the engine's option pair.
    ///
    /// The mode/value parsing is shared with the FFI contract
    /// ([`SubtitleMode::to_choice`]), so both transports accept exactly the
    /// same thing; validation happens here so a bad request fails as a
    /// request error instead of a download failure.
    pub fn resolve(&self) -> Result<(SubtitleMode, String), String> {
        let mode: SubtitleMode = self.mode.parse()?;
        let value = self.value.clone().unwrap_or_default();
        mode.to_choice(&value)?;
        Ok((mode, value))
    }
}

#[derive(Debug, Clone, Default, NsonDeserialize)]
pub struct ApiRequestContext {
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub origin: Option<String>,
    pub cookie: Option<String>,
    pub headers: Option<HashMap<String, String>>,
}

impl From<ApiRequestContext> for RequestContext {
    fn from(value: ApiRequestContext) -> Self {
        let headers = value
            .headers
            .unwrap_or_default()
            .into_iter()
            .map(|(name, value)| HeaderEntry { name, value })
            .collect();

        Self {
            user_agent: value.user_agent.unwrap_or_default(),
            referer: value.referer.unwrap_or_default(),
            origin: value.origin.unwrap_or_default(),
            cookie: value.cookie.unwrap_or_default(),
            headers,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SubtitleSelectionJson;
    use crate::api::downloader::SubtitleMode;

    fn selection(mode: &str, value: Option<&str>) -> SubtitleSelectionJson {
        SubtitleSelectionJson {
            mode: mode.to_string(),
            value: value.map(str::to_string),
        }
    }

    #[test]
    fn subtitle_payload_splits_into_engine_options() {
        assert_eq!(
            selection("auto", None).resolve().unwrap(),
            (SubtitleMode::Auto, String::new())
        );
        assert_eq!(
            selection("OFF", None).resolve().unwrap(),
            (SubtitleMode::Off, String::new())
        );
        let (mode, value) = selection("language", Some(" en-US ")).resolve().unwrap();
        assert_eq!(mode, SubtitleMode::Language);
        assert_eq!(value, " en-US ");
        let (mode, value) = selection("track", Some("https://i0.hdslb.com/1.json"))
            .resolve()
            .unwrap();
        assert_eq!(mode, SubtitleMode::Track);
        assert_eq!(value, "https://i0.hdslb.com/1.json");
    }

    #[test]
    fn subtitle_payload_rejects_unknown_modes_and_unsafe_urls() {
        assert!(selection("chinese", None).resolve().is_err());
        assert!(selection("track", None).resolve().is_err());
        assert!(selection("track", Some("http://i0.hdslb.com/1.json"))
            .resolve()
            .is_err());
        assert!(selection("language", Some("")).resolve().is_err());
    }
}

#[derive(Debug, Clone, NsonSerialize)]
pub struct DownloadStatus {
    pub task_id: String,
    pub status: String,
    pub message: String,
    pub progress_percent: Option<f64>,
    pub source_url: String,
    pub output_path: Option<String>,
    pub error: Option<String>,
    pub created_at: Zoned,
    pub completed_at: Option<Zoned>,
}

/// Request body of `POST /inspect`.
#[derive(Debug, Clone, NsonDeserialize)]
pub struct InspectRequest {
    pub url: String,
    pub request_context: Option<ApiRequestContext>,
}

/// JSON snapshot of `MediaInspectionResult` returned by `POST /inspect`.
/// The web client reconstructs the same model the native UI uses, so the
/// browser build can reuse the full analysis pipeline (via the API server).
#[derive(Debug, Clone, NsonSerialize)]
pub struct InspectionResponse {
    pub page_url: String,
    pub page_title: String,
    pub extractor: String,
    pub candidates: Vec<CandidateJson>,
    pub subtitles: Vec<SubtitleTrackJson>,
    pub warnings: Vec<String>,
    pub auth_required: bool,
    pub challenge_reason: String,
    pub collection: Option<CollectionJson>,
}

/// JSON snapshot of `MediaSubtitleTrack`.
#[derive(Debug, Clone, NsonSerialize)]
pub struct SubtitleTrackJson {
    pub language: String,
    pub label: String,
    pub url: String,
    pub selected: bool,
}

impl From<&MediaSubtitleTrack> for SubtitleTrackJson {
    fn from(track: &MediaSubtitleTrack) -> Self {
        Self {
            language: track.language.clone(),
            label: track.label.clone(),
            url: track.url.clone(),
            selected: track.selected,
        }
    }
}

/// JSON snapshot of `MediaCollection` (the episode list a series download
/// iterates over).
#[derive(Debug, Clone, NsonSerialize)]
pub struct CollectionJson {
    pub kind: String,
    pub title: String,
    pub entries: Vec<CollectionEntryJson>,
}

/// JSON snapshot of `MediaCollectionEntry`.
#[derive(Debug, Clone, NsonSerialize)]
pub struct CollectionEntryJson {
    pub id: String,
    pub index: i32,
    pub title: String,
    pub duration_seconds: f64,
    pub page_url: String,
    pub available: bool,
    pub unavailable_reason: String,
    pub current: bool,
}

impl From<&MediaCollection> for CollectionJson {
    fn from(collection: &MediaCollection) -> Self {
        Self {
            kind: collection.kind.clone(),
            title: collection.title.clone(),
            entries: collection
                .entries
                .iter()
                .map(|entry| CollectionEntryJson {
                    id: entry.id.clone(),
                    index: entry.index,
                    title: entry.title.clone(),
                    duration_seconds: entry.duration_seconds,
                    page_url: entry.page_url.clone(),
                    available: entry.available,
                    unavailable_reason: entry.unavailable_reason.clone(),
                    current: entry.current,
                })
                .collect(),
        }
    }
}

/// JSON snapshot of `MediaCandidate` (snake_case keys for the web client).
#[derive(Debug, Clone, NsonSerialize)]
pub struct CandidateJson {
    pub id: String,
    pub title: String,
    pub extractor: String,
    pub page_url: String,
    pub media_url: String,
    pub audio_url: Option<String>,
    pub container: String,
    pub protocol: String,
    pub mime_type: String,
    pub quality_label: String,
    pub quality_badge: String,
    pub codec: String,
    pub width: i32,
    pub height: i32,
    pub requires_ffmpeg: bool,
    pub score: i32,
    pub segment_count: i32,
    pub duration_seconds: f64,
    pub primary: bool,
    pub reason: String,
}

impl From<&MediaCandidate> for CandidateJson {
    fn from(candidate: &MediaCandidate) -> Self {
        Self {
            id: candidate.id.clone(),
            title: candidate.title.clone(),
            extractor: candidate.extractor.clone(),
            page_url: candidate.page_url.clone(),
            media_url: candidate.media_url.clone(),
            audio_url: candidate.audio_url.clone(),
            container: candidate.container.clone(),
            protocol: candidate.protocol.clone(),
            mime_type: candidate.mime_type.clone(),
            quality_label: candidate.quality_label.clone(),
            quality_badge: candidate.quality_badge.clone(),
            codec: candidate.codec.clone(),
            width: candidate.width,
            height: candidate.height,
            requires_ffmpeg: candidate.requires_ffmpeg,
            score: candidate.score,
            segment_count: candidate.segment_count,
            duration_seconds: candidate.duration_seconds,
            primary: candidate.primary,
            reason: candidate.reason.clone(),
        }
    }
}

impl From<&MediaInspectionResult> for InspectionResponse {
    fn from(result: &MediaInspectionResult) -> Self {
        Self {
            page_url: result.page_url.clone(),
            page_title: result.page_title.clone(),
            extractor: result.extractor.clone(),
            candidates: result.candidates.iter().map(CandidateJson::from).collect(),
            subtitles: result
                .subtitles
                .iter()
                .map(SubtitleTrackJson::from)
                .collect(),
            warnings: result.warnings.clone(),
            auth_required: result.auth_required,
            challenge_reason: result.challenge_reason.clone(),
            collection: result.collection.as_ref().map(CollectionJson::from),
        }
    }
}

impl DownloadStatus {
    pub fn queued(task_id: String, source_url: String) -> Self {
        let now = Zoned::now_utc()
            .unwrap_or_else(|_| Zoned::from_ticks(tzcraft::Ticks::EPOCH, tzcraft::Zone::Utc));
        Self {
            task_id,
            status: "queued".to_string(),
            message: "Task queued".to_string(),
            progress_percent: Some(0.0),
            source_url,
            output_path: None,
            error: None,
            created_at: now,
            completed_at: None,
        }
    }
}
