use super::run_ffmpeg;
use anyhow::{bail, Result};
use std::{path::Path, time::Duration};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum AccelType {
    Nvidia,
    Amd,
    IntelQuickSync,
    LinuxVaapi,
    LinuxV4l2M2m,
    RockchipMpp,
    AppleVideoToolbox,
    Cpu,
}

impl AccelType {
    pub(super) fn label(self) -> &'static str {
        match self {
            Self::Nvidia => "NVIDIA NVENC",
            Self::Amd => "AMD AMF",
            Self::IntelQuickSync => "Intel Quick Sync",
            Self::LinuxVaapi => "Linux VAAPI",
            Self::LinuxV4l2M2m => "Linux V4L2 M2M",
            Self::RockchipMpp => "Rockchip MPP",
            Self::AppleVideoToolbox => "Apple VideoToolbox",
            Self::Cpu => "CPU libx264",
        }
    }

    pub(super) fn encoder(self) -> &'static str {
        match self {
            Self::Nvidia => "h264_nvenc",
            Self::Amd => "h264_amf",
            Self::IntelQuickSync => "h264_qsv",
            Self::LinuxVaapi => "h264_vaapi",
            Self::LinuxV4l2M2m => "h264_v4l2m2m",
            Self::RockchipMpp => "h264_rkmpp",
            Self::AppleVideoToolbox => "h264_videotoolbox",
            Self::Cpu => "libx264",
        }
    }
}

pub(super) fn detect_acceleration(ffmpeg_path: &Path) -> Result<AccelType> {
    let output = run_ffmpeg(
        ffmpeg_path,
        &["-hide_banner".to_string(), "-encoders".to_string()],
        Duration::from_secs(30),
    )?;

    if !output.status.success() {
        bail!("FFmpeg could not enumerate its encoders");
    }
    let list = String::from_utf8_lossy(&output.stdout);
    let candidates = [
        AccelType::Nvidia,
        AccelType::Amd,
        AccelType::IntelQuickSync,
        #[cfg(target_os = "linux")]
        AccelType::LinuxVaapi,
        #[cfg(target_os = "linux")]
        AccelType::LinuxV4l2M2m,
        #[cfg(target_os = "linux")]
        AccelType::RockchipMpp,
        #[cfg(target_os = "macos")]
        AccelType::AppleVideoToolbox,
    ];
    for candidate in candidates {
        if lists_encoder(&list, candidate.encoder()) && probe_ffmpeg_encoder(ffmpeg_path, candidate)
        {
            return Ok(candidate);
        }
    }
    if lists_encoder(&list, AccelType::Cpu.encoder())
        && probe_ffmpeg_encoder(ffmpeg_path, AccelType::Cpu)
    {
        return Ok(AccelType::Cpu);
    }
    bail!("FFmpeg is installed but no usable H.264 encoder passed the runtime probe")
}

fn lists_encoder(list: &str, encoder: &str) -> bool {
    list.lines()
        .any(|line| line.split_whitespace().nth(1) == Some(encoder))
}

fn probe_ffmpeg_encoder(ffmpeg_path: &Path, accel: AccelType) -> bool {
    run_ffmpeg(ffmpeg_path, &probe_arguments(accel), Duration::from_secs(8))
        .is_ok_and(|output| output.status.success())
}

fn probe_arguments(accel: AccelType) -> Vec<String> {
    let mut args: Vec<String> = [
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-f",
        "lavfi",
        "-i",
        "color=c=black:s=1280x720:r=30",
        "-frames:v",
        "3",
        "-an",
        "-c:v",
        accel.encoder(),
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    push_accel_encode_args(&mut args, accel);
    args.extend(["-f", "null", "-"].into_iter().map(str::to_owned));
    args
}

/// Appends the hardware-acceleration specific arguments (device init, frame
/// upload filters, encoder presets) for a real transcode run.
pub(super) fn push_accel_encode_args(args: &mut Vec<String>, accel: AccelType) {
    match accel {
        AccelType::Nvidia => args.extend([
            "-preset".to_string(),
            "p4".to_string(),
            "-rc".to_string(),
            "vbr".to_string(),
        ]),
        AccelType::Cpu => args.extend(["-preset".to_string(), "medium".to_string()]),
        AccelType::LinuxVaapi => args.extend([
            "-vaapi_device".to_string(),
            "/dev/dri/renderD128".to_string(),
            "-vf".to_string(),
            "format=nv12,hwupload".to_string(),
        ]),
        AccelType::IntelQuickSync => args.extend([
            "-init_hw_device".to_string(),
            "qsv=hw".to_string(),
            "-filter_hw_device".to_string(),
            "hw".to_string(),
            "-vf".to_string(),
            "format=nv12,hwupload=extra_hw_frames=64".to_string(),
        ]),
        AccelType::LinuxV4l2M2m | AccelType::RockchipMpp => {
            args.extend(["-vf".to_string(), "format=nv12".to_string()])
        }
        AccelType::AppleVideoToolbox => args.extend(["-allow_sw".to_string(), "0".to_string()]),
        AccelType::Amd => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoder_listing_matches_names_not_descriptions_or_prefixes() {
        let list =
            " V..... h264_nvenc NVIDIA encoder\n V..... libx264 H.264 / h264_qsv compatible\n";
        assert!(lists_encoder(list, "h264_nvenc"));
        assert!(!lists_encoder(list, "h264"));
        assert!(!lists_encoder(list, "h264_qsv"));
    }

    #[test]
    fn probes_use_real_conversion_settings_and_supported_frame_size() {
        for accel in [
            AccelType::Nvidia,
            AccelType::Amd,
            AccelType::IntelQuickSync,
            AccelType::LinuxVaapi,
            AccelType::LinuxV4l2M2m,
            AccelType::RockchipMpp,
            AccelType::AppleVideoToolbox,
            AccelType::Cpu,
        ] {
            let args = probe_arguments(accel);
            let mut conversion = Vec::new();
            push_accel_encode_args(&mut conversion, accel);
            assert!(args
                .iter()
                .any(|arg| arg == "color=c=black:s=1280x720:r=30"));
            if !conversion.is_empty() {
                assert!(args
                    .windows(conversion.len())
                    .any(|part| part == conversion));
            }
        }
        let args = probe_arguments(AccelType::AppleVideoToolbox);
        assert!(args.windows(2).any(|pair| pair == ["-allow_sw", "0"]));
    }
}
