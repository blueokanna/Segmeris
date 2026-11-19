//! Disk-backed HLS downloads: neither media objects nor decrypted segments
//! need to fit in memory. The .part and its hash receipt appear only on success.
use super::*;
#[cfg(test)]
#[path = "hls_stream_tests.rs"]
mod tests;

fn stream_resource(
    client: &SyncHttpClient,
    request: &HlsResourceRequest,
    headers: &[(String, String)],
    output: &mut std::fs::File,
) -> Result<()> {
    let mut response = match request.byte_range {
        Some((start, end)) => client.stream_range(&request.url, headers, start, end)?,
        None => client.stream(&request.url, headers)?,
    };
    if !matches!(response.status, 200 | 206) {
        let status = response.status;
        let error_body = response.body.collect_limited(16 * 1024).unwrap_or_default();
        return Err(hls_http_error(status, &error_body));
    }
    if response_header(&response.headers, "content-encoding")
        .is_some_and(|v| !v.eq_ignore_ascii_case("identity"))
    {
        bail!("HLS response must use identity content encoding");
    }
    if response_header(&response.headers, "content-type").is_some_and(|v| {
        let v = v.to_ascii_lowercase();
        v.starts_with("text/html")
            || v.starts_with("application/json")
            || v.starts_with("text/json")
    }) {
        bail!("HLS request returned non-media content")
    }
    let declared = response_header(&response.headers, "content-length")
        .map(str::parse::<u64>)
        .transpose()
        .context("Invalid HLS Content-Length")?;
    let expected_range = request
        .byte_range
        .map(|(start, end)| {
            end.checked_sub(start)
                .and_then(|n| n.checked_add(1))
                .context("Invalid HLS range")
        })
        .transpose()?;
    if response.status == 206 {
        let (start, end) = request
            .byte_range
            .context("Unsolicited partial HLS response")?;
        let range = parse_content_range(&response.headers)?;
        if range.start != Some(start)
            || range.end != Some(end)
            || declared.zip(expected_range).is_some_and(|(a, b)| a != b)
        {
            bail!("HLS Content-Range does not match requested bytes")
        }
    }
    let slice = if response.status == 200 {
        request.byte_range
    } else {
        None
    };
    if let Some((_, end)) = slice
        && declared.is_some_and(|length| length <= end)
    {
        bail!("Full HLS response is shorter than the requested range")
    }
    let expected_body = if response.status == 206 {
        expected_range
    } else {
        declared
    };
    let mut received = 0u64;
    let mut written = 0u64;
    while let Some(bytes) = response.body.next_chunk()? {
        let next = received
            .checked_add(bytes.len() as u64)
            .context("HLS body length overflow")?;
        if expected_body.is_some_and(|length| next > length) {
            bail!("HLS response exceeded its declared length")
        }
        let data = if let Some((start, end)) = slice {
            let left = start.saturating_sub(received).min(bytes.len() as u64) as usize;
            let right = (end + 1).saturating_sub(received).min(bytes.len() as u64) as usize;
            &bytes[left.min(right)..right]
        } else {
            &bytes
        };
        output.write_all(data)?;
        written += data.len() as u64;
        received = next;
        if slice.is_some() && Some(written) == expected_range {
            break;
        }
    }
    if written == 0
        || expected_range.is_some_and(|length| written != length)
        || (slice.is_none() && expected_body.is_some_and(|length| received != length))
    {
        bail!("HLS response length mismatch")
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn download_segment_to_cache(
    client: &SyncHttpClient,
    headers: &[(String, String)],
    request: &HlsResourceRequest,
    init: Option<&[u8]>,
    crypto: Option<&(Vec<u8>, Vec<u8>)>,
    retries: u8,
    path: &Path,
    cache_key: &str,
) -> Result<()> {
    let token = Uuid::new_v4().simple().to_string();
    let staged = path.with_extension(format!("tmp-{token}"));
    let encrypted = path.with_extension(format!("encrypted.tmp-{token}"));
    let receipt = hls_segment_metadata_path(path);
    let staged_receipt = receipt.with_extension(format!("meta.tmp-{token}"));
    let result = (|| {
        let mut last_error = None;
        for attempt in 1..=retries.max(1) {
            let attempt_result: Result<()> = (|| {
                let mut output = std::fs::File::create(&staged)?;
                if let Some(init) = init {
                    output.write_all(init)?;
                }
                if let Some((key, iv)) = crypto {
                    let mut ciphertext = std::fs::File::create(&encrypted)?;
                    stream_resource(client, request, headers, &mut ciphertext)?;
                    drop(ciphertext);
                    crate::crypto::aes_cbc::aes_128_cbc_decrypt_stream(
                        key,
                        iv,
                        std::fs::File::open(&encrypted)?,
                        &mut output,
                    )?;
                } else {
                    stream_resource(client, request, headers, &mut output)?;
                }
                output.sync_all()?;
                drop(output);
                let length = std::fs::metadata(&staged)?.len();
                let digest = hash_file(&staged)?;
                let mut metadata = std::fs::File::create(&staged_receipt)?;
                writeln!(metadata, "{cache_key}\n{length}\n{digest}")?;
                metadata.sync_all()?;
                drop(metadata);
                // Remove the previous receipt before publishing new bytes.
                let _ = std::fs::remove_file(&receipt);
                replace_download_output(&staged, path)?;
                replace_download_output(&staged_receipt, &receipt)?;
                Ok(())
            })();
            match attempt_result {
                Ok(()) => return Ok(()),
                Err(error) => {
                    if error
                        .downcast_ref::<HlsHttpError>()
                        .is_some_and(HlsHttpError::is_permanent)
                    {
                        return Err(error);
                    }
                    last_error = Some(error);
                    if attempt < retries.max(1) {
                        std::thread::sleep(retry_backoff_delay(attempt, None));
                    }
                }
            }
        }
        Err(last_error.expect("at least one segment attempt"))
    })();
    let _ = std::fs::remove_file(staged);
    let _ = std::fs::remove_file(encrypted);
    let _ = std::fs::remove_file(staged_receipt);
    result.with_context(|| {
        format!(
            "Failed to download HLS segment: {}",
            safe_media_url_label(&request.url)
        )
    })
}
