//! Streaming media transfers, validator-based resumption and CDN fallback.
use super::{emit_progress, retry_backoff_delay, ProgressReporter};
use crate::crypto::Sha256;
use crate::net::SyncHttpClient;
use anyhow::{anyhow, bail, Context, Result};
use log::warn;
use std::io::Write;
use std::path::{Path, PathBuf};
use url::Url;
use uuid::Uuid;

pub(super) fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0usize;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", bytes, UNITS[unit])
    } else {
        format!("{:.1} {}", value, UNITS[unit])
    }
}

// FRB auto-bridges every `Default` type it scans; this resumption
// bookkeeping is crate-internal and must stay out of the generated API.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct ResumableMetadata {
    pub(super) etag: Option<String>,
    pub(super) last_modified: Option<String>,
    pub(super) total_length: Option<u64>,
}

impl ResumableMetadata {
    pub(super) fn if_range_value(&self) -> Option<&str> {
        self.etag.as_deref().or(self.last_modified.as_deref())
    }

    pub(super) fn has_resume_validator(&self) -> bool {
        self.etag.is_some() || self.last_modified.is_some()
    }
}

pub(super) fn resumable_metadata_path(partial_path: &Path) -> PathBuf {
    let mut name = partial_path.file_name().unwrap_or_default().to_os_string();
    name.push(".meta");
    partial_path.with_file_name(name)
}

pub(super) fn response_header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(header_name, _)| header_name.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.trim())
}

pub(super) fn resumable_metadata_from_response(
    headers: &[(String, String)],
    total_length: Option<u64>,
) -> ResumableMetadata {
    let etag = response_header(headers, "etag")
        .filter(|value| !value.to_ascii_lowercase().starts_with("w/"))
        .map(str::to_string);
    ResumableMetadata {
        etag,
        last_modified: response_header(headers, "last-modified").map(str::to_string),
        total_length,
    }
}

pub(super) fn resumable_metadata_matches_response(
    saved: &ResumableMetadata,
    headers: &[(String, String)],
    response_total: Option<u64>,
) -> bool {
    let validator_matches = match saved.etag.as_deref() {
        Some(saved_etag) => response_header(headers, "etag") == Some(saved_etag),
        None => match saved.last_modified.as_deref() {
            Some(saved_last_modified) => {
                response_header(headers, "last-modified") == Some(saved_last_modified)
            }
            None => true,
        },
    };
    if !validator_matches {
        return false;
    }
    if saved
        .total_length
        .zip(response_total)
        .is_some_and(|(saved_total, current_total)| saved_total != current_total)
    {
        return false;
    }
    if let (Some(saved_etag), Some(response_etag)) =
        (saved.etag.as_deref(), response_header(headers, "etag"))
    {
        if saved_etag != response_etag {
            return false;
        }
    }
    if let (Some(saved_last_modified), Some(response_last_modified)) = (
        saved.last_modified.as_deref(),
        response_header(headers, "last-modified"),
    ) {
        if saved_last_modified != response_last_modified {
            return false;
        }
    }
    true
}

pub(super) fn read_resumable_metadata(partial_path: &Path) -> Option<ResumableMetadata> {
    let contents = std::fs::read_to_string(resumable_metadata_path(partial_path)).ok()?;
    let mut lines = contents.lines();
    if lines.next() != Some("v1") {
        return None;
    }
    let total_length = match lines.next()? {
        "" => None,
        value => Some(value.parse::<u64>().ok()?),
    };
    let etag = lines
        .next()
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let last_modified = lines
        .next()
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if lines.next().is_some() {
        return None;
    }
    Some(ResumableMetadata {
        etag,
        last_modified,
        total_length,
    })
}

pub(super) fn write_resumable_metadata(
    partial_path: &Path,
    metadata: &ResumableMetadata,
) -> Result<()> {
    for value in [metadata.etag.as_deref(), metadata.last_modified.as_deref()]
        .into_iter()
        .flatten()
    {
        if value.contains(['\r', '\n']) {
            bail!("Invalid line break in media response validator");
        }
    }

    let metadata_path = resumable_metadata_path(partial_path);
    let token = Uuid::new_v4().simple().to_string();
    let temporary_path = metadata_path.with_file_name(format!(
        "{}.tmp-{}",
        metadata_path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy(),
        token
    ));
    let contents = format!(
        "v1\n{}\n{}\n{}\n",
        metadata
            .total_length
            .map(|value| value.to_string())
            .unwrap_or_default(),
        metadata.etag.as_deref().unwrap_or_default(),
        metadata.last_modified.as_deref().unwrap_or_default(),
    );

    let result = (|| -> Result<()> {
        let mut file = std::fs::File::create(&temporary_path)?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        drop(file);
        match std::fs::remove_file(&metadata_path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        std::fs::rename(&temporary_path, &metadata_path)?;
        Ok(())
    })();

    if result.is_err() {
        let _ = std::fs::remove_file(temporary_path);
    }
    result.with_context(|| {
        format!(
            "Failed to persist media resume metadata: {}",
            metadata_path.display()
        )
    })
}

pub(super) fn clear_resumable_partial(partial_path: &Path) -> Result<()> {
    for path in [
        partial_path.to_path_buf(),
        resumable_metadata_path(partial_path),
    ] {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("Failed to clear stale partial file: {}", path.display())
                });
            }
        }
    }
    Ok(())
}

pub(super) fn is_complete_unsatisfied_range(range: ContentRange, downloaded: u64) -> bool {
    range.start.is_none()
        && range.end.is_none()
        && range.total == Some(downloaded)
        && downloaded > 0
}

pub(super) fn range_response_has_safe_resume_identity(
    metadata: &ResumableMetadata,
    start: u64,
    total: Option<u64>,
    response_length: u64,
) -> bool {
    metadata.has_resume_validator() || (start == 0 && total == Some(response_length))
}

/// Stream media with bounded memory. Range-capable servers support validated
/// resumption; full responses are streamed to disk regardless of their size.
#[allow(clippy::too_many_arguments)]
pub(super) fn stream_media_response_to_file(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
    path: &Path,
    progress_start: f64,
    progress_end: f64,
    reporter: &ProgressReporter,
    label: &str,
) -> Result<()> {
    const CHUNK: u64 = 8 * 1024 * 1024;

    let partial_path = resumable_partial_path(path, url, headers);
    let mut downloaded = std::fs::metadata(&partial_path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let mut resume_metadata = if downloaded > 0 {
        match read_resumable_metadata(&partial_path) {
            Some(metadata) if metadata.has_resume_validator() => Some(metadata),
            None => {
                clear_resumable_partial(&partial_path)?;
                downloaded = 0;
                None
            }
            Some(_) => {
                clear_resumable_partial(&partial_path)?;
                downloaded = 0;
                None
            }
        }
    } else {
        None
    };
    let mut last_reported = 0u64;
    let mut use_range = true;
    emit_progress(reporter, label, progress_start);

    loop {
        let start = downloaded;
        let end = start.saturating_add(CHUNK - 1);
        let mut range_headers = headers.to_vec();
        if start > 0 {
            if let Some(if_range) = resume_metadata
                .as_ref()
                .and_then(ResumableMetadata::if_range_value)
            {
                range_headers.retain(|(name, _)| !name.eq_ignore_ascii_case("if-range"));
                range_headers.push(("If-Range".to_string(), if_range.to_string()));
            }
        }
        let response = if use_range {
            client.stream_range(url, &range_headers, start, end)?
        } else {
            client.stream(url, headers)?
        };
        let status = response.status;
        let response_headers = response.headers;
        let mut body = response.body;
        if response_header(&response_headers, "content-encoding")
            .is_some_and(|v| !v.eq_ignore_ascii_case("identity"))
        {
            bail!("Media response must use identity content encoding");
        }
        if let Some(content_type) = response_headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("content-type"))
            .map(|(_, value)| value.to_ascii_lowercase())
        {
            if content_type.starts_with("text/html")
                || content_type.starts_with("application/json")
                || content_type.starts_with("text/json")
            {
                bail!(
                    "Media request returned non-media content type {}",
                    content_type
                );
            }
        }

        if status == 416 {
            let range = parse_content_range(&response_headers)?;
            let validators_match = resume_metadata.as_ref().is_none_or(|saved| {
                resumable_metadata_matches_response(saved, &response_headers, range.total)
            });
            if is_complete_unsatisfied_range(range, downloaded) && validators_match {
                replace_download_output(&partial_path, path)?;
                let _ = std::fs::remove_file(resumable_metadata_path(&partial_path));
                break;
            }
            if start > 0 {
                clear_resumable_partial(&partial_path)?;
                downloaded = 0;
                resume_metadata = None;
                continue;
            }
            bail!("Media Range request returned HTTP 416 at byte {}", start);
        }
        if !(200..300).contains(&status) {
            bail!("Media request returned HTTP {}", status);
        }

        let total = if status == 206 {
            let range = parse_content_range(&response_headers)?;
            if range.start != Some(start) {
                clear_resumable_partial(&partial_path)?;
                bail!(
                    "Media Range response did not start at requested byte {}",
                    start
                );
            }
            let range_end = range
                .end
                .ok_or_else(|| anyhow!("Media Range response omitted its end offset"))?;
            let range_length = range_end
                .checked_sub(start)
                .and_then(|length| length.checked_add(1));
            if range_end > end || range_length.is_none() {
                bail!(
                    "Media Range response length mismatch: received {} bytes for {}-{}",
                    0,
                    start,
                    range_end
                );
            }
            range.total
        } else {
            if start > 0 {
                downloaded = 0;
            }
            response_headers
                .iter()
                .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                .and_then(|(_, value)| value.trim().parse::<u64>().ok())
        };

        if status == 206
            && start > 0
            && resume_metadata.as_ref().is_some_and(|saved| {
                !resumable_metadata_matches_response(saved, &response_headers, total)
            })
        {
            clear_resumable_partial(&partial_path)?;
            downloaded = 0;
            resume_metadata = None;
            continue;
        }
        let response_metadata = resumable_metadata_from_response(&response_headers, total);
        let mut next_metadata = if status == 200 || start == 0 {
            response_metadata
        } else {
            let mut metadata = resume_metadata.clone().unwrap_or_default();
            if metadata.etag.is_none() {
                metadata.etag = response_metadata.etag;
            }
            if metadata.last_modified.is_none() {
                metadata.last_modified = response_metadata.last_modified;
            }
            if metadata.total_length.is_none() {
                metadata.total_length = response_metadata.total_length;
            }
            metadata
        };
        if status == 200 {
            next_metadata.total_length = total;
        }
        if status == 206
            && !range_response_has_safe_resume_identity(
                &next_metadata,
                start,
                total,
                parse_content_range(&response_headers)?
                    .end
                    .unwrap_or(start)
                    .saturating_sub(start)
                    + 1,
            )
        {
            clear_resumable_partial(&partial_path)?;
            if !use_range {
                bail!("Server returned an unrequested partial response without validators");
            }
            use_range = false;
            downloaded = 0;
            resume_metadata = None;
            continue;
        }
        write_resumable_metadata(&partial_path, &next_metadata)?;
        resume_metadata = Some(next_metadata);
        let mut output = if status == 200 {
            std::fs::File::create(&partial_path)
        } else {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&partial_path)
        }
        .with_context(|| format!("Failed to create media file: {}", partial_path.display()))?;
        let mut received = 0u64;
        while let Some(chunk) = body.next_chunk()? {
            output.write_all(&chunk)?;
            received += chunk.len() as u64;
            if received.saturating_sub(last_reported) >= 512 * 1024 {
                let count = downloaded + received;
                let progress = total
                    .filter(|n| *n > 0)
                    .map(|n| {
                        progress_start
                            + (count as f64 / n as f64).min(1.0) * (progress_end - progress_start)
                    })
                    .unwrap_or(progress_start);
                emit_progress(
                    reporter,
                    format!("{} [{}]", label, human_bytes(count)),
                    progress,
                );
                last_reported = received;
            }
        }
        if received == 0 {
            bail!("Media response was empty");
        }
        if status == 206 {
            let range = parse_content_range(&response_headers)?;
            if range.end.and_then(|n| n.checked_sub(start)).map(|n| n + 1) != Some(received) {
                drop(output);
                clear_resumable_partial(&partial_path)?;
                bail!("Media Range response length mismatch");
            }
        }
        output.flush()?;
        output.sync_data()?;
        drop(output);
        downloaded = downloaded.saturating_add(received);

        if total.is_some_and(|total| downloaded > total) {
            bail!("Media response exceeded its declared total length");
        }
        if total.is_some_and(|total| downloaded == total) {
            replace_download_output(&partial_path, path)?;
            let _ = std::fs::remove_file(resumable_metadata_path(&partial_path));
            break;
        }
        if status == 200 {
            if let Some(total) = total {
                bail!(
                    "Media response was truncated: expected {} bytes, received {}",
                    total,
                    downloaded
                );
            }
            replace_download_output(&partial_path, path)?;
            let _ = std::fs::remove_file(resumable_metadata_path(&partial_path));
            break;
        }
        if total.is_none() && received < CHUNK {
            bail!("Media server omitted the total length; completion cannot be verified");
        }

        if downloaded.saturating_sub(last_reported) >= 512 * 1024 {
            let progress = total
                .filter(|total| *total > 0)
                .map(|total| {
                    progress_start
                        + (downloaded as f64 / total as f64).clamp(0.0, 1.0)
                            * (progress_end - progress_start)
                })
                .unwrap_or(progress_start);
            let detail = total
                .map(|total| format!("{} / {}", human_bytes(downloaded), human_bytes(total)))
                .unwrap_or_else(|| human_bytes(downloaded));
            emit_progress(reporter, format!("{} [{}]", label, detail), progress);
            last_reported = downloaded;
        }
    }

    emit_progress(
        reporter,
        format!("{} [{}]", label, human_bytes(downloaded)),
        progress_end,
    );
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ContentRange {
    pub(super) start: Option<u64>,
    pub(super) end: Option<u64>,
    pub(super) total: Option<u64>,
}

pub(super) fn parse_content_range(headers: &[(String, String)]) -> Result<ContentRange> {
    let value = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("content-range"))
        .map(|(_, value)| value.trim())
        .ok_or_else(|| anyhow!("Media server omitted the Content-Range header"))?;
    let (unit, value) = value
        .split_once(' ')
        .ok_or_else(|| anyhow!("Invalid Content-Range header"))?;
    if !unit.eq_ignore_ascii_case("bytes") {
        bail!("Unsupported Content-Range unit: {}", unit);
    }
    let (range, total) = value
        .split_once('/')
        .ok_or_else(|| anyhow!("Invalid Content-Range header"))?;
    let total = if total == "*" {
        None
    } else {
        Some(
            total
                .parse::<u64>()
                .context("Invalid Content-Range total length")?,
        )
    };
    if range == "*" {
        return Ok(ContentRange {
            start: None,
            end: None,
            total,
        });
    }
    let (start, end) = range
        .split_once('-')
        .ok_or_else(|| anyhow!("Invalid Content-Range byte interval"))?;
    let start = start
        .parse::<u64>()
        .context("Invalid Content-Range start offset")?;
    let end = end
        .parse::<u64>()
        .context("Invalid Content-Range end offset")?;
    if end < start || total.is_some_and(|total| end >= total) {
        bail!("Invalid Content-Range bounds");
    }
    Ok(ContentRange {
        start: Some(start),
        end: Some(end),
        total,
    })
}

pub(super) fn resumable_partial_path(
    path: &Path,
    url: &str,
    headers: &[(String, String)],
) -> PathBuf {
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("download");
    let mut hasher = Sha256::new();
    for value in std::iter::once(url).chain(
        headers
            .iter()
            .flat_map(|(name, value)| [name.as_str(), value.as_str()]),
    ) {
        hasher.update(&(value.len() as u64).to_be_bytes());
        hasher.update(value.as_bytes());
    }
    let identity = hex::encode(hasher.finalize());
    path.with_file_name(format!("{}.{}.part", filename, &identity[..24]))
}

pub(super) fn replace_download_output(partial_path: &Path, output_path: &Path) -> Result<()> {
    if output_path.exists() {
        let filename = output_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("download");
        let backup_path =
            output_path.with_file_name(format!(".{}.{}.backup", filename, Uuid::new_v4().simple()));
        std::fs::rename(output_path, &backup_path).with_context(|| {
            format!(
                "Failed to preserve existing output: {}",
                output_path.display()
            )
        })?;
        if let Err(error) = std::fs::rename(partial_path, output_path) {
            let _ = std::fs::rename(&backup_path, output_path);
            return Err(error).with_context(|| {
                format!("Failed to finalize media output: {}", output_path.display())
            });
        }
        let _ = std::fs::remove_file(backup_path);
        return Ok(());
    }
    std::fs::rename(partial_path, output_path)
        .with_context(|| format!("Failed to finalize media output: {}", output_path.display()))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn download_with_retries(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
    path: &Path,
    reuse_completed_file: bool,
    retries: u8,
    progress_start: f64,
    progress_end: f64,
    reporter: &ProgressReporter,
    label: &str,
) -> Result<()> {
    if reuse_completed_file
        && std::fs::metadata(path)
            .map(|metadata| metadata.is_file() && metadata.len() > 0)
            .unwrap_or(false)
    {
        return Ok(());
    }
    for attempt in 1..=retries {
        let result = stream_media_response_to_file(
            client,
            url,
            headers,
            path,
            progress_start,
            progress_end,
            reporter,
            label,
        );
        match result {
            Ok(()) => return Ok(()),
            Err(error) => {
                if attempt == retries {
                    let safe_url = safe_media_url_label(url);
                    let details = format!("{error:#}").replace(url, &safe_url);
                    return Err(anyhow!(
                        "Failed to download media from {safe_url}: {details}"
                    ));
                }
                warn!(
                    "Media stream attempt {} failed for {}: {}",
                    attempt,
                    safe_media_url_label(url),
                    format!("{error:#}").replace(url, safe_media_url_label(url).as_str())
                );
                let delay = retry_backoff_delay(attempt, None);
                std::thread::sleep(delay);
            }
        }
    }

    bail!(
        "Failed to download media after retries from {}",
        safe_media_url_label(url)
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn download_with_fallbacks(
    client: &SyncHttpClient,
    primary_url: &str,
    fallback_urls: &[String],
    headers: &[(String, String)],
    path: &Path,
    reuse_completed_file: bool,
    retries: u8,
    progress_start: f64,
    progress_end: f64,
    reporter: &ProgressReporter,
    label: &str,
) -> Result<()> {
    if fallback_urls.is_empty() {
        return download_with_retries(
            client,
            primary_url,
            headers,
            path,
            reuse_completed_file,
            retries,
            progress_start,
            progress_end,
            reporter,
            label,
        );
    }

    let mut urls = Vec::with_capacity(fallback_urls.len() + 1);
    urls.push(primary_url);
    urls.extend(
        fallback_urls
            .iter()
            .map(String::as_str)
            .filter(|fallback| *fallback != primary_url),
    );
    let mut errors = Vec::new();
    for (index, url) in urls.iter().enumerate() {
        if index > 0 {
            emit_progress(
                reporter,
                format!(
                    "{label} CDN unavailable; trying alternate {}/{}",
                    index,
                    urls.len() - 1
                ),
                progress_start,
            );
        }
        match download_with_retries(
            client,
            url,
            headers,
            path,
            reuse_completed_file,
            retries,
            progress_start,
            progress_end,
            reporter,
            label,
        ) {
            Ok(()) => return Ok(()),
            Err(error) => errors.push(error.to_string()),
        }
    }

    bail!(
        "All {} candidate CDN URLs failed: {}",
        urls.len(),
        errors.join("; ")
    )
}

pub(super) fn safe_media_url_label(raw_url: &str) -> String {
    Url::parse(raw_url)
        .map(|url| {
            format!(
                "{}://{}{}",
                url.scheme(),
                url.host_str().unwrap_or_default(),
                url.path()
            )
        })
        .unwrap_or_else(|_| "media URL".to_string())
}
