//! Structural MP4 validation shared by copy and conversion paths.
use std::path::Path;

pub(crate) fn has_mp4_signature(prefix: &[u8]) -> bool {
    prefix
        .windows(4)
        .take(24)
        .any(|window| window == b"ftyp" || window == b"styp")
}

/// What the top-level box chain of an MP4 file says about the file as a whole.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub(crate) struct Mp4Layout {
    pub(crate) plain: bool,
    pub(crate) duration_seconds: Option<f64>,
}

/// Walks the top-level boxes of `path` without reading the payloads (a few
/// seeks, whatever the file's size) and reports whether it is a plain,
/// self-describing MP4 plus the duration its movie header declares.
///
/// Both shapes that start with `ftyp` but are not plain must be rebuilt by a
/// real muxer instead of being copied:
///
/// * a fragmented MP4 (an `EXT-X-MAP` HLS download assembled byte-for-byte:
///   `ftyp` + `moov` + `moof`/`mdat` fragments) — its `mvhd` carries `0`, so
///   the system gallery lists a finished two-hour download as `00:00` (or as
///   whatever the first fragment covers) while a player still plays it end to
///   end;
/// * byte-concatenated MP4 segments (an HLS playlist whose segment URIs are
///   `.mp4`, i.e. several `moov`/`mdat` pairs) — the first `moov` describes
///   only the first segment, the exact "system says 00:06, playback says
///   1:02:44" report.
pub(crate) fn mp4_layout(path: &Path) -> Option<Mp4Layout> {
    use std::io::{Read, Seek, SeekFrom};

    const MAX_BOXES: u64 = 8192;

    let mut file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut position = 0u64;
    let mut boxes = 0u64;
    let mut ftyp_boxes = 0u32;
    let mut moov_boxes = 0u32;
    let mut moof_boxes = 0u32;
    let mut styp_boxes = 0u32;
    let mut ftyp_first = false;
    let mut content_started = false;
    let mut duration_seconds: Option<f64> = None;

    loop {
        if position == file_len {
            break;
        }
        boxes += 1;
        if boxes > MAX_BOXES {
            return Some(Mp4Layout::default());
        }
        let remaining = file_len.checked_sub(position)?;
        if remaining < 8 {
            return Some(Mp4Layout::default());
        }
        file.seek(SeekFrom::Start(position)).ok()?;
        let mut header = [0u8; 8];
        file.read_exact(&mut header).ok()?;
        let short_size = u32::from_be_bytes(header[0..4].try_into().ok()?);
        let kind = [header[4], header[5], header[6], header[7]];
        let (header_len, payload_len) = match short_size {
            0 => (8u64, remaining - 8),
            1 => {
                if remaining < 16 {
                    return Some(Mp4Layout::default());
                }
                let mut large = [0u8; 8];
                file.read_exact(&mut large).ok()?;
                let large_size = u64::from_be_bytes(large);
                if large_size < 16 {
                    return Some(Mp4Layout::default());
                }
                (16u64, large_size - 16)
            }
            value => {
                if u64::from(value) < 8 {
                    return Some(Mp4Layout::default());
                }
                (8u64, u64::from(value) - 8)
            }
        };
        if payload_len > remaining - header_len {
            return Some(Mp4Layout::default());
        }
        if kind == *b"moov" {
            moov_boxes += 1;
            if moov_boxes == 1 {
                duration_seconds = read_mvhd_seconds(&mut file, position + header_len, payload_len);
            }
        } else if kind == *b"ftyp" {
            ftyp_boxes += 1;
            if !content_started {
                ftyp_first = true;
            }
        } else if kind == *b"moof" {
            moof_boxes += 1;
        } else if kind == *b"styp" {
            styp_boxes += 1;
        }
        if kind != *b"free" && kind != *b"wide" && kind != *b"skip" && kind != *b"ftyp" {
            content_started = true;
        }
        position += header_len + payload_len;
    }

    let plain = position == file_len
        && ftyp_first
        && ftyp_boxes == 1
        && moov_boxes == 1
        && moof_boxes == 0
        && styp_boxes == 0
        && duration_seconds.is_some_and(|seconds| seconds > 0.0);
    Some(Mp4Layout {
        plain,
        duration_seconds,
    })
}

/// Seconds declared by the `mvhd` found among the direct children of a `moov`.
pub(crate) fn read_mvhd_seconds(
    file: &mut std::fs::File,
    start: u64,
    payload_len: u64,
) -> Option<f64> {
    use std::io::{Read, Seek, SeekFrom};

    let end = start.checked_add(payload_len)?;
    let mut position = start;
    let mut children = 0u32;
    let mut duration_seconds = None;
    while position < end {
        children += 1;
        let remaining = end.checked_sub(position)?;
        if children > 4096 || remaining < 8 {
            return None;
        }
        file.seek(SeekFrom::Start(position)).ok()?;
        let mut header = [0u8; 8];
        file.read_exact(&mut header).ok()?;
        let short_size = u32::from_be_bytes(header[..4].try_into().ok()?);
        let (header_len, size) = match short_size {
            0 => (8, remaining),
            1 => {
                if remaining < 16 {
                    return None;
                }
                let mut large = [0u8; 8];
                file.read_exact(&mut large).ok()?;
                (16, u64::from_be_bytes(large))
            }
            n => (8, u64::from(n)),
        };
        if size < header_len || size > remaining {
            return None;
        }
        let payload_len = size - header_len;
        if &header[4..] == b"mvhd" {
            if duration_seconds.is_some() || payload_len < 20 {
                return None;
            }
            let mut body = [0u8; 32];
            file.read_exact(&mut body[..20]).ok()?;
            let (timescale, duration, unknown) = match body[0] {
                0 => (
                    u32::from_be_bytes(body[12..16].try_into().ok()?),
                    u64::from(u32::from_be_bytes(body[16..20].try_into().ok()?)),
                    u64::from(u32::MAX),
                ),
                1 if payload_len >= 32 => {
                    file.read_exact(&mut body[20..]).ok()?;
                    (
                        u32::from_be_bytes(body[20..24].try_into().ok()?),
                        u64::from_be_bytes(body[24..32].try_into().ok()?),
                        u64::MAX,
                    )
                }
                _ => return None,
            };
            if timescale == 0 || duration == 0 || duration == unknown {
                return None;
            }
            duration_seconds = Some(duration as f64 / f64::from(timescale));
        }
        position = position.checked_add(size)?;
    }
    duration_seconds
}

/// Duration of `path` when the file is a plain MP4 the platform's own media
/// stack will read correctly, `None` when it must be rebuilt instead.
pub(crate) fn plain_mp4_duration_seconds(path: &Path) -> Option<f64> {
    let layout = mp4_layout(path)?;
    layout.plain.then_some(layout.duration_seconds).flatten()
}

/// Whether a container duration is a plausible match for the playlist's
/// expected duration. The expected value is the sum of the EXTINF tags, which
/// are rounded up per segment, so the real media is routinely a few percent
/// shorter; only a significant shortfall (truncation) or an inflated timeline
/// is rejected.
pub(crate) fn copied_mp4_duration_is_plausible(seconds: f64, expected: Option<f64>) -> bool {
    if !seconds.is_finite() || seconds <= 0.0 {
        return false;
    }
    let Some(expected) = expected.filter(|value| value.is_finite() && *value > 0.0) else {
        return true;
    };
    let shortest = (expected * 0.97).max(expected - 5.0);
    let longest = expected + (expected * 0.03).max(5.0);
    seconds + 1.0 >= shortest && seconds <= longest
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn movie_header_bounds_versions_and_unknown_durations_are_checked() {
        let mut valid = vec![0; 28];
        valid[..4].copy_from_slice(&28u32.to_be_bytes());
        valid[4..8].copy_from_slice(b"mvhd");
        valid[20..24].copy_from_slice(&1000u32.to_be_bytes());
        valid[24..28].copy_from_slice(&18000u32.to_be_bytes());
        let mut unknown_version = valid.clone();
        unknown_version[8] = 2;
        let mut unknown_duration = valid.clone();
        unknown_duration[24..28].fill(0xff);
        let mut short = valid.clone();
        short[..4].copy_from_slice(&8u32.to_be_bytes());
        let mut overlong = valid.clone();
        overlong[..4].copy_from_slice(&1000u32.to_be_bytes());
        let duplicate = [valid.clone(), valid.clone()].concat();
        let directory = std::env::temp_dir().join(format!("segmeris-mp4-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        for (i, bytes) in [
            valid,
            unknown_version,
            unknown_duration,
            short,
            overlong,
            duplicate,
        ]
        .iter()
        .enumerate()
        {
            let path = directory.join(i.to_string());
            std::fs::write(&path, bytes).unwrap();
            let mut file = std::fs::File::open(path).unwrap();
            assert_eq!(
                read_mvhd_seconds(&mut file, 0, bytes.len() as u64),
                if i == 0 { Some(18.0) } else { None },
                "case {i}"
            );
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
