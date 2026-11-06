use crate::api::downloader::{self, DownloadOptions, MediaSource, ProgressUpdate, RequestContext};
use anyhow::Result;
use std::sync::Arc;

pub type DownloadProgressHandler = Arc<dyn Fn(ProgressUpdate) + Send + Sync>;

#[allow(clippy::too_many_arguments)]
pub fn hls_to_mp4(
    url: String,
    concurrency: i32,
    output: String,
    retries: i32,
    video_bitrate: i32,
    audio_bitrate: i32,
    keep_temp: bool,
    progress: Option<DownloadProgressHandler>,
) -> Result<()> {
    downloader::hls2mp4_core(
        progress.unwrap_or_else(downloader::noop_progress_reporter),
        url,
        concurrency,
        output,
        retries,
        video_bitrate,
        audio_bitrate,
        keep_temp,
    )
}

pub fn download_media(
    source: MediaSource,
    output: String,
    options: DownloadOptions,
    request_context: RequestContext,
    progress: Option<DownloadProgressHandler>,
) -> Result<()> {
    downloader::download_media_with_context_core(
        progress.unwrap_or_else(downloader::noop_progress_reporter),
        source,
        output,
        options,
        request_context,
    )
}
