//! Fixed-size, independently resumable ranges. Each worker owns one file and
//! one 64 KiB HTTP buffer; the completed object is assembled only after joining.
use super::*;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

pub(super) const RANGE_CHUNK: u64 = 4 * 1024 * 1024;

#[cfg(test)]
#[path = "parallel_tests.rs"]
mod tests;

/// Reuse the contiguous validated prefix when a CDN rejects parallel ranges.
/// Every worker is joined by the caller before this transition.
pub(super) fn prepare_sequential_fallback(
    path: &Path,
    url: &str,
    headers: &[(String, String)],
) -> Result<bool> {
    let partial = resumable_partial_path(path, url, headers);
    let directory = partial.with_extension("ranges");
    let Some(metadata) = read_resumable_metadata(&directory.join("entity")) else {
        return Ok(false);
    };
    let Some(total) = metadata.total_length else {
        return Ok(false);
    };
    if partial.exists() {
        return Ok(true);
    }
    let staged = directory.join("sequential-prefix");
    let mut output = std::fs::File::create(&staged)?;
    for start in (0..total).step_by(RANGE_CHUNK as usize) {
        let end = (start + RANGE_CHUNK).min(total) - 1;
        let chunk = directory.join(format!("{start}-{end}.chunk"));
        if super::super::hls::is_valid_hls_segment_cache(&chunk, &format!("range-v1:{start}:{end}"))
        {
            std::io::copy(&mut std::fs::File::open(chunk)?, &mut output)?;
        } else {
            let chunk = chunk.with_extension("part");
            if let Ok(input) = std::fs::File::open(chunk) {
                use std::io::Read;
                let mut prefix = input.take(end - start);
                std::io::copy(&mut prefix, &mut output)?;
            }
            break;
        }
    }
    output.sync_all()?;
    drop(output);
    write_resumable_metadata(&partial, &metadata)?;
    replace_download_output(&staged, &partial)?;
    Ok(true)
}

pub(super) fn validate_media_headers(headers: &[(String, String)]) -> Result<()> {
    if response_header(headers, "content-encoding")
        .is_some_and(|value| !value.eq_ignore_ascii_case("identity"))
    {
        bail!("Media response must use identity content encoding");
    }
    if response_header(headers, "content-type").is_some_and(|value| {
        let value = value.to_ascii_lowercase();
        value.starts_with("text/html")
            || value.starts_with("application/json")
            || value.starts_with("text/json")
    }) {
        bail!("Media request returned non-media content type");
    }
    Ok(())
}

/// A one-byte GET establishes actual Range support (Accept-Ranges is only a
/// hint). Nothing is reused until the response and its body have been checked.
pub(super) fn probe_range_metadata(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
) -> Result<Option<ResumableMetadata>> {
    read_probe_response(client.stream_range(url, headers, 0, 0)?)
}

fn read_probe_response(
    mut response: crate::net::HttpResponse,
) -> Result<Option<ResumableMetadata>> {
    if response.status == 200 {
        return Ok(None);
    }
    if response.status != 206 {
        bail!("Media range probe returned HTTP {}", response.status)
    }
    validate_media_headers(&response.headers)?;
    let range = parse_content_range(&response.headers)?;
    if range.start != Some(0)
        || range.end != Some(0)
        || response_header(&response.headers, "content-length").is_some_and(|value| value != "1")
    {
        bail!("Media range probe did not return exactly byte zero")
    }
    let mut received = 0;
    while let Some(chunk) = response.body.next_chunk()? {
        received += chunk.len();
        if received > 1 {
            bail!("Media range probe body exceeded one byte")
        }
    }
    if received != 1 {
        bail!("Media range probe was truncated")
    }
    let metadata = resumable_metadata_from_response(&response.headers, range.total);
    Ok(Some(metadata))
}

#[allow(clippy::too_many_arguments)]
fn download_range(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
    directory: &Path,
    metadata: &ResumableMetadata,
    start: u64,
    end: u64,
    transferred: &AtomicU64,
    progress: &dyn Fn(u64),
) -> Result<()> {
    let length = end - start + 1;
    let path = directory.join(format!("{start}-{end}.chunk"));
    let partial = path.with_extension("part");
    let cache_key = format!("range-v1:{start}:{end}");
    if super::super::hls::is_valid_hls_segment_cache(&path, &cache_key) {
        return Ok(());
    }
    let _ = std::fs::remove_file(&path);
    let mut saved = std::fs::metadata(&partial).map(|m| m.len()).unwrap_or(0);
    if saved >= length {
        saved = length - 1;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&partial)?;
    file.set_len(saved)?;
    use std::io::{Seek, SeekFrom};
    file.seek(SeekFrom::Start(saved))?;
    let mut range_headers = headers.to_vec();
    range_headers.retain(|(name, _)| !name.eq_ignore_ascii_case("if-range"));
    range_headers.push((
        "If-Range".into(),
        metadata
            .if_range_value()
            .context("Range has no validator")?
            .into(),
    ));
    let mut response = client.stream_range(url, &range_headers, start + saved, end)?;
    if response.status != 206 {
        bail!(
            "Parallel media request returned HTTP {}; expected 206",
            response.status
        );
    }
    validate_media_headers(&response.headers)?;
    let range = parse_content_range(&response.headers)?;
    if range.start != Some(start + saved)
        || range.end != Some(end)
        || range.total != metadata.total_length
        || !resumable_metadata_matches_response(metadata, &response.headers, range.total)
        || response_header(&response.headers, "content-length")
            .is_some_and(|value| value.parse::<u64>().ok() != Some(length - saved))
    {
        bail!("Parallel media range identity, bounds or length changed")
    }
    let mut received = saved;
    while let Some(chunk) = response.body.next_chunk()? {
        let next = received
            .checked_add(chunk.len() as u64)
            .context("Range length overflow")?;
        if next > length {
            file.set_len(saved)?;
            bail!("Parallel media response exceeded its declared length");
        }
        file.write_all(&chunk)?;
        received = next;
        let actual =
            transferred.fetch_add(chunk.len() as u64, Ordering::Relaxed) + chunk.len() as u64;
        progress(actual);
    }
    file.sync_data()?;
    if received != length {
        bail!("Parallel media response was truncated")
    }
    drop(file);
    let digest = super::super::hls::hash_file(&partial)?;
    let receipt = super::super::hls::hls_segment_metadata_path(&path);
    let temporary_receipt = receipt.with_extension("meta.tmp");
    let mut file = std::fs::File::create(&temporary_receipt)?;
    writeln!(file, "{cache_key}\n{length}\n{digest}")?;
    file.sync_all()?;
    drop(file);
    let _ = std::fs::remove_file(&receipt);
    replace_download_output(&partial, &path)?;
    replace_download_output(&temporary_receipt, &receipt)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn try_parallel_transfer(
    client: &SyncHttpClient,
    url: &str,
    headers: &[(String, String)],
    path: &Path,
    concurrency: usize,
    progress_start: f64,
    progress_end: f64,
    reporter: &ProgressReporter,
    label: &str,
) -> Result<bool> {
    if concurrency < 2 {
        return Ok(false);
    }
    let partial = resumable_partial_path(path, url, headers);
    if std::fs::metadata(&partial).is_ok_and(|m| m.len() > 0) {
        return Ok(false);
    }
    let response = client.stream_range(url, headers, 0, 0)?;
    if response.status == 200 {
        stream_media_with_initial_response(
            client,
            url,
            headers,
            path,
            progress_start,
            progress_end,
            reporter,
            label,
            Some(response),
        )?;
        return Ok(true);
    }
    let Some(metadata) = read_probe_response(response)? else {
        return Ok(false);
    };
    let Some(total) = metadata.total_length.filter(|n| *n >= RANGE_CHUNK * 2) else {
        return Ok(false);
    };
    if metadata.etag.is_none() {
        return Ok(false);
    }
    let directory = partial.with_extension("ranges");
    let manifest = directory.join("entity");
    if read_resumable_metadata(&manifest).as_ref() != Some(&metadata) {
        if directory.exists() {
            std::fs::remove_dir_all(&directory)?;
        }
        std::fs::create_dir_all(&directory)?;
        write_resumable_metadata(&manifest, &metadata)?;
    }
    let count = total.div_ceil(RANGE_CHUNK);
    let next = AtomicU64::new(0);
    let transferred = AtomicU64::new(0);
    let completed = AtomicU64::new(0);
    let error = Mutex::new(None);
    let clock = Instant::now();
    let last_reported = Mutex::new(Instant::now());
    let report = |actual: u64| {
        let mut last = last_reported.lock().unwrap_or_else(|e| e.into_inner());
        if last.elapsed().as_millis() < 250 {
            return;
        }
        *last = Instant::now();
        let speed = (actual as f64 / clock.elapsed().as_secs_f64().max(0.001)) as u64;
        let fraction = completed.load(Ordering::Relaxed) as f64 / total as f64;
        emit_progress(
            reporter,
            format!(
                "{label} [{} received, {}/s]",
                human_bytes(actual),
                human_bytes(speed)
            ),
            progress_start + fraction.min(1.0) * (progress_end - progress_start),
        );
    };
    std::thread::scope(|scope| {
        for _ in 0..concurrency.min(count as usize) {
            let control = crate::download_control::current();
            let (metadata, directory, next, error, transferred, completed, report) = (
                &metadata,
                &directory,
                &next,
                &error,
                &transferred,
                &completed,
                &report,
            );
            scope.spawn(move || {
                let _scope = crate::download_control::enter(control);
                loop {
                    if error.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
                        break;
                    }
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    if index >= count {
                        break;
                    }
                    let start = index * RANGE_CHUNK;
                    let end = (start + RANGE_CHUNK).min(total) - 1;
                    match download_range(
                        client,
                        url,
                        headers,
                        directory,
                        metadata,
                        start,
                        end,
                        transferred,
                        report,
                    ) {
                        Ok(()) => {
                            completed.fetch_add(end - start + 1, Ordering::Relaxed);
                        }
                        Err(failure) => {
                            let mut slot = error.lock().unwrap_or_else(|e| e.into_inner());
                            if slot.is_none() {
                                *slot = Some(failure);
                            }
                            break;
                        }
                    }
                }
            });
        }
    });
    if let Some(error) = error.into_inner().unwrap_or_else(|e| e.into_inner()) {
        return Err(error);
    }
    let assembly = directory.join("assembled");
    let mut output = std::fs::File::create(&assembly)?;
    for index in 0..count {
        crate::download_control::checkpoint()?;
        let start = index * RANGE_CHUNK;
        let end = (start + RANGE_CHUNK).min(total) - 1;
        let mut input = std::fs::File::open(directory.join(format!("{start}-{end}.chunk")))?;
        if std::io::copy(&mut input, &mut output)? != end - start + 1 {
            bail!("Cached range length changed")
        }
    }
    output.sync_all()?;
    drop(output);
    // Metadata precedes the rename: before that boundary the partial is absent.
    write_resumable_metadata(&partial, &metadata)?;
    replace_download_output(&assembly, &partial)?;
    finish_media_partial(&partial, path)?;
    let _ = std::fs::remove_dir_all(&directory);
    emit_progress(
        reporter,
        format!("{label} [{}]", human_bytes(total)),
        progress_end,
    );
    Ok(true)
}
