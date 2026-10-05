//! Native HLS → MP4 stream-copy remuxer: a self-contained equivalent of
//! `ffmpeg -c copy` for MPEG-TS sources, implemented from scratch (no FFmpeg,
//! no MediaCodec/MediaMuxer, no AVFoundation).
//!
//! It demuxes the MPEG-TS byte stream, copies the H.264 access units and AAC
//! frames bit-for-bit, re-bases the timeline across HLS segment PTS resets and
//! writes a plain MP4 (`ftyp` + `mdat` + `moov`). Because no decoder or
//! encoder is involved, it runs at disk speed and produces no heat — on every
//! platform, including iOS and Android.
//!
//! The caller is expected to treat any error as "fall back to the platform
//! transcoder": the remuxer is deliberately strict and never guesses on
//! streams outside its supported subset (one H.264 video track + optional
//! AAC/ADTS audio track).

mod bits;
mod mp4;
mod ts;

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use anyhow::{Context, Result};
use log::info;

pub use ts::is_mpeg_ts;

/// Result of a successful stream-copy remux.
#[derive(Debug, Clone, Copy)]
pub struct RemuxSummary {
    pub video_samples: u64,
    pub audio_samples: u64,
    pub duration_seconds: f64,
    pub width: u32,
    pub height: u32,
}

struct Mp4Sink {
    writer: mp4::Mp4Writer,
}

impl ts::SampleSink for Mp4Sink {
    fn set_video_config(&mut self, config: ts::AvcConfig) -> Result<()> {
        self.writer.set_video_config(config);
        Ok(())
    }

    fn set_audio_config(&mut self, config: ts::AacConfig) -> Result<()> {
        self.writer.set_audio_config(config);
        Ok(())
    }

    fn video_sample(&mut self, data: &[u8], dts: i64, cts_offset: i32, key: bool) -> Result<()> {
        self.writer.write_video_sample(data, dts, cts_offset, key)
    }

    fn audio_sample(&mut self, data: &[u8]) -> Result<()> {
        self.writer.write_audio_sample(data)
    }

    fn set_source_starts(
        &mut self,
        video_ticks: Option<i64>,
        audio_ticks: Option<i64>,
    ) -> Result<()> {
        self.writer.set_source_starts(video_ticks, audio_ticks);
        Ok(())
    }
}

/// Stream-copy a merged MPEG-TS file into an MP4 without re-encoding.
pub fn remux_ts_to_mp4(input: &Path, output: &Path) -> Result<RemuxSummary> {
    let file =
        File::open(input).with_context(|| format!("cannot open TS input: {}", input.display()))?;
    let reader = BufReader::with_capacity(1 << 20, file);
    let mut sink = Mp4Sink {
        writer: mp4::Mp4Writer::create(output)?,
    };
    ts::parse_ts(reader, &mut sink)?;
    let summary = sink.writer.finish()?;
    info!(
        "Stream-copy remux complete: {}x{}, {} video / {} audio samples, {:.2}s",
        summary.width,
        summary.height,
        summary.video_samples,
        summary.audio_samples,
        summary.duration_seconds
    );
    Ok(RemuxSummary {
        video_samples: summary.video_samples,
        audio_samples: summary.audio_samples,
        duration_seconds: summary.duration_seconds,
        width: summary.width,
        height: summary.height,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `(timescale, duration)` of every track of the produced MP4, read from
    /// its `mdhd` boxes (the writer emits version 0 throughout).
    fn track_media_durations(bytes: &[u8], moov: usize) -> Vec<(u32, u64)> {
        fn children(bytes: &[u8], start: usize, end: usize, kind: &[u8; 4]) -> Vec<(usize, usize)> {
            let mut found = Vec::new();
            let mut position = start;
            while position + 8 <= end {
                let size =
                    u32::from_be_bytes(bytes[position..position + 4].try_into().unwrap()) as usize;
                if size < 8 || position + size > end {
                    break;
                }
                if &bytes[position + 4..position + 8] == kind {
                    found.push((position, position + size));
                }
                position += size;
            }
            found
        }

        // `moov` is the offset of the box *name*, so the box itself starts four
        // bytes earlier.
        let moov_start = moov - 4;
        let moov_size =
            u32::from_be_bytes(bytes[moov_start..moov_start + 4].try_into().unwrap()) as usize;
        let moov_end = moov_start + moov_size;
        let mut durations = Vec::new();
        for (trak, trak_end) in children(bytes, moov_start + 8, moov_end, b"trak") {
            let (mdia, mdia_end) = children(bytes, trak + 8, trak_end, b"mdia")[0];
            let (mdhd, _) = children(bytes, mdia + 8, mdia_end, b"mdhd")[0];
            let timescale = u32::from_be_bytes(bytes[mdhd + 20..mdhd + 24].try_into().unwrap());
            let duration = u32::from_be_bytes(bytes[mdhd + 24..mdhd + 28].try_into().unwrap());
            durations.push((timescale, u64::from(duration)));
        }
        durations
    }

    /// End-to-end check against a real HLS segment. Skipped unless
    /// `FERRISLOAD_TS_SAMPLE` points at a TS file, so CI stays hermetic.
    #[test]
    fn remuxes_a_real_ts_sample_when_configured() {
        let Ok(sample) = std::env::var("FERRISLOAD_TS_SAMPLE") else {
            return;
        };
        let _ = env_logger::builder()
            .is_test(true)
            .filter_level(log::LevelFilter::Info)
            .try_init();
        let sample = std::path::PathBuf::from(sample);
        let output =
            std::env::temp_dir().join(format!("segmeris-remux-sample-{}.mp4", std::process::id()));
        let summary = remux_ts_to_mp4(&sample, &output).expect("stream-copy remux must succeed");
        assert!(summary.video_samples > 0, "no video samples were produced");
        assert!(summary.width > 0 && summary.height > 0);
        assert!(summary.duration_seconds > 0.5, "implausible duration");

        let bytes = std::fs::read(&output).expect("read output");
        assert_eq!(&bytes[4..8], b"ftyp");
        let moov = bytes
            .windows(4)
            .position(|window| window == b"moov")
            .expect("moov box present");
        let mdat = bytes
            .windows(4)
            .position(|window| window == b"mdat")
            .expect("mdat box present");
        let mdat_size = u32::from_be_bytes(bytes[mdat - 4..mdat].try_into().unwrap()) as usize;
        assert_eq!(
            mdat - 4 + mdat_size,
            moov - 4,
            "mdat must cover exactly the bytes up to moov"
        );
        let moov_size = u32::from_be_bytes(bytes[moov - 4..moov].try_into().unwrap()) as usize;
        assert_eq!(moov - 4 + moov_size, bytes.len(), "moov must end the file");

        // Both tracks of one clip must span the same wall-clock time. A frame
        // interval that disagrees with the stream's real cadence stretches the
        // video track away from the audio (the "16 fps, out of sync" symptom),
        // and this is the regression guard for exactly that.
        let durations = track_media_durations(&bytes, moov);
        assert!(durations.len() >= 2, "sample must carry video and audio");
        let seconds = |(scale, duration): (u32, u64)| duration as f64 / f64::from(scale.max(1));
        let video_seconds = seconds(durations[0]);
        let audio_seconds = seconds(durations[1]);
        let slack = (video_seconds * 0.05).max(0.5);
        assert!(
            (video_seconds - audio_seconds).abs() <= slack,
            "video track ({video_seconds:.2}s) and audio track ({audio_seconds:.2}s) diverged; \
             the video timeline must follow the stream's real cadence"
        );
        println!("remuxed sample written to {}", output.display());
    }
}
