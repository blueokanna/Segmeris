//! Turning a parsed [`DashStreams`] set into downloader candidates.
//!
//! Bilibili exposes each quality tier as a separate video-only stream plus
//! a set of audio-only streams; the downloader's candidate model already
//! carries a `media_url` + `audio_url` pair, so each usable video tier
//! becomes one candidate with the best compatible AAC audio paired in.
//! Tier names come from the playurl `support_formats` list — the same
//! official naming (`1080P 高码率`, `4K 超高清`, …) and corner badges
//! (`大会员`, `60帧`, …) the web player shows — so the selection the
//! downloader offers matches what Bilibili itself advertises for the
//! signed-in account, including 4K / HDR / Dolby Vision / 8K for
//! membership sessions. Lossless (FLAC) and Dolby audio, when the account
//! may access them, are offered as explicit extras on top of the highest
//! video tier.
//!
//! Tiers the video advertises but the manifest does not contain are not
//! invented as candidates: [`locked_quality_tiers`] reports them so the
//! inspection can say *which* qualities a signed-in session would unlock.

use std::collections::HashSet;

use crate::api::downloader::{CandidateCollector, CandidateSpec};
use crate::api::site_adapters::SiteWarning;

use super::api::{DashMedia, DashStreams};

/// Fallback names for the stable public quality ids, used only when a
/// playurl response carries no `support_formats` (proxied or very old
/// responses). The wording follows Bilibili's own product naming.
fn fallback_quality_name(quality_id: i64) -> Option<&'static str> {
    Some(match quality_id {
        6 => "240P",
        16 => "360P 流畅",
        32 => "480P 标清",
        64 => "720P 准高清",
        74 => "720P 60帧",
        80 => "1080P 高清",
        100 => "智能修复",
        112 => "1080P 高码率",
        116 => "1080P 60帧",
        120 => "4K 超高清",
        125 => "HDR 真彩",
        126 => "杜比视界",
        127 => "8K 超高清",
        _ => return None,
    })
}

/// `AVC` / `HEVC` / `AV1`, named the way players and encoders do.
fn codec_name(codec_id: i64) -> Option<&'static str> {
    Some(match codec_id {
        7 => "AVC",
        12 => "HEVC",
        13 => "AV1",
        _ => return None,
    })
}

/// `codecid` is the authoritative signal, but responses occasionally only
/// carry the RFC 6381 codec string; its prefix is enough to name the
/// codec. Dolby Vision profiles ride on HEVC, so they report as HEVC.
fn codec_name_for(media: &DashMedia) -> Option<&'static str> {
    codec_name(media.codec_id).or_else(|| {
        let codecs = media.codecs.to_ascii_lowercase();
        if codecs.starts_with("avc1") || codecs.starts_with("avc3") {
            Some("AVC")
        } else if codecs.starts_with("hev1")
            || codecs.starts_with("hvc1")
            || codecs.starts_with("dvhe")
            || codecs.starts_with("dvh1")
        {
            Some("HEVC")
        } else if codecs.starts_with("av01") {
            Some("AV1")
        } else {
            None
        }
    })
}

/// Codec preference when one tier is offered with several encodings:
/// AVC plays everywhere, HEVC is broadly supported, AV1 is newest.
fn codec_priority(codec_id: i64) -> i32 {
    match codec_id {
        7 => 3,  // AVC
        12 => 2, // HEVC
        13 => 1, // AV1
        _ => 0,
    }
}

/// Human name of a tier, in falling order of authority: the official
/// `support_formats` description, the built-in table, the short display
/// form, and finally the raw resolution. A frame rate the name does not
/// already state is appended on the table/resolution paths.
fn quality_label(streams: &DashStreams, media: &DashMedia) -> String {
    let format = streams.format_for(media.quality_id);
    if let Some(description) = format
        .map(|format| format.description.as_str())
        .filter(|text| !text.is_empty())
    {
        return description.to_string();
    }
    if let Some(name) = fallback_quality_name(media.quality_id) {
        return with_frame_rate(name.to_string(), media.frame_rate);
    }
    if let Some(display) = format
        .map(|format| format.display.as_str())
        .filter(|text| !text.is_empty())
    {
        return with_frame_rate(display.to_string(), media.frame_rate);
    }
    if media.height > 0 {
        with_frame_rate(format!("{}p", media.height), media.frame_rate)
    } else {
        "Auto".to_string()
    }
}

fn with_frame_rate(label: String, frame_rate: f64) -> String {
    if frame_rate >= 48.0 && !label.contains('帧') {
        format!("{label} {}帧", frame_rate.round() as i64)
    } else {
        label
    }
}

/// The corner badge Bilibili publishes for a tier (`大会员`, `高码率`,
/// `60帧`, …). Badges the rendered name already spells out are dropped
/// instead of being shown twice.
fn quality_badge(streams: &DashStreams, media: &DashMedia, label: &str) -> Option<String> {
    let badge = streams.format_for(media.quality_id)?.badge.trim();
    if badge.is_empty() || label.contains(badge) {
        return None;
    }
    Some(badge.to_string())
}

/// Keep one stream per quality tier (highest codec priority wins), sorted
/// from best to worst.
fn dedupe_video_tiers(streams: &DashStreams) -> Vec<&DashMedia> {
    let mut by_quality: Vec<&DashMedia> = Vec::new();
    for media in &streams.video {
        match by_quality
            .iter_mut()
            .find(|kept| kept.quality_id == media.quality_id)
        {
            Some(kept) => {
                if codec_priority(media.codec_id) > codec_priority(kept.codec_id) {
                    *kept = media;
                }
            }
            None => by_quality.push(media),
        }
    }

    by_quality.sort_by(|left, right| {
        (right.height, right.bandwidth, right.quality_id).cmp(&(
            left.height,
            left.bandwidth,
            left.quality_id,
        ))
    });
    by_quality
}

/// Best plain AAC audio track (highest bandwidth).
fn best_audio(streams: &DashStreams) -> Option<&DashMedia> {
    streams
        .audio
        .iter()
        .filter(|media| !media.url.is_empty())
        .max_by_key(|media| media.bandwidth)
}

/// Quality tiers the video advertises in `support_formats` but the DASH
/// manifest does not contain: they exist, yet the current session may not
/// download them (sign-in, membership or region gate). Returned in
/// descending quality order, best first.
pub(crate) fn locked_quality_tiers(streams: &DashStreams) -> Vec<String> {
    if streams.video.is_empty() {
        return Vec::new();
    }
    let playable: HashSet<i64> = streams.video.iter().map(|media| media.quality_id).collect();
    let best_playable = streams
        .video
        .iter()
        .map(|media| media.quality_id)
        .max()
        .unwrap_or(0);
    let mut locked: Vec<&super::api::SupportFormat> = streams
        .formats
        .iter()
        .filter(|format| {
            format.quality_id > best_playable && !playable.contains(&format.quality_id)
        })
        .collect();
    locked.sort_by_key(|format| std::cmp::Reverse(format.quality_id));
    locked
        .into_iter()
        .filter_map(|format| format.name().map(str::to_string))
        .collect()
}

/// Emit one candidate per video tier (paired with the best AAC audio),
/// plus explicit FLAC / Dolby extras on the best tier, or progressive
/// fallback entries when no DASH manifest was usable.
pub(crate) fn collect_stream_candidates(
    collector: &mut CandidateCollector,
    title: &str,
    streams: &DashStreams,
    warnings: &mut Vec<SiteWarning>,
) {
    let audio = best_audio(streams).map(|media| media.url.clone());

    if !streams.video.is_empty() {
        if audio.is_none() {
            warnings.push(SiteWarning::media(
                "bilibili-audio-missing",
                "Bilibili exposed video streams without a reusable audio track; files will be silent",
            ));
        }

        let tiers = dedupe_video_tiers(streams);
        for media in &tiers {
            let label = quality_label(streams, media);
            collector.push(CandidateSpec {
                media_url: media.url.clone(),
                audio_url: audio.clone(),
                title: Some(title.to_string()),
                quality_badge: quality_badge(streams, media, &label),
                codec: codec_name_for(media).map(str::to_string),
                quality_label: Some(label),
                mime_type: Some(if media.mime_type.is_empty() {
                    "video/mp4".to_string()
                } else {
                    media.mime_type.clone()
                }),
                width: Some(media.width as i32),
                height: Some(media.height as i32),
                extractor: Some("bilibili"),
            });
        }

        let best_url = tiers.first().map(|media| media.url.clone());

        // Which audio extras can end up in the MP4 is decided by the muxer,
        // not by the entitlement: FFmpeg (desktop / API server) carries FLAC
        // and EC-3, the Android and iOS native muxers do not — offering them
        // there would guarantee a failed merge, so they are reported instead
        // of offered.
        let native_muxer_limits_audio = cfg!(any(target_os = "android", target_os = "ios"));
        if native_muxer_limits_audio {
            if streams.flac.is_some() || streams.dolby.is_some() {
                warnings.push(SiteWarning::media(
                    "bilibili-lossless-audio-unavailable",
                    "Hi-Res lossless and Dolby Atmos audio tracks are not offered on this platform: its MP4 muxer cannot carry FLAC or EC-3. The AAC track is used; desktop builds and the API server can mux them",
                ));
            }
            return;
        }

        if let (Some(best_url), Some(flac)) = (best_url.as_ref(), streams.flac.as_ref()) {
            collector.push(CandidateSpec {
                media_url: best_url.clone(),
                audio_url: Some(flac.url.clone()),
                title: Some(title.to_string()),
                quality_label: Some("Hi-Res 无损".to_string()),
                mime_type: Some("video/mp4".to_string()),
                extractor: Some("bilibili"),
                ..CandidateSpec::default()
            });
        }

        if let (Some(best_url), Some(dolby)) = (best_url.as_ref(), streams.dolby.as_ref()) {
            collector.push(CandidateSpec {
                media_url: best_url.clone(),
                audio_url: Some(dolby.url.clone()),
                title: Some(title.to_string()),
                quality_label: Some("杜比全景声".to_string()),
                mime_type: Some("video/mp4".to_string()),
                extractor: Some("bilibili"),
                ..CandidateSpec::default()
            });
        }

        return;
    }

    // Progressive fallback: fully muxed files, one candidate each.
    for media in &streams.progressive {
        collector.push(CandidateSpec {
            media_url: media.url.clone(),
            title: Some(title.to_string()),
            quality_label: Some(quality_label(streams, media)),
            codec: codec_name_for(media).map(str::to_string),
            mime_type: Some("video/mp4".to_string()),
            extractor: Some("bilibili"),
            ..CandidateSpec::default()
        });
    }
}

#[cfg(test)]
mod tests {
    use super::{collect_stream_candidates, fallback_quality_name, locked_quality_tiers};
    use crate::api::bilibili::api::{DashMedia, DashStreams, SupportFormat};
    use crate::api::downloader::{CandidateCollector, MediaCandidate};
    use crate::api::site_adapters::SiteWarning;

    fn media(quality: i64, codec: i64, height: i64, bandwidth: i64, url: &str) -> DashMedia {
        DashMedia {
            quality_id: quality,
            bandwidth,
            codec_id: codec,
            codecs: String::new(),
            mime_type: "video/mp4".to_string(),
            width: height * 16 / 9,
            height,
            frame_rate: 0.0,
            url: url.to_string(),
        }
    }

    fn audio(id: i64, bandwidth: i64, url: &str) -> DashMedia {
        DashMedia {
            quality_id: id,
            bandwidth,
            codec_id: 0,
            codecs: "mp4a.40.2".to_string(),
            mime_type: "audio/mp4".to_string(),
            width: 0,
            height: 0,
            frame_rate: 0.0,
            url: url.to_string(),
        }
    }

    fn format(quality_id: i64, description: &str, badge: &str) -> SupportFormat {
        SupportFormat {
            quality_id,
            description: description.to_string(),
            display: description
                .split(' ')
                .next()
                .unwrap_or(description)
                .to_string(),
            badge: badge.to_string(),
        }
    }

    fn collect(streams: &DashStreams) -> (Vec<MediaCandidate>, Vec<String>) {
        let mut collector = CandidateCollector::new(
            "https://www.bilibili.com/video/BV1fixture/",
            "Fixture",
            "bilibili",
        );
        let mut warnings = Vec::<SiteWarning>::new();
        collect_stream_candidates(&mut collector, "Fixture Video", streams, &mut warnings);
        (
            collector.finish(),
            warnings
                .into_iter()
                .map(SiteWarning::into_display)
                .collect(),
        )
    }

    #[test]
    fn maps_well_known_quality_ids() {
        assert_eq!(fallback_quality_name(16), Some("360P 流畅"));
        assert_eq!(fallback_quality_name(80), Some("1080P 高清"));
        assert_eq!(fallback_quality_name(112), Some("1080P 高码率"));
        assert_eq!(fallback_quality_name(127), Some("8K 超高清"));
        assert_eq!(fallback_quality_name(999), None);
    }

    #[test]
    fn prefers_official_support_format_naming() {
        let streams = DashStreams {
            video: vec![media(
                120,
                12,
                2160,
                16_000_000,
                "https://upos.example/4k.m4s",
            )],
            audio: vec![audio(30280, 192_000, "https://upos.example/audio.m4s")],
            formats: vec![
                format(120, "4K 超高清", ""),
                format(112, "1080P 高码率", "高码率"),
            ],
            ..DashStreams::default()
        };

        let (candidates, _) = collect(&streams);
        assert_eq!(candidates[0].quality_label, "4K 超高清");
        assert_eq!(candidates[0].codec, "HEVC");
        // `高码率` merely repeats the official name and must not double up.
        assert!(candidates[0].quality_badge.is_empty());
    }

    #[test]
    fn keeps_badges_that_add_information() {
        let streams = DashStreams {
            video: vec![media(
                120,
                12,
                2160,
                16_000_000,
                "https://upos.example/4k.m4s",
            )],
            audio: vec![audio(30280, 192_000, "https://upos.example/audio.m4s")],
            formats: vec![format(120, "4K 超高清", "大会员")],
            ..DashStreams::default()
        };

        let (candidates, _) = collect(&streams);
        assert_eq!(candidates[0].quality_badge, "大会员");
    }

    #[test]
    fn states_frame_rate_when_the_fallback_name_omits_it() {
        let mut stream_4k = media(120, 12, 2160, 16_000_000, "https://upos.example/4k.m4s");
        stream_4k.frame_rate = 60.0;
        let streams = DashStreams {
            video: vec![stream_4k],
            audio: vec![audio(30280, 192_000, "https://upos.example/audio.m4s")],
            ..DashStreams::default()
        };

        let (candidates, _) = collect(&streams);
        assert_eq!(candidates[0].quality_label, "4K 超高清 60帧");
    }

    #[test]
    fn reports_locked_qualities_without_inventing_candidates() {
        let streams = DashStreams {
            video: vec![media(32, 7, 480, 500_000, "https://upos.example/480.m4s")],
            formats: vec![
                format(120, "4K 超高清", ""),
                format(112, "1080P 高码率", "高码率"),
                format(32, "480P 标清", ""),
            ],
            ..DashStreams::default()
        };

        assert_eq!(
            locked_quality_tiers(&streams),
            vec!["4K 超高清".to_string(), "1080P 高码率".to_string()]
        );
        let (candidates, _) = collect(&streams);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].quality_label, "480P 标清");
    }

    #[test]
    fn names_the_codec_from_the_rfc6381_string_when_the_id_is_missing() {
        let mut stream_8k = media(127, 0, 4320, 40_000_000, "https://upos.example/8k.m4s");
        stream_8k.codecs = "hev1.1.6.L186.80".to_string();
        let streams = DashStreams {
            video: vec![stream_8k],
            audio: vec![audio(30280, 192_000, "https://upos.example/audio.m4s")],
            ..DashStreams::default()
        };

        let (candidates, _) = collect(&streams);
        assert_eq!(candidates[0].codec, "HEVC");
    }

    #[test]
    fn dedupes_tiers_by_codec_priority() {
        let streams = DashStreams {
            video: vec![
                media(80, 12, 1080, 2_000_000, "https://upos.example/hevc.m4s"),
                media(80, 7, 1080, 2_100_000, "https://upos.example/avc.m4s"),
                media(80, 13, 1080, 1_900_000, "https://upos.example/av1.m4s"),
                media(112, 12, 1080, 6_000_000, "https://upos.example/plus.m4s"),
            ],
            audio: vec![audio(30280, 192_000, "https://upos.example/audio.m4s")],
            ..DashStreams::default()
        };

        let (candidates, warnings) = collect(&streams);
        assert!(warnings.is_empty());
        assert_eq!(candidates.len(), 2);
        // Best tier first, then the plain one; each paired with audio.
        assert_eq!(candidates[0].quality_label, "1080P 高码率");
        assert_eq!(candidates[0].codec, "HEVC");
        assert_eq!(
            candidates[0].audio_url.as_deref(),
            Some("https://upos.example/audio.m4s")
        );
        assert_eq!(candidates[1].quality_label, "1080P 高清");
        assert_eq!(candidates[1].codec, "AVC");
        assert_eq!(candidates[1].media_url, "https://upos.example/avc.m4s");
    }

    #[test]
    fn adds_flac_and_dolby_extras_on_the_best_tier() {
        let streams = DashStreams {
            video: vec![media(
                120,
                12,
                2160,
                16_000_000,
                "https://upos.example/4k.m4s",
            )],
            audio: vec![audio(30280, 192_000, "https://upos.example/audio.m4s")],
            flac: Some(audio(30251, 1_500_000, "https://upos.example/flac.m4s")),
            dolby: Some(audio(30250, 448_000, "https://upos.example/dolby.m4s")),
            ..DashStreams::default()
        };

        let (candidates, _) = collect(&streams);
        assert_eq!(candidates.len(), 3);
        let labels: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.quality_label.as_str())
            .collect();
        assert!(labels.contains(&"4K 超高清"));
        assert!(labels.contains(&"Hi-Res 无损"));
        assert!(labels.contains(&"杜比全景声"));
        for candidate in &candidates {
            assert_eq!(candidate.media_url, "https://upos.example/4k.m4s");
        }
    }

    #[test]
    fn warns_when_dash_video_has_no_audio() {
        let streams = DashStreams {
            video: vec![media(32, 7, 480, 500_000, "https://upos.example/480.m4s")],
            ..DashStreams::default()
        };
        let (candidates, warnings) = collect(&streams);
        assert_eq!(candidates.len(), 1);
        assert!(warnings
            .iter()
            .any(|warning| warning.contains("bilibili-audio-missing")));
    }

    #[test]
    fn falls_back_to_progressive_files() {
        let streams = DashStreams {
            progressive: vec![
                media(32, 7, 480, 900_000, "https://upos.example/p1.mp4"),
                media(16, 7, 360, 400_000, "https://upos.example/p2.mp4"),
            ],
            ..DashStreams::default()
        };
        let (candidates, _) = collect(&streams);
        assert_eq!(candidates.len(), 2);
        assert!(candidates
            .iter()
            .all(|candidate| candidate.audio_url.is_none()));
    }
}
