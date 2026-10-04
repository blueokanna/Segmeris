//! Pure (network-free) parsing of Bilibili page URLs into a typed target.
//!
//! The downloader supports every page shape a user can realistically copy
//! out of a browser or the share sheet:
//!
//! | Page shape                                   | Target             |
//! |----------------------------------------------|--------------------|
//! | `www.bilibili.com/video/BV…` / `video/av…`   | [`Target::Video`]  |
//! | `www.bilibili.com/bangumi/play/ep…`          | [`Target::Episode`]|
//! | `www.bilibili.com/bangumi/play/ss…`          | [`Target::Season`] |
//! | `space.bilibili.com/{mid}/channel/…`         | [`Target::Collection`] |
//! | `space.bilibili.com/{mid}/lists/{sid}?type=…`| [`Target::Collection`] |
//! | `www.bilibili.com/list/{mid}?sid=…`          | [`Target::Playlist`] |
//! | `b23.tv/…` / `bili2233.cn/…`                 | [`Target::ShortLink`] |
//!
//! Everything here is deterministic so the shapes can be unit tested
//! without a network. Short links are the one case that needs a request;
//! [`Target::ShortLink`] hands the URL to the API layer, which follows the
//! redirect chain and re-enters this parser with the final URL.

use url::Url;

/// A parsed Bilibili page target.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum Target {
    /// A regular video, addressed by BV id or aid, optionally pointing at
    /// a specific part (`?p=N`, 1-based) of a multi-part upload.
    Video {
        bvid: Option<String>,
        aid: Option<i64>,
        page: Option<u32>,
    },
    /// One episode of a PGC (bangumi / documentary / movie) season.
    Episode { ep_id: i64 },
    /// A whole PGC season ("ss" link).
    Season { season_id: i64 },
    /// A channel collection ("合集") or series ("系列") detail page, whose
    /// kind is already known from the URL.
    Collection {
        mid: i64,
        season_id: i64,
        kind: CollectionKind,
    },
    /// A collection/series *playlist* page (`/list/{mid}?sid=…`), where the
    /// URL does not say whether `sid` is a season or a series id; the API
    /// layer probes for that.
    Playlist {
        mid: Option<i64>,
        season_id: i64,
        current_bvid: Option<String>,
        current_aid: Option<i64>,
    },
    /// A `b23.tv` / `bili2233.cn` short link that must be resolved over
    /// the network before it can be parsed further.
    ShortLink { url: String },
}

/// Distinguishes channel collections ("合集") from uploader series
/// ("系列"); the two are backed by different read APIs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CollectionKind {
    Season,
    Series,
}

/// Whether `host` is a Bilibili content host.
pub(crate) fn is_bilibili_host(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host == "bilibili.com"
        || host.ends_with(".bilibili.com")
        || host == "b23.tv"
        || host.ends_with(".b23.tv")
        || host == "bili2233.cn"
        || host.ends_with(".bili2233.cn")
}

fn is_short_link_host(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host == "b23.tv" || host.ends_with(".b23.tv") || host == "bili2233.cn"
}

fn is_space_host(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    matches!(
        host.as_str(),
        "space.bilibili.com" | "m.bilibili.com" | "www.bilibili.com" | "bilibili.com"
    )
}

fn path_segments(url: &Url) -> Vec<&str> {
    url.path_segments()
        .map(|segments| segments.filter(|segment| !segment.is_empty()).collect())
        .unwrap_or_default()
}

fn query_value(url: &Url, key: &str) -> Option<String> {
    url.query_pairs()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.into_owned())
}

/// Parse a single non-empty query value as `i64`.
fn query_i64(url: &Url, keys: &[&str]) -> Option<i64> {
    url.query_pairs()
        .find(|(name, _)| keys.iter().any(|key| key == name))
        .and_then(|(_, value)| value.parse::<i64>().ok())
}

/// Split a BV string like `BV1xx411c7mD` off `text` (the BV prefix must be
/// uppercase, the payload is mixed-case alphanumeric and exactly 10 long).
fn extract_bvid(text: &str) -> Option<String> {
    let index = text.find("BV")?;
    let candidate = &text[index..];
    let payload = candidate.get(2..12)?;
    if payload.chars().all(|ch| ch.is_ascii_alphanumeric()) {
        Some(candidate[..12].to_string())
    } else {
        None
    }
}

/// Parse an `av123` / `123` style video identifier into an aid.
fn extract_aid(text: &str) -> Option<i64> {
    let digits = text
        .strip_prefix("av")
        .or_else(|| text.strip_prefix("AV"))
        .unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    digits.parse::<i64>().ok()
}

/// Maximum accepted `?p=` part number before the value is treated as
/// nonsense and ignored (Bilibili itself caps parts well below this).
const MAX_PART_NUMBER: u32 = 10_000;

/// Parse a Bilibili page URL into a [`Target`].
///
/// Returns `None` for hosts/paths this downloader does not support (live
/// rooms, activity pages, …); the caller reports that visibly instead of
/// silently falling back to something generic.
pub(crate) fn parse_target(url: &Url) -> Option<Target> {
    let host = url.host_str()?;
    if is_short_link_host(host) {
        return Some(Target::ShortLink {
            url: url.to_string(),
        });
    }
    if !is_bilibili_host(host) {
        return None;
    }

    let segments = path_segments(url);

    // m.bilibili.com spaces the mid under a leading `space/` segment.
    let segments = if is_space_host(host) && segments.first() == Some(&"space") {
        &segments[1..]
    } else {
        segments.as_slice()
    };

    match segments {
        ["video", id] => {
            let page = query_i64(url, &["p"])
                .and_then(|value| u32::try_from(value).ok())
                .filter(|value| (1..=MAX_PART_NUMBER).contains(value));
            if let Some(bvid) = extract_bvid(id) {
                return Some(Target::Video {
                    bvid: Some(bvid),
                    aid: None,
                    page,
                });
            }
            if let Some(aid) = extract_aid(id) {
                return Some(Target::Video {
                    bvid: None,
                    aid: Some(aid),
                    page,
                });
            }
            None
        }
        ["bangumi", "play", id] => {
            if let Some(ep) = id.strip_prefix("ep") {
                return ep
                    .parse::<i64>()
                    .ok()
                    .map(|ep_id| Target::Episode { ep_id });
            }
            if let Some(ss) = id.strip_prefix("ss") {
                return ss
                    .parse::<i64>()
                    .ok()
                    .map(|season_id| Target::Season { season_id });
            }
            None
        }
        [mid, "channel", detail] => {
            let mid = mid.parse::<i64>().ok()?;
            let season_id = query_i64(url, &["sid"])?;
            let kind = match *detail {
                "collectiondetail" => CollectionKind::Season,
                "seriesdetail" => CollectionKind::Series,
                _ => return None,
            };
            Some(Target::Collection {
                mid,
                season_id,
                kind,
            })
        }
        [mid, "lists", season_id] => {
            let mid = mid.parse::<i64>().ok()?;
            let season_id = season_id.parse::<i64>().ok()?;
            let kind = match query_value(url, "type").as_deref() {
                Some("series") => CollectionKind::Series,
                Some("season") => CollectionKind::Season,
                // `/lists/{id}` without a type defaults to a collection.
                _ => CollectionKind::Season,
            };
            Some(Target::Collection {
                mid,
                season_id,
                kind,
            })
        }
        ["list", mid] => {
            let season_id = query_i64(url, &["sid", "season_id"])?;
            let mid = query_i64(url, &["mid"]).or_else(|| mid.parse::<i64>().ok());
            let current_bvid = query_value(url, "bvid").and_then(|value| extract_bvid(&value));
            let current_aid = query_i64(url, &["oid"]);
            Some(Target::Playlist {
                mid,
                season_id,
                current_bvid,
                current_aid,
            })
        }
        ["medialist", "play", mid] => {
            let season_id = query_i64(url, &["season_id", "sid"])?;
            let mid = query_i64(url, &["mid"]).or_else(|| mid.parse::<i64>().ok());
            Some(Target::Playlist {
                mid,
                season_id,
                current_bvid: None,
                current_aid: None,
            })
        }
        _ => None,
    }
}

/// Canonical page URL for a single part of a multi-part video.
pub(crate) fn video_page_url(bvid: &str, page: u32, total_parts: usize) -> String {
    if total_parts > 1 {
        format!("https://www.bilibili.com/video/{bvid}/?p={page}")
    } else {
        format!("https://www.bilibili.com/video/{bvid}/")
    }
}

/// Canonical page URL for a PGC episode.
pub(crate) fn episode_page_url(ep_id: i64) -> String {
    format!("https://www.bilibili.com/bangumi/play/ep{ep_id}")
}

#[cfg(test)]
mod tests {
    use super::{parse_target, CollectionKind, Target};
    use url::Url;

    fn target(url: &str) -> Option<Target> {
        parse_target(&Url::parse(url).expect("test URL must parse"))
    }

    #[test]
    fn parses_bv_and_av_video_links() {
        assert_eq!(
            target("https://www.bilibili.com/video/BV1xx411c7mD"),
            Some(Target::Video {
                bvid: Some("BV1xx411c7mD".to_string()),
                aid: None,
                page: None,
            })
        );
        assert_eq!(
            target("https://www.bilibili.com/video/BV1xx411c7mD/?p=3&t=8"),
            Some(Target::Video {
                bvid: Some("BV1xx411c7mD".to_string()),
                aid: None,
                page: Some(3),
            })
        );
        assert_eq!(
            target("https://www.bilibili.com/video/av170001"),
            Some(Target::Video {
                bvid: None,
                aid: Some(170001),
                page: None,
            })
        );
        assert_eq!(
            target("https://m.bilibili.com/video/BV1QQ4y1T7Eu?p=2"),
            Some(Target::Video {
                bvid: Some("BV1QQ4y1T7Eu".to_string()),
                aid: None,
                page: Some(2),
            })
        );
    }

    #[test]
    fn rejects_nonsense_part_numbers() {
        assert_eq!(
            target("https://www.bilibili.com/video/BV1xx411c7mD?p=0"),
            Some(Target::Video {
                bvid: Some("BV1xx411c7mD".to_string()),
                aid: None,
                page: None,
            })
        );
        assert_eq!(
            target("https://www.bilibili.com/video/BV1xx411c7mD?p=99999999"),
            Some(Target::Video {
                bvid: Some("BV1xx411c7mD".to_string()),
                aid: None,
                page: None,
            })
        );
    }

    #[test]
    fn parses_bangumi_episode_and_season_links() {
        assert_eq!(
            target("https://www.bilibili.com/bangumi/play/ep327577"),
            Some(Target::Episode { ep_id: 327577 })
        );
        assert_eq!(
            target("https://www.bilibili.com/bangumi/play/ss28747?from_spmid=666.4"),
            Some(Target::Season { season_id: 28747 })
        );
        assert_eq!(
            target("https://www.bilibili.com/bangumi/media/md28229369"),
            None
        );
    }

    #[test]
    fn parses_collection_detail_pages() {
        assert_eq!(
            target("https://space.bilibili.com/2624953/channel/collectiondetail?sid=3369187"),
            Some(Target::Collection {
                mid: 2624953,
                season_id: 3369187,
                kind: CollectionKind::Season,
            })
        );
        assert_eq!(
            target("https://space.bilibili.com/2624953/channel/seriesdetail?sid=12345"),
            Some(Target::Collection {
                mid: 2624953,
                season_id: 12345,
                kind: CollectionKind::Series,
            })
        );
        assert_eq!(
            target("https://m.bilibili.com/space/2624953/lists/3369187?type=season"),
            Some(Target::Collection {
                mid: 2624953,
                season_id: 3369187,
                kind: CollectionKind::Season,
            })
        );
        assert_eq!(
            target("https://space.bilibili.com/2624953/lists/12345?type=series"),
            Some(Target::Collection {
                mid: 2624953,
                season_id: 12345,
                kind: CollectionKind::Series,
            })
        );
    }

    #[test]
    fn parses_playlist_pages_with_current_video() {
        assert_eq!(
            target(
                "https://www.bilibili.com/list/2624953?sid=3369187&oid=997835904&bvid=BV1QQ4y1T7Eu"
            ),
            Some(Target::Playlist {
                mid: Some(2624953),
                season_id: 3369187,
                current_bvid: Some("BV1QQ4y1T7Eu".to_string()),
                current_aid: Some(997835904),
            })
        );
        assert_eq!(
            target("https://www.bilibili.com/medialist/play/2624953?season_id=3369187"),
            Some(Target::Playlist {
                mid: Some(2624953),
                season_id: 3369187,
                current_bvid: None,
                current_aid: None,
            })
        );
    }

    #[test]
    fn classifies_short_links() {
        assert_eq!(
            target("https://b23.tv/AbCdEfG"),
            Some(Target::ShortLink {
                url: "https://b23.tv/AbCdEfG".to_string(),
            })
        );
        assert_eq!(
            target("https://bili2233.cn/xyz"),
            Some(Target::ShortLink {
                url: "https://bili2233.cn/xyz".to_string(),
            })
        );
    }

    #[test]
    fn rejects_unsupported_pages_and_foreign_hosts() {
        assert_eq!(target("https://live.bilibili.com/123"), None);
        assert_eq!(target("https://space.bilibili.com/2624953"), None);
        assert_eq!(target("https://www.bilibili.com/read/cv123"), None);
        assert_eq!(target("https://example.com/video/BV1xx411c7mD"), None);
        assert_eq!(target("https://www.bilibili.com/video/not-a-video"), None);
    }
}
