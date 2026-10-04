//! Bilibili subtitles: `player/v2` track metadata and `.bcc` → SRT.
//!
//! ## Where subtitles come from
//!
//! `x/player/v2?bvid=&cid=` returns, per episode:
//!
//! ```json
//! { "code": 0, "data": { "subtitle": {
//!     "allow_submit": false,
//!     "lan": "", "lan_doc": "",
//!     "subtitles": [
//!       { "id": 123, "lan": "zh-CN", "lan_doc": "中文（自动生成）",
//!         "ai_status": 1, "ai_type": 1, "type": 0,
//!         "subtitle_url": "//aisubtitle.hdslb.com/bfs/ai_subtitle/....json" }
//!     ] } } }
//! ```
//!
//! The list itself is entitlement-scoped exactly like the streams: an
//! anonymous session receives an empty `subtitles` array, a signed-in one
//! receives the tracks it may read (including AI-generated ones). Nothing
//! here tries to work around that — an empty list is reported as such.
//!
//! Each `subtitle_url` points at a JSON document whose `body` array holds
//! `{from, to, content}` entries with second-precision floats:
//!
//! ```json
//! { "font_size": 0.4, "font_color": "#FFFFFF", "background_alpha": 0.5,
//!   "background_color": "#9C27B0", "Stroke": "none",
//!   "body": [ { "from": 0.53, "to": 3.2, "location": 2, "content": "…" } ] }
//! ```
//!
//! Both shapes are wire facts (they are what the web player consumes), and
//! both parsers below are network-free so they stay unit tested.

use anyhow::{bail, Context, Result};
use nextjson::Value;

/// One subtitle track as `player/v2` describes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SubtitleTrack {
    pub id: i64,
    /// BCP-47-ish language tag (`zh-CN`, `en-US`, `ai-zh`, …).
    pub language: String,
    /// Human label the site shows (`中文（自动生成）`, `English`, …).
    pub label: String,
    /// Absolute HTTPS URL of the subtitle JSON.
    pub url: String,
}

/// The subtitle section of one episode.
#[derive(Clone, Debug, Default)]
pub(crate) struct SubtitleList {
    pub tracks: Vec<SubtitleTrack>,
    /// The language the account currently has selected (`subtitle.lan`),
    /// empty when the account has none.
    pub selected_language: String,
}

impl SubtitleList {
    /// Whether the account may submit subtitles on this episode; only
    /// meaningful for signed-in sessions, but it confirms the response was
    /// understood rather than empty.
    pub fn is_empty(&self) -> bool {
        self.tracks.is_empty()
    }

    /// The track a download should use, in falling order of authority:
    /// the language the account itself has selected, then a track whose
    /// label does not advertise auto-generation, then list order.
    ///
    /// Auto-generated tracks are not deprioritised because they are
    /// "wrong" — Bilibili labels them itself in `lan_doc` — but because a
    /// human-authored track of the same episode is the better default
    /// when the account expressed no preference.
    pub fn default_track(&self) -> Option<&SubtitleTrack> {
        self.default_index().map(|index| &self.tracks[index])
    }

    /// Position of [`Self::default_track`] inside [`Self::tracks`].
    pub fn default_index(&self) -> Option<usize> {
        if !self.selected_language.is_empty() {
            if let Some(index) = self
                .tracks
                .iter()
                .position(|track| track.language == self.selected_language)
            {
                return Some(index);
            }
        }
        self.tracks
            .iter()
            .position(|track| !looks_auto_generated(&track.label))
            .or(if self.tracks.is_empty() {
                None
            } else {
                Some(0)
            })
    }

    /// The track a download should save: an explicit language preference
    /// first (a series queue holds one language across episodes), then the
    /// episode's own default.
    pub fn choose(&self, preferred_language: Option<&str>) -> Option<&SubtitleTrack> {
        if let Some(tag) = preferred_language
            .map(str::trim)
            .filter(|tag| !tag.is_empty())
        {
            if let Some(track) = self.tracks.iter().find(|track| track.language == tag) {
                return Some(track);
            }
        }
        self.default_track()
    }
}

/// `lan_doc` marks AI subtitles with a parenthesised note (`（自动生成）`,
/// `(auto-generated)`, `AI`) in every locale observed; the raw
/// `ai_status`/`ai_type` fields are not documented well enough to be
/// relied on, so the label is the signal used for ordering only.
fn looks_auto_generated(label: &str) -> bool {
    let lower = label.to_ascii_lowercase();
    lower.contains("auto")
        || lower.contains("ai-")
        || lower.contains("ai ")
        || label.contains("自动生成")
        || label.contains("自動生成")
        || label.contains("자동 생성")
}

/// Parse the `player/v2` payload into the track list.
pub(crate) fn parse_player_subtitles(payload: &Value) -> Result<SubtitleList> {
    ok_or_api_error(payload)?;
    let subtitle = payload.pointer("/data/subtitle");
    let Some(subtitle) = subtitle else {
        return Ok(SubtitleList::default());
    };

    let mut list = SubtitleList {
        selected_language: subtitle
            .get("lan")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        ..SubtitleList::default()
    };

    if let Some(items) = subtitle.get("subtitles").and_then(Value::as_array) {
        for item in items {
            if let Some(track) = parse_track(item) {
                list.tracks.push(track);
            }
        }
    }
    Ok(list)
}

fn parse_track(value: &Value) -> Option<SubtitleTrack> {
    let url = value
        .get("subtitle_url")
        .or_else(|| value.get("subtitleUrl"))
        .and_then(Value::as_str)
        .map(normalize_subtitle_url)?;
    if url.is_empty() {
        return None;
    }
    let label = value
        .get("lan_doc")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    let language = value
        .get("lan")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    Some(SubtitleTrack {
        id: value.get("id").and_then(Value::as_i64).unwrap_or(0),
        language,
        label,
        url,
    })
}

/// Subtitle URLs are served protocol-relative (`//aisubtitle…`); TLS is
/// available everywhere they point, and a plain-http subtitle next to an
/// https video would be blocked as mixed content on the web build.
fn normalize_subtitle_url(url: &str) -> String {
    let url = url.trim();
    if let Some(rest) = url.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = url.strip_prefix("http://") {
        format!("https://{rest}")
    } else {
        url.to_string()
    }
}

/// The subtitle JSON body → SRT text.
///
/// Entries with a non-positive duration or no text are dropped rather than
/// padded, and entries are emitted in chronological order because SRT
/// readers assume a monotonic timeline.
pub(crate) fn body_to_srt(payload: &Value, context: &str) -> Result<String> {
    let body = payload.get("body").and_then(Value::as_array).context(
        "subtitle document did not contain a body array; the track may have been removed",
    )?;

    let mut lines: Vec<(f64, f64, String)> = Vec::new();
    for entry in body {
        let from = entry.get("from").and_then(Value::as_f64).unwrap_or(-1.0);
        let to = entry.get("to").and_then(Value::as_f64).unwrap_or(-1.0);
        let content = entry
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if from < 0.0 || to <= from || content.is_empty() {
            continue;
        }
        lines.push((from, to, content));
    }

    if lines.is_empty() {
        bail!("subtitle document {context} carried no usable cues");
    }
    lines.sort_by(|left, right| left.0.total_cmp(&right.0));

    let mut out = String::with_capacity(lines.len() * 96);
    for (index, (from, to, content)) in lines.iter().enumerate() {
        out.push_str(&(index + 1).to_string());
        out.push('\n');
        out.push_str(&format_timestamp(*from));
        out.push_str(" --> ");
        out.push_str(&format_timestamp(*to));
        out.push('\n');
        out.push_str(content);
        out.push_str("\n\n");
    }
    Ok(out)
}

/// `HH:MM:SS,mmm`, SRT's only accepted timestamp shape.
fn format_timestamp(seconds: f64) -> String {
    let total_ms = (seconds * 1000.0).round().max(0.0) as u64;
    let hours = total_ms / 3_600_000;
    let minutes = (total_ms / 60_000) % 60;
    let secs = (total_ms / 1_000) % 60;
    let millis = total_ms % 1_000;
    format!("{hours:02}:{minutes:02}:{secs:02},{millis:03}")
}

/// `code` must be 0; the message is surfaced verbatim when it is not.
fn ok_or_api_error(payload: &Value) -> Result<()> {
    let code = payload.get("code").and_then(Value::as_i64).unwrap_or(0);
    if code == 0 {
        return Ok(());
    }
    let message = payload
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown error");
    bail!("Bilibili subtitle API rejected the request (code {code}: {message})")
}

#[cfg(test)]
mod tests {
    use super::{body_to_srt, parse_player_subtitles};
    use nextjson::Value;

    fn parse_json(text: &str) -> Value {
        nextjson::from_str::<Value>(text).expect("fixture must be valid JSON")
    }

    #[test]
    fn parses_tracks_and_prefers_the_account_selection() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "data": {
                    "subtitle": {
                        "allow_submit": false,
                        "lan": "en-US",
                        "lan_doc": "English",
                        "subtitles": [
                            { "id": 1, "lan": "zh-CN", "lan_doc": "中文（自动生成）",
                              "subtitle_url": "//aisubtitle.hdslb.com/bfs/ai_subtitle/1.json" },
                            { "id": 2, "lan": "en-US", "lan_doc": "English",
                              "subtitle_url": "https://i0.hdslb.com/bfs/subtitle/2.json" }
                        ]
                    }
                }
            }"#,
        );

        let list = parse_player_subtitles(&payload).expect("payload must parse");
        assert_eq!(list.tracks.len(), 2);
        assert_eq!(list.selected_language, "en-US");
        assert_eq!(
            list.tracks[0].url,
            "https://aisubtitle.hdslb.com/bfs/ai_subtitle/1.json"
        );
        assert_eq!(
            list.tracks[1].url,
            "https://i0.hdslb.com/bfs/subtitle/2.json"
        );
        assert_eq!(
            list.default_track().map(|track| track.language.as_str()),
            Some("en-US")
        );
    }

    #[test]
    fn falls_back_to_a_human_track_before_an_auto_generated_one() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "data": { "subtitle": {
                    "lan": "",
                    "subtitles": [
                        { "id": 1, "lan": "ai-zh", "lan_doc": "中文（自动生成）",
                          "subtitle_url": "https://example/ai.json" },
                        { "id": 2, "lan": "zh-Hans", "lan_doc": "中文（简体）",
                          "subtitle_url": "https://example/manual.json" }
                    ] } }
            }"#,
        );

        let list = parse_player_subtitles(&payload).expect("payload must parse");
        assert_eq!(
            list.default_track().map(|track| track.label.as_str()),
            Some("中文（简体）")
        );
    }

    #[test]
    fn prefers_the_requested_language_and_falls_back_to_the_default() {
        let payload = parse_json(
            r#"{
                "code": 0,
                "data": { "subtitle": {
                    "lan": "",
                    "subtitles": [
                        { "id": 1, "lan": "zh-CN", "lan_doc": "中文（自动生成）",
                          "subtitle_url": "https://example/zh.json" },
                        { "id": 2, "lan": "en-US", "lan_doc": "English",
                          "subtitle_url": "https://example/en.json" }
                    ] } }
            }"#,
        );

        let list = parse_player_subtitles(&payload).expect("payload must parse");
        // An explicit preference wins over the account/default ordering.
        assert_eq!(
            list.choose(Some("zh-CN")).map(|track| track.url.as_str()),
            Some("https://example/zh.json")
        );
        // A language this episode does not offer falls back to the default
        // (the first non-auto-generated track), never to a wrong track.
        assert_eq!(
            list.choose(Some("ja-JP")).map(|track| track.url.as_str()),
            Some("https://example/en.json")
        );
        assert_eq!(
            list.choose(None).map(|track| track.url.as_str()),
            Some("https://example/en.json")
        );
        assert_eq!(
            list.choose(Some("   ")).map(|track| track.url.as_str()),
            Some("https://example/en.json")
        );
    }

    #[test]
    fn empty_subtitle_section_is_not_an_error() {
        let payload = parse_json(
            r#"{"code": 0, "message": "0", "data": {
                "subtitle": {"allow_submit": false, "lan": "", "lan_doc": "", "subtitles": []}
            }}"#,
        );
        let list = parse_player_subtitles(&payload).expect("empty list must parse");
        assert!(list.is_empty());
        assert!(list.default_track().is_none());
        assert!(list.choose(Some("zh-CN")).is_none());
    }

    #[test]
    fn surfaces_api_errors() {
        let payload = parse_json(r#"{"code": -400, "message": "请求错误"}"#);
        let error = parse_player_subtitles(&payload).expect_err("must fail");
        assert!(error.to_string().contains("-400"));
    }

    #[test]
    fn converts_a_body_to_srt() {
        let payload = parse_json(
            r#"{
                "font_size": 0.4,
                "body": [
                    { "from": 3.2, "to": 5.75, "location": 2, "content": "second line" },
                    { "from": 0.5, "to": 3.2, "location": 2, "content": "first line\ncontinued" },
                    { "from": 6.0, "to": 6.0, "location": 2, "content": "dropped: zero duration" },
                    { "from": 7.0, "to": 8.0, "location": 2, "content": "   " }
                ]
            }"#,
        );

        let srt = body_to_srt(&payload, "fixture").expect("body must convert");
        assert_eq!(
            srt,
            "1\n00:00:00,500 --> 00:00:03,200\nfirst line\ncontinued\n\n\
             2\n00:00:03,200 --> 00:00:05,750\nsecond line\n\n"
        );
    }

    #[test]
    fn formats_hour_long_timestamps_with_millisecond_precision() {
        let payload = parse_json(
            r#"{"body": [ { "from": 3725.04, "to": 3726.999, "content": "late cue" } ]}"#,
        );
        let srt = body_to_srt(&payload, "fixture").expect("body must convert");
        assert!(srt.contains("01:02:05,040 --> 01:02:06,999"));
    }

    #[test]
    fn rejects_a_body_without_usable_cues() {
        let payload = parse_json(r#"{"body": []}"#);
        assert!(body_to_srt(&payload, "fixture").is_err());
    }
}
