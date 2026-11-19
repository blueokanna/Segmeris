//! Streaming media transfers, validator-based resumption and CDN fallback.
use super::{ProgressReporter, emit_progress, retry_backoff_delay};
use crate::crypto::Sha256;
use crate::net::SyncHttpClient;
use anyhow::{Context, Result, anyhow, bail};
use log::warn;
use std::io::Write;
use std::path::{Path, PathBuf};
use url::Url;
use uuid::Uuid;

#[path = "parallel.rs"]
mod parallel;

/// Bilibili signatures expire, but a representation's object path is stable.
/// Only recognized authorization fields are discarded; arbitrary query fields
/// (which may select different content) and non-Bilibili URLs retain identity.
pub(super) fn media_resume_identity(raw: &str) -> String {
    let Ok(mut url) = Url::parse(raw) else {
        return raw.to_string();
    };
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    if !(host.ends_with(".bilivideo.com") || host.ends_with(".bilivideo.cn"))
        || !url.path().starts_with("/upgcxcode/")
    {
        return raw.to_string();
    }
    let mut query: Vec<(String, String)> = url
        .query_pairs()
        .filter(|(name, _)| {
            !matches!(
                name.to_ascii_lowercase().as_str(),
                "deadline"
                    | "upsig"
                    | "wssecret"
                    | "wstime"
                    | "token"
                    | "expires"
                    | "sign"
                    | "auth_key"
                    | "uipk"
                    | "oi"
                    | "gen"
                    | "trid"
                    | "traceid"
                    | "uparams"
            )
        })
        .map(|(name, value)| (name.into_owned(), value.into_owned()))
        .collect();
    query.sort();
    let _ = url.set_host(Some("media.bilivideo.com"));
    url.set_fragment(None);
    url.set_query(None);
    if !query.is_empty() {
        url.query_pairs_mut().extend_pairs(query);
    }
    url.to_string()
}

fn completed_receipt(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".completed");
    path.with_file_name(name)
}

fn finish_media_partial(partial: &Path, path: &Path) -> Result<()> {
    let metadata = read_resumable_metadata(partial);
    let digest = super::hls::hash_file(partial)?;
    replace_download_output(partial, path)?;
    if let Some(metadata) = metadata {
        let receipt = completed_receipt(path);
        write_resumable_metadata(&receipt, &metadata)?;
        let temporary = receipt.with_extension("completed.tmp");
        let mut file = std::fs::File::create(&temporary)?;
        writeln!(
            file,
            "{}\n{}",
            partial.file_name().unwrap_or_default().to_string_lossy(),
            digest
        )?;
        file.sync_all()?;
        drop(file);
        replace_download_output(&temporary, &receipt)?;
    }
    let _ = std::fs::remove_file(resumable_metadata_path(partial));
    Ok(())
}

fn completed_media_is_valid(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
    path: &Path,
) -> Result<bool> {
    let receipt = completed_receipt(path);
    let Ok(contents) = std::fs::read_to_string(&receipt) else {
        return Ok(false);
    };
    let mut lines = contents.lines();
    let partial = resumable_partial_path(path, url, headers);
    if lines.next() != partial.file_name().and_then(|name| name.to_str()) {
        return Ok(false);
    }
    let Some(expected_hash) = lines.next() else {
        return Ok(false);
    };
    let Some(saved) =
        read_resumable_metadata(&receipt).filter(ResumableMetadata::has_resume_validator)
    else {
        return Ok(false);
    };
    if !std::fs::metadata(path)
        .is_ok_and(|m| m.is_file() && m.len() > 0 && Some(m.len()) == saved.total_length)
        || super::hls::hash_file(path)? != expected_hash
    {
        return Ok(false);
    }
    let Some(current) = parallel::probe_range_metadata(client, url, headers)? else {
        return Ok(false);
    };
    Ok(saved == current)
}

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
        && saved_etag != response_etag
    {
        return false;
    }
    if let (Some(saved_last_modified), Some(response_last_modified)) = (
        saved.last_modified.as_deref(),
        response_header(headers, "last-modified"),
    ) && saved_last_modified != response_last_modified
    {
        return false;
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
        replace_download_output(&temporary_path, &metadata_path)?;
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
    stream_media_with_initial_response(
        client,
        url,
        headers,
        path,
        progress_start,
        progress_end,
        reporter,
        label,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn stream_media_with_initial_response(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
    path: &Path,
    progress_start: f64,
    progress_end: f64,
    reporter: &ProgressReporter,
    label: &str,
    mut initial_response: Option<crate::net::HttpResponse>,
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
    if let Some(total) = resume_metadata.as_ref().and_then(|m| m.total_length) {
        if downloaded > total {
            clear_resumable_partial(&partial_path)?;
            downloaded = 0;
            resume_metadata = None;
        } else if downloaded == total && downloaded > 0 {
            downloaded -= 1;
            std::fs::OpenOptions::new()
                .write(true)
                .open(&partial_path)?
                .set_len(downloaded)?;
        }
    }
    let clock = std::time::Instant::now();
    let mut transferred = 0u64;
    let mut last_report = clock;
    let mut last_reported = downloaded;
    let mut use_range = true;
    emit_progress(reporter, label, progress_start);

    loop {
        let start = downloaded;
        let end = start.saturating_add(CHUNK - 1);
        let mut range_headers = headers.to_vec();
        if start > 0
            && let Some(if_range) = resume_metadata
                .as_ref()
                .and_then(ResumableMetadata::if_range_value)
        {
            range_headers.retain(|(name, _)| !name.eq_ignore_ascii_case("if-range"));
            range_headers.push(("If-Range".to_string(), if_range.to_string()));
        }
        let response = if let Some(response) = initial_response.take() {
            response
        } else if use_range {
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
            && (content_type.starts_with("text/html")
                || content_type.starts_with("application/json")
                || content_type.starts_with("text/json"))
        {
            bail!(
                "Media request returned non-media content type {}",
                content_type
            );
        }

        if status == 416 {
            let range = parse_content_range(&response_headers)?;
            let validators_match = resume_metadata.as_ref().is_none_or(|saved| {
                resumable_metadata_matches_response(saved, &response_headers, range.total)
            });
            if is_complete_unsatisfied_range(range, downloaded) && validators_match {
                finish_media_partial(&partial_path, path)?;
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
        if !matches!(status, 200 | 206) {
            bail!("Media request returned HTTP {}", status);
        }
        if status == 206 && !use_range {
            bail!("Server returned an unrequested partial response");
        }

        let (total, expected_length) = if status == 206 {
            let range = parse_content_range(&response_headers)?;
            if range.start != Some(start) {
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
                .and_then(|length| length.checked_add(1))
                .context("Media Range response length overflow")?;
            if range_end > end {
                bail!("Media Range response exceeded the requested end offset");
            }
            if response_header(&response_headers, "content-length")
                .is_some_and(|value| value.parse::<u64>().ok() != Some(range_length))
            {
                bail!("Media Content-Length disagrees with Content-Range");
            }
            (range.total, Some(range_length))
        } else {
            downloaded = 0;
            last_reported = 0;
            let length = response_header(&response_headers, "content-length")
                .map(str::parse::<u64>)
                .transpose()
                .context("Invalid media Content-Length")?;
            (length, length)
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
                expected_length.context("Partial response has no length")?,
            )
        {
            clear_resumable_partial(&partial_path)?;
            use_range = false;
            downloaded = 0;
            resume_metadata = None;
            continue;
        }
        if status == 200 {
            clear_resumable_partial(&partial_path)?;
        }
        let mut output = if status == 200 {
            std::fs::File::create(&partial_path)
        } else {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&partial_path)
        }
        .with_context(|| format!("Failed to create media file: {}", partial_path.display()))?;
        write_resumable_metadata(&partial_path, &next_metadata)?;
        resume_metadata = Some(next_metadata);
        let mut received = 0u64;
        while let Some(chunk) = body.next_chunk()? {
            let next_received = received
                .checked_add(chunk.len() as u64)
                .context("Media response length overflow")?;
            if expected_length.is_some_and(|length| next_received > length) {
                drop(output);
                if downloaded == 0 {
                    clear_resumable_partial(&partial_path)?;
                } else {
                    let rollback = std::fs::OpenOptions::new()
                        .write(true)
                        .open(&partial_path)?;
                    rollback.set_len(downloaded)?;
                    rollback.sync_data()?;
                }
                bail!("Media response exceeded its declared length");
            }
            output.write_all(&chunk)?;
            transferred += chunk.len() as u64;
            received = next_received;
            let count = downloaded
                .checked_add(received)
                .context("Media download length overflow")?;
            if last_report.elapsed().as_millis() >= 250 {
                let progress = total
                    .filter(|n| *n > 0)
                    .map(|n| {
                        progress_start
                            + (count as f64 / n as f64).min(1.0) * (progress_end - progress_start)
                    })
                    .unwrap_or(progress_start);
                emit_progress(
                    reporter,
                    format!(
                        "{} [{}, {}/s]",
                        label,
                        human_bytes(count),
                        human_bytes(
                            (transferred as f64 / clock.elapsed().as_secs_f64().max(0.001)) as u64
                        )
                    ),
                    progress,
                );
                last_report = std::time::Instant::now();
                last_reported = count;
            }
        }
        if received == 0 {
            bail!("Media response was empty");
        }
        if expected_length.is_some_and(|length| received != length) {
            output.sync_data()?;
            bail!("Media response length mismatch");
        }
        output.flush()?;
        output.sync_data()?;
        drop(output);
        downloaded = downloaded
            .checked_add(received)
            .context("Media download length overflow")?;

        if total.is_some_and(|total| downloaded > total) {
            bail!("Media response exceeded its declared total length");
        }
        if total.is_some_and(|total| downloaded == total) {
            finish_media_partial(&partial_path, path)?;
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
            finish_media_partial(&partial_path, path)?;
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
    let identity_url = media_resume_identity(url);
    for value in std::iter::once(identity_url.as_str()).chain(
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
    // std::fs::rename replaces an existing regular file on Unix and Windows.
    // Keeping this a single operation avoids a missing destination if the
    // process exits between moving an old file away and publishing the new one.
    std::fs::rename(partial_path, output_path)
        .with_context(|| format!("Failed to finalize media output: {}", output_path.display()))?;
    #[cfg(unix)]
    if let Some(parent) = output_path.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn download_with_retries(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
    path: &Path,
    reuse_completed_file: bool,
    concurrency: usize,
    retries: u8,
    progress_start: f64,
    progress_end: f64,
    reporter: &ProgressReporter,
    label: &str,
) -> Result<()> {
    let mut parallelism = concurrency;
    for attempt in 1..=retries.max(1) {
        let result = (|| {
            if reuse_completed_file && completed_media_is_valid(client, url, headers, path)? {
                emit_progress(
                    reporter,
                    format!("{label} [verified cached file]"),
                    progress_end,
                );
                return Ok(());
            }
            match parallel::try_parallel_transfer(
                client,
                url,
                headers,
                path,
                parallelism,
                progress_start,
                progress_end,
                reporter,
                label,
            ) {
                Ok(true) => return Ok(()),
                Ok(false) => {}
                Err(error) => {
                    if !parallel::prepare_sequential_fallback(path, url, headers)? {
                        return Err(error);
                    }
                    parallelism = 1;
                    emit_progress(
                        reporter,
                        format!("{label} [retrying with one connection]"),
                        progress_start,
                    );
                }
            }
            stream_media_response_to_file(
                client,
                url,
                headers,
                path,
                progress_start,
                progress_end,
                reporter,
                label,
            )
        })();
        match result {
            Ok(()) => return Ok(()),
            Err(error) => {
                if attempt == retries.max(1) {
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
    concurrency: usize,
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
            concurrency,
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
            concurrency,
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
