//! Minimal, dependency-free MP4 (ISO BMFF) writer used by the native
//! TS → MP4 stream-copy remuxer.
//!
//! Scope: exactly what an HLS "stream copy" needs — one AVC video track and
//! an optional AAC audio track, sample tables written in decode order with a
//! `ctts` table when B-frames are present, and a plain (non-fragmented) MP4
//! with `moov` after `mdat`. No re-encoding, no external tooling.
//!
//! Layout produced: `ftyp` + `mdat` (payload streamed, size back-patched) +
//! `moov`. Playback does not require `faststart` for a local file.

use std::fs::File;
use std::io::{BufWriter, Seek, SeekFrom, Write};
use std::path::Path;

use anyhow::{bail, Context, Result};

use super::ts::{AacConfig, AvcConfig};

/// Summary returned after a successful mux.
#[derive(Debug, Clone, Copy)]
pub struct Mp4Summary {
    pub video_samples: u64,
    pub audio_samples: u64,
    pub duration_seconds: f64,
    pub width: u32,
    pub height: u32,
}

struct Sample {
    offset: u64,
    size: u32,
}

struct VideoTrack {
    config: AvcConfig,
    samples: Vec<Sample>,
    durations: Vec<u32>,
    cts_offsets: Vec<i32>,
    keyframes: Vec<u32>,
    last_dts: Option<i64>,
}

struct AudioTrack {
    config: AacConfig,
    samples: Vec<Sample>,
    /// AAC frame length in samples (LC = 1024).
    frame_samples: u32,
}

/// Streaming MP4 writer. Samples are appended to `mdat` as they arrive; the
/// sample index stays in memory (a few MB even for a feature-length movie).
pub struct Mp4Writer {
    out: Out,
    mdat_start: u64,
    video: Option<VideoTrack>,
    audio: Option<AudioTrack>,
    /// [`Mp4Writer::set_source_starts`].
    source_starts: (Option<i64>, Option<i64>),
    finished: bool,
}

impl Mp4Writer {
    pub fn create(path: &Path) -> Result<Self> {
        let file = File::create(path)
            .with_context(|| format!("cannot create MP4 output: {}", path.display()))?;
        let mut out = Out::new(file);
        write_ftyp(&mut out)?;
        let mdat_start = out.pos;
        out.u32(0)?;
        out.bytes(b"mdat")?;
        Ok(Self {
            out,
            mdat_start,
            video: None,
            audio: None,
            source_starts: (None, None),
            finished: false,
        })
    }

    pub fn set_video_config(&mut self, config: AvcConfig) {
        self.video = Some(VideoTrack {
            config,
            samples: Vec::new(),
            durations: Vec::new(),
            cts_offsets: Vec::new(),
            keyframes: Vec::new(),
            last_dts: None,
        });
    }

    pub fn set_audio_config(&mut self, config: AacConfig) {
        self.audio = Some(AudioTrack {
            config,
            samples: Vec::new(),
            frame_samples: 1024,
        });
    }

    /// Append one compressed AVC access unit (length-prefixed NALUs).
    pub fn write_video_sample(
        &mut self,
        data: &[u8],
        dts: i64,
        cts_offset: i32,
        key: bool,
    ) -> Result<()> {
        let offset = self.out.pos;
        self.out.bytes(data)?;
        let track = self
            .video
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("video sample without an AVC configuration"))?;
        let duration = match track.last_dts {
            Some(previous) if dts > previous => u32::try_from(dts - previous).unwrap_or(3000),
            Some(_) | None => 3000, // first sample / non-monotonic guard (~33 ms)
        };
        if track.last_dts.is_some() {
            track.durations.push(duration);
        }
        track.last_dts = Some(dts);
        track.cts_offsets.push(cts_offset.max(0));
        if key {
            track.keyframes.push((track.samples.len() + 1) as u32);
        }
        let size = u32::try_from(data.len()).context("video sample is larger than 4 GiB")?;
        track.samples.push(Sample { offset, size });
        Ok(())
    }

    /// Append one raw AAC frame (ADTS header removed).
    pub fn write_audio_sample(&mut self, data: &[u8]) -> Result<()> {
        let offset = self.out.pos;
        self.out.bytes(data)?;
        let track = self
            .audio
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("audio sample without an AAC configuration"))?;
        let size = u32::try_from(data.len()).context("audio frame is larger than 4 GiB")?;
        track.samples.push(Sample { offset, size });
        Ok(())
    }

    /// Tell the writer where each track began in the source timeline, in
    /// 90 kHz ticks (the MPEG-TS clock).
    ///
    /// The output timelines are rebuilt from a frame count — video from a
    /// picture grid, audio from an AAC frame count — so both start at zero. A
    /// source whose audio starts half a second after its video would then be
    /// muxed with the two tracks *aligned*, i.e. half a second out of sync. The
    /// offset is restored the way container formats express it: an
    /// `edts`/`elst` edit list holding the later track back by the difference,
    /// so players stay on the source's own timeline.
    ///
    /// Either value may be missing; unless both are known no edit list is
    /// written and the output keeps the zero-based timeline.
    pub fn set_source_starts(&mut self, video_ticks: Option<i64>, audio_ticks: Option<i64>) {
        self.source_starts = (video_ticks, audio_ticks);
    }

    /// Delay to insert in front of each track, `(video_ms, audio_ms)` — at most
    /// one of them is non-zero.
    fn start_delays_ms(&self) -> (u32, u32) {
        let (Some(video_start), Some(audio_start)) = self.source_starts else {
            return (0, 0);
        };
        let first_presented = self
            .video
            .as_ref()
            .and_then(|track| track.cts_offsets.first().copied())
            .unwrap_or(0) as i64;
        let delta_ticks = (audio_start - video_start) + first_presented;
        if delta_ticks >= 0 {
            (0, ticks_to_ms(delta_ticks))
        } else {
            (ticks_to_ms(-delta_ticks), 0)
        }
    }

    /// Finalize the file: `moov` is written after `mdat`, then the `mdat`
    /// size is back-patched.
    pub fn finish(mut self) -> Result<Mp4Summary> {
        self.finished = true;
        let delays_ms = self.start_delays_ms();
        let video = self
            .video
            .as_mut()
            .filter(|track| !track.samples.is_empty())
            .ok_or_else(|| anyhow::anyhow!("no video samples were muxed"))?;
        if video.last_dts.is_some() && video.durations.len() + 1 == video.samples.len() {
            let fallback = video.durations.last().copied().unwrap_or(3000);
            video.durations.push(fallback);
        }

        let video_duration_90k: u64 = video.durations.iter().map(|d| u64::from(*d)).sum();
        let (audio_duration, audio_sample_count) = match self.audio.as_ref() {
            Some(track) if !track.samples.is_empty() => {
                let frames = track.samples.len() as u64;
                let samples = frames * u64::from(track.frame_samples);
                let duration = samples * 1000 / u64::from(track.config.sample_rate.max(1));
                (duration, frames)
            }
            _ => (0, 0),
        };
        let video_duration_ms = video_duration_90k * 1000 / 90_000;
        let movie_duration_ms =
            video_duration_ms.max(audio_duration) + u64::from(delays_ms.0.max(delays_ms.1));

        let mdat_end = self.out.pos;
        let mdat_size = u32::try_from(mdat_end - self.mdat_start)
            .context("mdat exceeds the 4 GiB classic MP4 limit")?;

        write_moov(
            &mut self.out,
            video,
            self.audio.as_ref(),
            movie_duration_ms,
            video_duration_ms,
            delays_ms,
        )?;

        self.out.patch_u32(self.mdat_start, mdat_size)?;
        self.out.flush()?;

        let width = video.config.width;
        let height = video.config.height;
        Ok(Mp4Summary {
            video_samples: video.samples.len() as u64,
            audio_samples: audio_sample_count,
            duration_seconds: movie_duration_ms as f64 / 1000.0,
            width,
            height,
        })
    }
}

// ───────────────────────────── low-level output ─────────────────────────────

struct Out {
    writer: BufWriter<File>,
    pos: u64,
}

impl Out {
    fn new(file: File) -> Self {
        Self {
            writer: BufWriter::with_capacity(1 << 20, file),
            pos: 0,
        }
    }

    fn bytes(&mut self, data: &[u8]) -> Result<()> {
        self.writer.write_all(data)?;
        self.pos += data.len() as u64;
        Ok(())
    }

    fn u8(&mut self, value: u8) -> Result<()> {
        self.bytes(&[value])
    }

    fn u16(&mut self, value: u16) -> Result<()> {
        self.bytes(&value.to_be_bytes())
    }

    fn u24(&mut self, value: u32) -> Result<()> {
        self.bytes(&value.to_be_bytes()[1..])
    }

    fn u32(&mut self, value: u32) -> Result<()> {
        self.bytes(&value.to_be_bytes())
    }

    fn u64(&mut self, value: u64) -> Result<()> {
        self.bytes(&value.to_be_bytes())
    }

    fn patch_u32(&mut self, at: u64, value: u32) -> Result<()> {
        self.writer.flush()?;
        let end = self.pos;
        self.writer.seek(SeekFrom::Start(at))?;
        self.writer.write_all(&value.to_be_bytes())?;
        self.writer.seek(SeekFrom::Start(end))?;
        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        self.writer.flush()?;
        Ok(())
    }
}

fn begin_box(out: &mut Out, name: &[u8; 4]) -> Result<u64> {
    let start = out.pos;
    out.u32(0)?;
    out.bytes(name)?;
    Ok(start)
}

fn end_box(out: &mut Out, start: u64) -> Result<()> {
    let size = u32::try_from(out.pos - start).context("box exceeds 4 GiB")?;
    out.patch_u32(start, size)
}

fn write_full_box_header(out: &mut Out, version: u8, flags: u32) -> Result<()> {
    out.u8(version)?;
    out.u24(flags)
}

fn write_ftyp(out: &mut Out) -> Result<()> {
    let start = begin_box(out, b"ftyp")?;
    out.bytes(b"isom")?;
    out.u32(0x200)?; // minor version
    out.bytes(b"isom")?;
    out.bytes(b"iso2")?;
    out.bytes(b"avc1")?;
    out.bytes(b"mp41")?;
    end_box(out, start)
}

const UNITY_MATRIX: [u32; 9] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000];

/// 90 kHz ticks → milliseconds, rounded to the nearest one — the finest a delay
/// can be expressed with in a movie whose timescale is 1000.
fn ticks_to_ms(ticks: i64) -> u32 {
    u32::try_from((ticks.max(0) + 45) / 90).unwrap_or(u32::MAX)
}

fn write_matrix(out: &mut Out) -> Result<()> {
    for value in UNITY_MATRIX {
        out.u32(value)?;
    }
    Ok(())
}

fn write_moov(
    out: &mut Out,
    video: &VideoTrack,
    audio: Option<&AudioTrack>,
    movie_duration_ms: u64,
    video_duration_ms: u64,
    delays_ms: (u32, u32),
) -> Result<()> {
    let (video_delay_ms, audio_delay_ms) = delays_ms;
    let moov = begin_box(out, b"moov")?;

    // mvhd
    let mvhd = begin_box(out, b"mvhd")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(0)?; // creation time
    out.u32(0)?; // modification time
    out.u32(1000)?; // movie timescale
    out.u32(u32::try_from(movie_duration_ms).unwrap_or(u32::MAX))?;
    out.u32(0x0001_0000)?; // rate 1.0
    out.u16(0x0100)?; // volume
    out.u16(0)?; // reserved
    out.u32(0)?;
    out.u32(0)?;
    write_matrix(out)?;
    out.bytes(&[0u8; 24])?; // pre_defined
    let next_track_id = if audio.is_some() { 3u32 } else { 2u32 };
    out.u32(next_track_id)?;
    end_box(out, mvhd)?;

    write_video_trak(
        out,
        video,
        video_duration_ms + u64::from(video_delay_ms),
        video_delay_ms,
    )?;
    if let Some(audio) = audio.filter(|track| !track.samples.is_empty()) {
        write_audio_trak(
            out,
            audio,
            movie_duration_ms + u64::from(audio_delay_ms),
            audio_delay_ms,
        )?;
    }

    end_box(out, moov)
}

/// `edts`/`elst` holding a track back by `delay_ms` (the movie timescale is
/// 1000): one empty edit, then the media itself.
fn write_edts(out: &mut Out, delay_ms: u32) -> Result<()> {
    let edts = begin_box(out, b"edts")?;
    let elst = begin_box(out, b"elst")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(2)?; // entry count
    out.u32(delay_ms)?; // empty edit: wait this long before the media starts
    out.u32(u32::MAX)?; // media_time -1 marks an empty edit
    out.u32(0x0001_0000)?; // media_rate 1.0
    out.u32(0)?; // remaining segment duration (0 = rest of the movie)
    out.u32(0)?; // media_time 0: the track's first sample
    out.u32(0x0001_0000)?; // media_rate 1.0
    end_box(out, elst)?;
    end_box(out, edts)
}

fn write_video_trak(
    out: &mut Out,
    track: &VideoTrack,
    duration_ms: u64,
    delay_ms: u32,
) -> Result<()> {
    let trak = begin_box(out, b"trak")?;

    // tkhd
    let tkhd = begin_box(out, b"tkhd")?;
    write_full_box_header(out, 0, 0x0000_0007)?;
    out.u32(0)?;
    out.u32(0)?;
    out.u32(1)?; // track ID
    out.u32(0)?; // reserved
    out.u32(u32::try_from(duration_ms).unwrap_or(u32::MAX))?;
    out.u32(0)?;
    out.u32(0)?;
    out.u16(0)?; // layer
    out.u16(0)?; // alternate group
    out.u16(0)?; // volume (video)
    out.u16(0)?; // reserved
    write_matrix(out)?;
    out.u32(track.config.width << 16)?;
    out.u32(track.config.height << 16)?;
    end_box(out, tkhd)?;

    if delay_ms > 0 {
        write_edts(out, delay_ms)?;
    }

    // mdia
    let mdia = begin_box(out, b"mdia")?;
    write_mdhd(
        out,
        90_000,
        track.durations.iter().map(|d| u64::from(*d)).sum(),
    )?;
    write_hdlr(out, b"vide", "VideoHandler")?;

    let minf = begin_box(out, b"minf")?;
    let vmhd = begin_box(out, b"vmhd")?;
    write_full_box_header(out, 0, 1)?;
    out.u16(0)?;
    out.u16(0)?;
    out.u16(0)?;
    out.u16(0)?;
    end_box(out, vmhd)?;
    write_dinf(out)?;
    write_video_stbl(out, track)?;
    end_box(out, minf)?;
    end_box(out, mdia)?;
    end_box(out, trak)
}

fn write_audio_trak(
    out: &mut Out,
    track: &AudioTrack,
    duration_ms: u64,
    delay_ms: u32,
) -> Result<()> {
    let trak = begin_box(out, b"trak")?;

    let tkhd = begin_box(out, b"tkhd")?;
    write_full_box_header(out, 0, 0x0000_0007)?;
    out.u32(0)?;
    out.u32(0)?;
    out.u32(2)?; // track ID
    out.u32(0)?;
    out.u32(u32::try_from(duration_ms).unwrap_or(u32::MAX))?;
    out.u32(0)?;
    out.u32(0)?;
    out.u16(0)?;
    out.u16(0)?;
    out.u16(0x0100)?; // volume (audio)
    out.u16(0)?;
    write_matrix(out)?;
    out.u32(0)?;
    out.u32(0)?;
    end_box(out, tkhd)?;

    if delay_ms > 0 {
        write_edts(out, delay_ms)?;
    }

    let mdia = begin_box(out, b"mdia")?;
    let frames = track.samples.len() as u64;
    write_mdhd(
        out,
        track.config.sample_rate,
        frames * u64::from(track.frame_samples),
    )?;
    write_hdlr(out, b"soun", "SoundHandler")?;

    let minf = begin_box(out, b"minf")?;
    let smhd = begin_box(out, b"smhd")?;
    write_full_box_header(out, 0, 0)?;
    out.u16(0)?;
    out.u16(0)?;
    end_box(out, smhd)?;
    write_dinf(out)?;
    write_audio_stbl(out, track)?;
    end_box(out, minf)?;
    end_box(out, mdia)?;
    end_box(out, trak)
}

fn write_mdhd(out: &mut Out, timescale: u32, duration: u64) -> Result<()> {
    let mdhd = begin_box(out, b"mdhd")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(0)?;
    out.u32(0)?;
    out.u32(timescale)?;
    out.u32(u32::try_from(duration).unwrap_or(u32::MAX))?;
    out.u16(0x55C4)?; // language: 'und'
    out.u16(0)?; // pre_defined
    end_box(out, mdhd)
}

fn write_hdlr(out: &mut Out, handler: &[u8; 4], name: &str) -> Result<()> {
    let hdlr = begin_box(out, b"hdlr")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(0)?; // pre_defined
    out.bytes(handler)?;
    out.u32(0)?;
    out.u32(0)?;
    out.u32(0)?;
    out.bytes(name.as_bytes())?;
    out.u8(0)?;
    end_box(out, hdlr)
}

fn write_dinf(out: &mut Out) -> Result<()> {
    let dinf = begin_box(out, b"dinf")?;
    let dref = begin_box(out, b"dref")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(1)?; // entry count
    let url = begin_box(out, b"url ")?;
    write_full_box_header(out, 0, 1)?; // self-contained
    end_box(out, url)?;
    end_box(out, dref)?;
    end_box(out, dinf)
}

fn run_length_runs(values: &[u32]) -> Vec<(u32, u32)> {
    let mut runs: Vec<(u32, u32)> = Vec::new();
    for value in values {
        match runs.last_mut() {
            Some(last) if last.1 == *value => last.0 += 1,
            _ => runs.push((1, *value)),
        }
    }
    runs
}

fn write_stts(out: &mut Out, durations: &[u32]) -> Result<()> {
    let stts = begin_box(out, b"stts")?;
    write_full_box_header(out, 0, 0)?;
    let runs = run_length_runs(durations);
    out.u32(runs.len() as u32)?;
    for (count, delta) in runs {
        out.u32(count)?;
        out.u32(delta)?;
    }
    end_box(out, stts)
}

fn write_ctts(out: &mut Out, offsets: &[i32]) -> Result<()> {
    let stts = begin_box(out, b"ctts")?;
    write_full_box_header(out, 0, 0)?;
    let normalized: Vec<u32> = offsets.iter().map(|value| (*value).max(0) as u32).collect();
    let runs = run_length_runs(&normalized);
    out.u32(runs.len() as u32)?;
    for (count, offset) in runs {
        out.u32(count)?;
        out.u32(offset)?;
    }
    end_box(out, stts)
}

fn write_stss(out: &mut Out, keyframes: &[u32], sample_count: usize) -> Result<()> {
    if keyframes.is_empty() {
        bail!("video track contains no sync samples");
    }
    if keyframes.len() == sample_count {
        return Ok(());
    }
    let stss = begin_box(out, b"stss")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(keyframes.len() as u32)?;
    for sample in keyframes {
        out.u32(*sample)?;
    }
    end_box(out, stss)
}

fn write_stsc(out: &mut Out) -> Result<()> {
    let stsc = begin_box(out, b"stsc")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(1)?; // entry count: one sample per chunk for the whole file
    out.u32(1)?; // first chunk
    out.u32(1)?; // samples per chunk
    out.u32(1)?; // sample description index
    end_box(out, stsc)
}

fn write_stsz(out: &mut Out, samples: &[Sample]) -> Result<()> {
    let stsz = begin_box(out, b"stsz")?;
    write_full_box_header(out, 0, 0)?;
    let uniform = samples
        .first()
        .map(|first| first.size)
        .filter(|size| samples.iter().all(|sample| sample.size == *size));
    match uniform {
        Some(size) => {
            out.u32(size)?;
            out.u32(samples.len() as u32)?;
        }
        None => {
            out.u32(0)?;
            out.u32(samples.len() as u32)?;
            for sample in samples {
                out.u32(sample.size)?;
            }
        }
    }
    end_box(out, stsz)
}

fn write_stco(out: &mut Out, samples: &[Sample]) -> Result<()> {
    let needs_co64 = samples
        .iter()
        .any(|sample| sample.offset > u64::from(u32::MAX));
    if needs_co64 {
        let co64 = begin_box(out, b"co64")?;
        write_full_box_header(out, 0, 0)?;
        out.u32(samples.len() as u32)?;
        for sample in samples {
            out.u64(sample.offset)?;
        }
        end_box(out, co64)
    } else {
        let stco = begin_box(out, b"stco")?;
        write_full_box_header(out, 0, 0)?;
        out.u32(samples.len() as u32)?;
        for sample in samples {
            out.u32(sample.offset as u32)?;
        }
        end_box(out, stco)
    }
}

fn write_video_stbl(out: &mut Out, track: &VideoTrack) -> Result<()> {
    let stbl = begin_box(out, b"stbl")?;

    let stsd = begin_box(out, b"stsd")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(1)?; // entry count
    write_avc1(out, &track.config)?;
    end_box(out, stsd)?;

    write_stts(out, &track.durations)?;
    if track.cts_offsets.iter().any(|value| *value != 0) {
        write_ctts(out, &track.cts_offsets)?;
    }
    write_stss(out, &track.keyframes, track.samples.len())?;
    write_stsc(out)?;
    write_stsz(out, &track.samples)?;
    write_stco(out, &track.samples)?;
    end_box(out, stbl)
}

fn write_audio_stbl(out: &mut Out, track: &AudioTrack) -> Result<()> {
    let stbl = begin_box(out, b"stbl")?;

    let stsd = begin_box(out, b"stsd")?;
    write_full_box_header(out, 0, 0)?;
    out.u32(1)?;
    write_mp4a(out, &track.config)?;
    end_box(out, stsd)?;

    let durations = vec![track.frame_samples; track.samples.len()];
    write_stts(out, &durations)?;
    write_stsc(out)?;
    write_stsz(out, &track.samples)?;
    write_stco(out, &track.samples)?;
    end_box(out, stbl)
}

fn write_avc1(out: &mut Out, config: &AvcConfig) -> Result<()> {
    let avc1 = begin_box(out, b"avc1")?;
    out.bytes(&[0u8; 6])?;
    out.u16(1)?; // data reference index
    out.u16(0)?; // pre_defined
    out.u16(0)?; // reserved
    out.bytes(&[0u8; 12])?; // pre_defined
    out.u16(u16::try_from(config.width).unwrap_or(u16::MAX))?;
    out.u16(u16::try_from(config.height).unwrap_or(u16::MAX))?;
    out.u32(0x0048_0000)?; // horizontal resolution 72 dpi
    out.u32(0x0048_0000)?; // vertical resolution 72 dpi
    out.u32(0)?; // reserved
    out.u16(1)?; // frame count
    out.bytes(&[0u8; 32])?; // compressor name
    out.u16(0x0018)?; // depth
    out.u16(0xFFFF)?; // pre_defined = -1

    let avcc = begin_box(out, b"avcC")?;
    out.u8(1)?; // configuration version
    out.u8(config.profile)?;
    out.u8(config.compat)?;
    out.u8(config.level)?;
    out.u8(0xFF)?; // 6 bits reserved + lengthSizeMinusOne = 3 (4-byte lengths)
    out.u8(0xE1)?; // 3 bits reserved + numOfSequenceParameterSets = 1
    let sps_len = u16::try_from(config.sps.len()).context("SPS too large")?;
    out.u16(sps_len)?;
    out.bytes(&config.sps)?;
    out.u8(1)?; // numOfPictureParameterSets
    let pps_len = u16::try_from(config.pps.len()).context("PPS too large")?;
    out.u16(pps_len)?;
    out.bytes(&config.pps)?;
    end_box(out, avcc)?;

    end_box(out, avc1)
}

fn write_mp4a(out: &mut Out, config: &AacConfig) -> Result<()> {
    let mp4a = begin_box(out, b"mp4a")?;
    out.bytes(&[0u8; 6])?;
    out.u16(1)?; // data reference index
    out.u32(0)?; // reserved
    out.u32(0)?; // reserved
    out.u16(config.channels)?;
    out.u16(16)?; // sample size
    out.u16(0)?; // pre_defined
    out.u16(0)?; // reserved
    out.u32(config.sample_rate << 16)?; // 16.16 fixed point

    let esds = begin_box(out, b"esds")?;
    write_full_box_header(out, 0, 0)?;

    let asc = &config.asc;
    let dcd_len = 13 + 2 + asc.len();
    let es_len = 3 + 2 + dcd_len + 3;
    write_descriptor_header(out, 0x03, es_len)?;
    out.u16(0)?; // ES_ID
    out.u8(0)?; // flags
    write_descriptor_header(out, 0x04, dcd_len)?;
    out.u8(0x40)?; // objectTypeIndication: MPEG-4 Audio
    out.u8(0x15)?; // streamType: audio, upStream 0, reserved 1
    out.u24(0)?; // bufferSizeDB
    out.u32(0)?; // maxBitrate
    out.u32(0)?; // avgBitrate
    write_descriptor_header(out, 0x05, asc.len())?;
    out.bytes(asc)?;
    write_descriptor_header(out, 0x06, 1)?;
    out.u8(0x02)?; // SLConfigDescriptor: predefined = MP4
    end_box(out, esds)?;

    end_box(out, mp4a)
}

/// MPEG-4 descriptor length encoding (7 bits per byte, high bit = continue).
fn write_descriptor_header(out: &mut Out, tag: u8, len: usize) -> Result<()> {
    out.u8(tag)?;
    let mut value = len;
    let mut encoded = [0u8; 4];
    let mut used = 0usize;
    loop {
        encoded[used] = (value & 0x7F) as u8;
        used += 1;
        value >>= 7;
        if value == 0 {
            break;
        }
        if used == 4 {
            bail!("descriptor length too large");
        }
    }
    for index in (0..used).rev() {
        let mut byte = encoded[index];
        if index != 0 {
            byte |= 0x80;
        }
        out.u8(byte)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_length_roundtrip() {
        // 127 -> 0x7F, 128 -> 0x81 0x00, 16383 -> 0xFF 0x7F
        let mut file = tempfile();
        let mut out = Out::new(file.take_file());
        write_descriptor_header(&mut out, 0x05, 127).unwrap();
        write_descriptor_header(&mut out, 0x05, 128).unwrap();
        write_descriptor_header(&mut out, 0x05, 16383).unwrap();
        out.flush().unwrap();
        let bytes = std::fs::read(&file.path).unwrap();
        assert_eq!(bytes, vec![0x05, 0x7F, 0x05, 0x81, 0x00, 0x05, 0xFF, 0x7F]);
    }

    struct TempFile {
        path: std::path::PathBuf,
        file: Option<File>,
    }
    impl TempFile {
        fn take_file(&mut self) -> File {
            self.file.take().unwrap()
        }
    }

    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
        }
    }

    fn tempfile() -> TempFile {
        let path =
            std::env::temp_dir().join(format!("segmeris-mp4-test-{}.bin", std::process::id()));
        let file = File::create(&path).unwrap();
        TempFile {
            path,
            file: Some(file),
        }
    }

    /// Unique, self-deleting `.mp4` path for the muxer tests: tests share one
    /// process, so the pid alone would collide.
    struct TempPath {
        path: std::path::PathBuf,
    }

    impl Drop for TempPath {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
        }
    }

    fn temp_path(label: &str) -> TempPath {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        TempPath {
            path: std::env::temp_dir().join(format!(
                "segmeris-mp4-{label}-{}-{sequence}.mp4",
                std::process::id()
            )),
        }
    }

    fn video_config() -> AvcConfig {
        AvcConfig {
            sps: vec![0x67, 0x42, 0x00, 0x1E],
            pps: vec![0x68, 0xCE, 0x3C, 0x80],
            profile: 0x42,
            compat: 0x00,
            level: 0x1E,
            width: 320,
            height: 240,
            frame_interval_ticks: Some(3000),
        }
    }

    fn audio_config() -> AacConfig {
        AacConfig {
            asc: vec![0x11, 0x90],
            sample_rate: 48_000,
            channels: 2,
        }
    }

    /// Mux one second of video (30 frames @ 30 fps) plus 981 ms of AAC, with
    /// `first_cts_offset` on the first picture and the given source starts.
    fn mux_fixture(
        path: &Path,
        first_cts_offset: i32,
        source_starts: (Option<i64>, Option<i64>),
    ) -> Mp4Summary {
        let mut writer = Mp4Writer::create(path).unwrap();
        writer.set_source_starts(source_starts.0, source_starts.1);
        writer.set_video_config(video_config());
        writer.set_audio_config(audio_config());
        for index in 0..30 {
            writer
                .write_video_sample(
                    &[0, 0, 0, 4, 0x65, 0x88, 0x84, 0x00],
                    i64::from(index) * 3000,
                    if index == 0 { first_cts_offset } else { 0 },
                    index % 15 == 0,
                )
                .unwrap();
        }
        for _ in 0..46 {
            writer.write_audio_sample(&[0x21, 0x10, 0x05]).unwrap();
        }
        writer.finish().unwrap()
    }

    /// Every box of `kind` lying directly inside `start..end`.
    fn child_boxes(bytes: &[u8], start: usize, end: usize, kind: &[u8; 4]) -> Vec<(usize, usize)> {
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

    /// `(handler, empty-edit duration in ms, media_time)` for every track that
    /// carries an `edts`/`elst`, in file order.
    fn edit_lists(path: &Path) -> Vec<(&'static str, u32, i32)> {
        let bytes = std::fs::read(path).unwrap();
        let (moov, moov_end) = child_boxes(&bytes, 0, bytes.len(), b"moov")[0];
        let mut edits = Vec::new();
        for (trak, trak_end) in child_boxes(&bytes, moov + 8, moov_end, b"trak") {
            let body = trak + 8;
            let (mdia, mdia_end) = child_boxes(&bytes, body, trak_end, b"mdia")[0];
            let (hdlr, _) = child_boxes(&bytes, mdia + 8, mdia_end, b"hdlr")[0];
            let handler = match &bytes[hdlr + 16..hdlr + 20] {
                b"vide" => "vide",
                b"soun" => "soun",
                other => panic!("unexpected handler {other:?}"),
            };
            let Some((edts, edts_end)) = child_boxes(&bytes, body, trak_end, b"edts")
                .into_iter()
                .next()
            else {
                continue;
            };
            let (elst, _) = child_boxes(&bytes, edts + 8, edts_end, b"elst")[0];
            let entries = u32::from_be_bytes(bytes[elst + 12..elst + 16].try_into().unwrap());
            assert_eq!(entries, 2, "expected an empty edit followed by the media");
            let duration = u32::from_be_bytes(bytes[elst + 16..elst + 20].try_into().unwrap());
            let media_time = i32::from_be_bytes(bytes[elst + 20..elst + 24].try_into().unwrap());
            edits.push((handler, duration, media_time));
        }
        edits
    }

    #[test]
    fn delays_the_audio_track_that_starts_later_in_the_source() {
        let file = temp_path("audio-defers");
        let summary = mux_fixture(&file.path, 3600, (Some(133_200), Some(176_280)));

        let edits = edit_lists(&file.path);
        assert_eq!(edits.len(), 1, "only the later track needs an edit list");
        let (handler, delay_ms, media_time) = edits[0];
        assert_eq!(handler, "soun");
        assert_eq!(delay_ms, 519, "audio waits 46680 ticks ≈ 519 ms");
        assert_eq!(media_time, -1, "the first edit must be empty");

        let duration_ms = (summary.duration_seconds * 1000.0).round() as u64;
        assert_eq!(duration_ms, 1_000 + 519, "the movie must cover the delay");
    }

    #[test]
    fn delays_the_video_track_that_starts_later_in_the_source() {
        let file = temp_path("video-defers");
        let summary = mux_fixture(&file.path, 0, (Some(176_280), Some(133_200)));

        let edits = edit_lists(&file.path);
        assert_eq!(edits.len(), 1);
        let (handler, delay_ms, media_time) = edits[0];
        assert_eq!(handler, "vide");
        assert_eq!(delay_ms, 479, "478.67 ms rounds to the nearest millisecond");
        assert_eq!(media_time, -1);

        let duration_ms = (summary.duration_seconds * 1000.0).round() as u64;
        assert_eq!(duration_ms, 1_000 + 479);
    }

    #[test]
    fn keeps_the_zero_based_timeline_without_source_starts() {
        let file = temp_path("no-origins");
        mux_fixture(&file.path, 3600, (None, None));
        assert!(edit_lists(&file.path).is_empty());
    }

    #[test]
    fn ignores_sub_millisecond_offsets() {
        // 30 ticks = 0.33 ms, below what a timescale of 1000 can express.
        let file = temp_path("sub-millisecond");
        mux_fixture(&file.path, 0, (Some(100_000), Some(100_030)));
        assert!(edit_lists(&file.path).is_empty());
    }
}
