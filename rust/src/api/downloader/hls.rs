//! HLS resource planning, decryption, cache verification and segment assembly.
use super::*;

#[derive(Debug)]
pub(super) struct HlsHttpError {
    status: u16,
    missing_object: bool,
}

impl HlsHttpError {
    fn is_permanent(&self) -> bool {
        (400..500).contains(&self.status) && !matches!(self.status, 408 | 429)
    }
}

impl std::fmt::Display for HlsHttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "HTTP {}", self.status)?;
        match self.status {
            404 if self.missing_object => write!(f, ": NoSuchKey; the origin reports that this object does not exist. Obtain a current media URL from the source page"),
            404 | 410 => write!(f, ": resource not found. Check the URL or obtain a current link from the source page"),
            401 | 403 => write!(f, ": the server refused access. Check the session, permissions and link validity"),
            _ => Ok(()),
        }
    }
}

impl std::error::Error for HlsHttpError {}

pub(super) fn hls_http_error(status: u16, body: &[u8]) -> anyhow::Error {
    let missing_object = status == 404
        && body.len() <= 16 * 1024
        && crate::xml::parse_xml(body).is_ok_and(|root| {
            root.name == "Error"
                && root
                    .child("Code")
                    .is_some_and(|code| code.text.trim() == "NoSuchKey")
        });
    HlsHttpError {
        status,
        missing_object,
    }
    .into()
}

struct HlsInitialization {
    bytes: Vec<u8>,
    digest: String,
}

#[derive(Clone, Debug)]
pub(super) struct SegmentInput {
    pub(super) dir: PathBuf,
    pub(super) prefix: String,
    pub(super) total: usize,
}

/// Every downloaded part is independently readable, including its cached MAP.
pub(super) fn segment_input_for(
    segments: &[crate::hls::MediaSegment],
    dir: &Path,
    prefix: &str,
    total: usize,
) -> Option<SegmentInput> {
    Some(SegmentInput {
        dir: dir.to_path_buf(),
        prefix: prefix.to_string(),
        total,
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn download_and_merge(
    playlist: MediaPlaylist,
    base_url: Option<Url>,
    concurrency: usize,
    retries: u8,
    output_file: &str,
    temp_dir: &Path,
    segment_prefix: &str,
    multi_progress: &MultiProgress,
    reporter: ProgressReporter,
    request_context: RequestContext,
) -> Result<()> {
    if concurrency > 1 {
        match download_and_merge_once(
            playlist.clone(),
            base_url.clone(),
            concurrency,
            retries,
            output_file,
            temp_dir,
            segment_prefix,
            multi_progress,
            reporter.clone(),
            request_context.clone(),
        ) {
            Ok(()) => return Ok(()),
            Err(error)
                if error
                    .downcast_ref::<HlsHttpError>()
                    .is_some_and(HlsHttpError::is_permanent) =>
            {
                return Err(error)
            }
            Err(error) => {
                warn!(
                    "Multi-thread segment download failed with concurrency {}. Retrying single-threaded: {}",
                    concurrency, error
                );
                // Validated cached segments remain reusable after a worker failure.
                emit_progress(
                    &reporter,
                    "Multi-thread download failed. Retrying in single-thread mode...",
                    0.12,
                );
            }
        }
    }

    download_and_merge_once(
        playlist,
        base_url,
        1,
        retries,
        output_file,
        temp_dir,
        segment_prefix,
        multi_progress,
        reporter,
        request_context,
    )
}

#[derive(Clone, Debug)]
pub(super) struct HlsResourceRequest {
    pub(super) url: String,
    pub(super) byte_range: Option<(u64, u64)>,
}

pub(super) fn resolve_hls_byte_range(
    uri: &str,
    byte_range: Option<&ByteRange>,
    cursor: &mut Option<(String, u64)>,
) -> Result<Option<(u64, u64)>> {
    let Some(byte_range) = byte_range else {
        *cursor = None;
        return Ok(None);
    };
    if byte_range.length == 0 {
        bail!("HLS byte range length must be greater than zero");
    }

    let start = match byte_range.offset {
        Some(offset) => offset,
        None => cursor
            .as_ref()
            .filter(|(previous_uri, _)| previous_uri == uri)
            .map(|(_, next_offset)| *next_offset)
            .ok_or_else(|| {
                anyhow!(
                    "HLS byte range for {} omitted its offset without a compatible previous range",
                    uri
                )
            })?,
    };
    let end_exclusive = start
        .checked_add(byte_range.length)
        .ok_or_else(|| anyhow!("HLS byte range overflow for {}", uri))?;
    *cursor = Some((uri.to_string(), end_exclusive));
    Ok(Some((start, end_exclusive - 1)))
}

pub(super) fn hls_response_bytes(
    status: u16,
    headers: &[(String, String)],
    mut data: Vec<u8>,
    byte_range: Option<(u64, u64)>,
) -> Result<Vec<u8>> {
    if status != 200 && status != 206 {
        return Err(hls_http_error(status, &data));
    }
    let Some((start, end)) = byte_range else {
        if status == 206 {
            bail!("Unsolicited partial HLS response");
        }
        return Ok(data);
    };
    let expected_length = end
        .checked_sub(start)
        .and_then(|length| length.checked_add(1))
        .ok_or_else(|| anyhow!("Invalid HLS byte range {}-{}", start, end))?;
    let expected_length = usize::try_from(expected_length)
        .context("HLS byte range is too large for this platform")?;

    if status == 206 {
        let range = parse_content_range(headers).context("Invalid HLS range response")?;
        if range.start != Some(start) || range.end != Some(end) {
            bail!("HLS Content-Range does not match requested bytes {start}-{end}");
        }
        if data.len() != expected_length {
            bail!(
                "HLS range response length mismatch: expected {} bytes, received {}",
                expected_length,
                data.len()
            );
        }
        return Ok(data);
    }

    let start = usize::try_from(start).context("HLS byte range offset is too large")?;
    let end_exclusive = start
        .checked_add(expected_length)
        .ok_or_else(|| anyhow!("HLS byte range slice overflow"))?;
    if data.len() < end_exclusive {
        bail!(
            "Server ignored the HLS Range request and returned only {} bytes for range {}-{}",
            data.len(),
            start,
            end
        );
    }
    data.copy_within(start..end_exclusive, 0);
    data.truncate(expected_length);
    Ok(data)
}

pub(super) fn download_hls_resource(
    client: &SyncHttpClient,
    request: &HlsResourceRequest,
    headers: &[(String, String)],
    retries: u8,
) -> Result<Vec<u8>> {
    let retries = retries.max(1);
    let mut last_error = None;
    for attempt in 1..=retries {
        let result = match request.byte_range {
            Some((start, end)) => client.get_range(&request.url, headers, start, end),
            None => client.get(&request.url, headers),
        };

        let status = result.as_ref().ok().map(|(status, _, _)| *status);
        let result = result.and_then(|(status, response_headers, body)| {
            hls_response_bytes(status, &response_headers, body, request.byte_range)
        });
        let error = match result {
            Ok(data) => return Ok(data),
            Err(error) => {
                error.context(format!("Failed to download HLS resource: {}", request.url))
            }
        };
        if status.is_some_and(|status| (400..500).contains(&status) && !matches!(status, 408 | 429))
        {
            return Err(error);
        }
        warn!("HLS resource attempt {attempt}/{retries}: {error:#}");
        last_error = Some(error);
        if attempt < retries {
            let delay = retry_backoff_delay(attempt, status);
            std::thread::sleep(delay);
        }
    }
    Err(last_error.expect("at least one HLS request was attempted"))
        .with_context(|| format!("HLS resource failed after {retries} attempts"))
}

pub(super) fn decrypt_hls_resource(
    data: Vec<u8>,
    crypto: Option<&(Vec<u8>, Vec<u8>)>,
) -> Result<Vec<u8>> {
    let Some((key, iv)) = crypto else {
        return Ok(data);
    };
    if key.len() != 16 || iv.len() != 16 {
        bail!("AES-128 key and IV must contain exactly 16 bytes");
    }
    aes_128_cbc_decrypt(key, iv, &data).map_err(|e| anyhow!("AES-128-CBC decryption failed: {e}"))
}

/// Init bytes are fetched and validated once, independently of segment retries.
pub(super) fn download_and_decrypt_segment(
    client: &SyncHttpClient,
    headers: &[(String, String)],
    segment_request: &HlsResourceRequest,
    init: Option<&[u8]>,
    crypto: Option<&(Vec<u8>, Vec<u8>)>,
    retries: u8,
) -> Result<Vec<u8>> {
    let data = download_hls_resource(client, segment_request, headers, retries.max(1))?;
    let data = decrypt_hls_resource(data, crypto)?;
    let Some(init) = init.filter(|init| !init.is_empty()) else {
        return Ok(data);
    };
    let mut output = Vec::with_capacity(init.len() + data.len());
    output.extend_from_slice(init);
    output.extend_from_slice(&data);
    Ok(output)
}

pub(super) fn hls_segment_cache_key(
    media_sequence: u64,
    index: usize,
    request: &HlsResourceRequest,
    init_request: Option<&HlsResourceRequest>,
    crypto: Option<&(Vec<u8>, Vec<u8>)>,
    headers: &[(String, String)],
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"segmeris-hls-segment-v1");
    hasher.update(&media_sequence.to_be_bytes());
    hasher.update(&(index as u64).to_be_bytes());
    hash_hls_resource_request(&mut hasher, request);
    if let Some(init_request) = init_request {
        hasher.update(&[1]);
        hash_hls_resource_request(&mut hasher, init_request);
    } else {
        hasher.update(&[0]);
    }
    if let Some((key, iv)) = crypto {
        hasher.update(&[1]);
        hasher.update(&(key.len() as u64).to_be_bytes());
        hasher.update(key);
        hasher.update(iv);
    } else {
        hasher.update(&[0]);
    }
    for (name, value) in headers {
        hash_hls_field(&mut hasher, name.as_bytes());
        hash_hls_field(&mut hasher, value.as_bytes());
    }
    hex::encode(hasher.finalize())
}

pub(super) fn hash_hls_resource_request(hasher: &mut Sha256, request: &HlsResourceRequest) {
    hash_hls_field(hasher, request.url.as_bytes());
    if let Some((start, end)) = request.byte_range {
        hasher.update(&[1]);
        hasher.update(&start.to_be_bytes());
        hasher.update(&end.to_be_bytes());
    } else {
        hasher.update(&[0]);
    }
}

pub(super) fn hash_hls_field(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(&(value.len() as u64).to_be_bytes());
    hasher.update(value);
}

pub(super) fn hls_segment_metadata_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".meta");
    path.with_file_name(name)
}

pub(super) fn hash_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path)
        .with_context(|| format!("Failed to open cached segment: {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let length = file.read(&mut buffer)?;
        if length == 0 {
            break;
        }
        hasher.update(&buffer[..length]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub(super) fn is_valid_hls_segment_cache(path: &Path, cache_key: &str) -> bool {
    let metadata_path = hls_segment_metadata_path(path);
    let Ok(metadata) = std::fs::read_to_string(metadata_path) else {
        return false;
    };
    let mut lines = metadata.lines();
    if lines.next() != Some(cache_key) {
        return false;
    }
    let Some(expected_length) = lines.next().and_then(|value| value.parse::<u64>().ok()) else {
        return false;
    };
    let Some(expected_hash) = lines.next() else {
        return false;
    };
    std::fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.len() == expected_length)
        .unwrap_or(false)
        && hash_file(path)
            .map(|actual_hash| actual_hash == expected_hash)
            .unwrap_or(false)
}

pub(super) fn write_hls_segment_cache(path: &Path, data: &[u8], cache_key: &str) -> Result<()> {
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("segment.part");
    let token = Uuid::new_v4().simple().to_string();
    let temporary_path = path.with_file_name(format!("{}.tmp-{}", filename, token));
    let metadata_path = hls_segment_metadata_path(path);
    let metadata_temporary_path =
        metadata_path.with_file_name(format!("{}.tmp-{}", filename, token));

    let result = (|| -> Result<()> {
        let mut file = std::fs::File::create(&temporary_path)?;
        file.write_all(data)?;
        file.sync_all()?;
        drop(file);

        let _ = std::fs::remove_file(&metadata_path);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        std::fs::rename(&temporary_path, path)?;

        let metadata = format!(
            "{}\n{}\n{}\n",
            cache_key,
            data.len(),
            hex::encode(sha256(data))
        );
        let mut file = std::fs::File::create(&metadata_temporary_path)?;
        file.write_all(metadata.as_bytes())?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&metadata_temporary_path, &metadata_path)?;
        Ok(())
    })();

    if result.is_err() {
        let _ = std::fs::remove_file(temporary_path);
        let _ = std::fs::remove_file(metadata_temporary_path);
    }
    result.with_context(|| format!("Failed to persist HLS segment cache: {}", path.display()))
}

pub(super) fn report_hls_segment_completed(
    completed: &std::sync::atomic::AtomicU64,
    total: usize,
    progress_bar: &ProgressBar,
    reporter: &ProgressReporter,
    last_reported: &std::sync::atomic::AtomicU64,
) {
    let count = completed.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    progress_bar.set_position(count);

    let total_u64 = total as u64;
    let coarse = ((count as f64) / (total as f64) * 900.0) as u64;
    let is_final = count >= total_u64;
    let should_emit = is_final
        || coarse.saturating_sub(last_reported.load(std::sync::atomic::Ordering::Relaxed)) >= 9;
    if should_emit {
        last_reported.store(coarse, std::sync::atomic::Ordering::Relaxed);
        progress_bar.set_message(format!("Downloading segments [{}/{}]", count, total));
        emit_progress(
            reporter,
            format!("Downloading segments [{}/{}]", count, total),
            (count as f64) / (total as f64) * 0.9,
        );
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn resolve_hls_crypto(
    key_definition: Option<&crate::hls::Key>,
    base_url: &Option<Url>,
    key_client: &SyncHttpClient,
    headers: &[(String, String)],
    key_cache: &mut HashMap<String, Vec<u8>>,
    retries: u8,
    sequence: u64,
) -> Result<Option<(Vec<u8>, Vec<u8>)>> {
    let Some(key_definition) = key_definition else {
        return Ok(None);
    };
    match &key_definition.method {
        KeyMethod::None => {
            return Ok(None);
        }
        KeyMethod::AES128 => {}
        method => bail!("Unsupported HLS encryption method: {:?}", method),
    }
    if key_definition
        .keyformat
        .as_deref()
        .is_some_and(|format| !format.eq_ignore_ascii_case("identity"))
    {
        bail!(
            "Unsupported HLS AES-128 key format: {}",
            key_definition.keyformat.as_deref().unwrap_or_default()
        );
    }
    let key_uri = key_definition
        .uri
        .as_deref()
        .ok_or_else(|| anyhow!("AES-128 HLS key is missing its URI"))?;
    let key_url = if let Some(base) = &base_url {
        base.join(key_uri)?
    } else {
        Url::parse(key_uri)?
    };
    if !matches!(key_url.scheme(), "http" | "https") {
        bail!("Refusing non-HTTP(S) HLS key URL: {}", key_url.scheme());
    }
    let key_url_string = key_url.to_string();
    let key_bytes = if let Some(cached) = key_cache.get(&key_url_string) {
        cached.clone()
    } else {
        let bytes = download_hls_resource(
            key_client,
            &HlsResourceRequest {
                url: key_url_string.clone(),
                byte_range: None,
            },
            headers,
            retries,
        )?;
        if bytes.len() != 16 {
            bail!("AES-128 key must contain exactly 16 bytes");
        }
        key_cache.insert(key_url_string, bytes.clone());
        bytes
    };

    let iv_bytes = if let Some(iv_hex) = &key_definition.iv {
        let raw = iv_hex.trim_start_matches("0x");
        let padded = if raw.len() < 32 {
            format!("{:0>32}", raw)
        } else {
            raw.to_string()
        };
        let decoded = hex::decode(&padded).context("IV hex decode failed")?;
        if decoded.len() != 16 {
            bail!("AES-128 IV must contain exactly 16 bytes");
        }
        decoded
    } else {
        (sequence as u128).to_be_bytes().to_vec()
    };

    Ok(Some((key_bytes, iv_bytes)))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn download_and_merge_once(
    playlist: MediaPlaylist,
    base_url: Option<Url>,
    concurrency: usize,
    retries: u8,
    output_file: &str,
    temp_dir: &Path,
    segment_prefix: &str,
    multi_progress: &MultiProgress,
    reporter: ProgressReporter,
    request_context: RequestContext,
) -> Result<()> {
    if !temp_dir.exists() {
        std::fs::create_dir_all(temp_dir)
            .with_context(|| format!("Failed to create temp dir: {}", temp_dir.display()))?;
    }

    if !playlist.end_list {
        bail!("Live HLS has no EXT-X-ENDLIST; recording is not supported. Use a finalized VOD playlist.");
    }
    let media_sequence = playlist.media_sequence;
    let segments = playlist.segments;
    let total = segments.len();
    if total == 0 {
        bail!("MediaPlaylist contains no segments");
    }

    let discontinuities = segments
        .iter()
        .enumerate()
        .filter(|(_, segment)| segment.discontinuity)
        .map(|(i, _)| i.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(
        temp_dir.join(format!("{segment_prefix}.discontinuities")),
        discontinuities,
    )?;
    let segment_headers = match &base_url {
        Some(base) => request_headers(base, &request_context)?,
        None => Vec::new(),
    };
    let segment_headers_shared = Arc::new(segment_headers);

    let download_pb = multi_progress.add(ProgressBar::new(total as u64));
    download_pb.set_style(
        ProgressStyle::with_template(
            "{msg} [{elapsed_precise}] {bar:40.cyan/blue} {pos:>7}/{len:7} ({percent}%) {eta}",
        )?
        .progress_chars("##-"),
    );
    download_pb.set_message("Downloading segments");

    let key_client =
        create_http_client_for_context(base_url.as_ref().map(Url::as_str), &request_context)?;
    let mut key_cache = HashMap::<String, Vec<u8>>::new();
    let mut segment_crypto = Vec::with_capacity(total);
    for (index, segment) in segments.iter().enumerate() {
        let sequence = media_sequence
            .checked_add(index as u64)
            .context("HLS sequence overflow")?;
        segment_crypto.push(resolve_hls_crypto(
            segment.key.as_ref(),
            &base_url,
            &key_client,
            &segment_headers_shared,
            &mut key_cache,
            retries,
            sequence,
        )?);
    }

    let resolve_url = |uri: &str| -> Result<String> {
        let resolved = if let Some(base) = &base_url {
            base.join(uri)?
        } else {
            Url::parse(uri)?
        };
        if !matches!(resolved.scheme(), "http" | "https") {
            bail!(
                "Refusing non-HTTP(S) media resource URL: {}",
                resolved.scheme()
            );
        }
        Ok(resolved.to_string())
    };
    let mut segment_range_cursor = None;
    let mut map_range_cursor = None;
    let mut previous_map = None;
    let mut current_init = None;
    let mut init_cache: HashMap<String, Arc<HlsInitialization>> = HashMap::new();
    let mut init_bytes = Vec::with_capacity(total);
    let mut init_cache_size = 0usize;
    let mut segment_requests = Vec::with_capacity(total);
    let mut init_requests = Vec::with_capacity(total);

    for (index, segment) in segments.iter().enumerate() {
        segment_requests.push(HlsResourceRequest {
            url: resolve_url(&segment.uri)?,
            byte_range: resolve_hls_byte_range(
                &segment.uri,
                segment.byte_range.as_ref(),
                &mut segment_range_cursor,
            )?,
        });

        let map_changed = segment.map != previous_map;
        let init_request = if map_changed {
            match segment.map.as_ref() {
                Some(map) => {
                    if map
                        .key
                        .as_ref()
                        .is_some_and(|key| key.method == KeyMethod::AES128 && key.iv.is_none())
                    {
                        bail!("Encrypted EXT-X-MAP requires an explicit AES-128 IV");
                    }
                    Some(HlsResourceRequest {
                        url: resolve_url(&map.uri)?,
                        byte_range: resolve_hls_byte_range(
                            &map.uri,
                            map.byte_range.as_ref(),
                            &mut map_range_cursor,
                        )?,
                    })
                }
                None => {
                    map_range_cursor = None;
                    None
                }
            }
        } else {
            current_init.clone()
        };
        current_init = init_request.clone();
        let init = if let Some(request) = &init_request {
            let crypto = resolve_hls_crypto(
                segment.map.as_ref().and_then(|m| m.key.as_ref()),
                &base_url,
                &key_client,
                &segment_headers_shared,
                &mut key_cache,
                retries,
                0,
            )?;
            let cache_key = hls_segment_cache_key(
                0,
                0,
                request,
                None,
                crypto.as_ref(),
                &segment_headers_shared,
            );
            if let Some(data) = init_cache.get(&cache_key) {
                Some(data.clone())
            } else {
                let path = temp_dir.join(format!("init-{cache_key}.part"));
                let data = if is_valid_hls_segment_cache(&path, &cache_key) {
                    std::fs::read(&path)?
                } else {
                    let data = decrypt_hls_resource(
                        download_hls_resource(
                            &key_client,
                            request,
                            &segment_headers_shared,
                            retries.max(1),
                        )?,
                        crypto.as_ref(),
                    )?;
                    write_hls_segment_cache(&path, &data, &cache_key)?;
                    data
                };
                init_cache_size += data.len();
                if init_cache_size > crate::net::MAX_MEMORY_BODY {
                    bail!("HLS initialization sections exceed cache limit");
                }
                let data = Arc::new(HlsInitialization {
                    digest: hex::encode(sha256(&data)),
                    bytes: data,
                });
                init_cache.insert(cache_key, data.clone());
                Some(data)
            }
        } else {
            None
        };
        init_bytes.push(init);
        previous_map = segment.map.clone();
        init_requests.push(init_request);
    }

    let client = Arc::new(create_http_client_for_context(
        base_url.as_ref().map(Url::as_str),
        &request_context,
    )?);
    let completed = Arc::new(std::sync::atomic::AtomicU64::new(0));

    let temp_dir = temp_dir.to_path_buf();
    let next_index = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let worker_count = concurrency.min(total).max(1);
    let errors: Arc<Mutex<Option<anyhow::Error>>> = Arc::new(Mutex::new(None));
    let last_reported_pct = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let client_shared = client.clone();
    let completed_shared = completed.clone();
    let pb_shared = download_pb.clone();
    let reporter_shared = reporter.clone();
    let temp_dir_shared = temp_dir.clone();
    let next_shared = next_index.clone();
    let errors_shared = errors.clone();
    let last_reported_shared = last_reported_pct.clone();
    let segment_headers_shared = segment_headers_shared.clone();
    let segment_requests_shared = segment_requests;
    let init_requests_shared = init_requests;
    let segment_crypto_shared = segment_crypto;

    std::thread::scope(|scope| {
        for _ in 0..worker_count {
            let next = next_shared.clone();
            let errors = errors_shared.clone();
            let client = client_shared.clone();
            let completed = completed_shared.clone();
            let pb = pb_shared.clone();
            let reporter = reporter_shared.clone();
            let temp_dir = temp_dir_shared.clone();
            let last_reported = last_reported_shared.clone();
            let headers = segment_headers_shared.clone();
            let segment_requests = &segment_requests_shared;
            let init_requests = &init_requests_shared;
            let segment_crypto = &segment_crypto_shared;
            let init_bytes = &init_bytes;
            let control = crate::download_control::current();
            scope.spawn(move || {
                let _control_scope = crate::download_control::enter(control);
                loop {
                    // Stop early if a previous worker failed.
                    if errors.lock().unwrap().is_some() {
                        break;
                    }
                    let idx = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    if idx >= total {
                        break;
                    }

                    let result = (|| -> Result<()> {
                        let segment_request = segment_requests[idx].clone();
                        let init_request = init_requests[idx].clone();
                        let key = segment_crypto.get(idx).cloned().flatten();
                        let file_name = format!("{}_{:05}.part", segment_prefix, idx);
                        let tmp_path = temp_dir.join(file_name);
                        let resource_key = hls_segment_cache_key(
                            media_sequence,
                            idx,
                            &segment_request,
                            init_request.as_ref(),
                            key.as_ref(),
                            &headers,
                        );

                        let init_hash = init_bytes[idx]
                            .as_ref()
                            .map(|data| data.digest.as_str())
                            .unwrap_or_default();
                        let cache_key =
                            hex::encode(sha256(format!("{resource_key}:{init_hash}").as_bytes()));
                        if is_valid_hls_segment_cache(&tmp_path, &cache_key) {
                            report_hls_segment_completed(
                                &completed,
                                total,
                                &pb,
                                &reporter,
                                &last_reported,
                            );
                            return Ok(());
                        }

                        let buffer = download_and_decrypt_segment(
                            &client,
                            &headers,
                            &segment_request,
                            init_bytes[idx].as_ref().map(|data| data.bytes.as_slice()),
                            key.as_ref(),
                            retries,
                        )?;
                        write_hls_segment_cache(&tmp_path, &buffer, &cache_key)?;
                        report_hls_segment_completed(
                            &completed,
                            total,
                            &pb,
                            &reporter,
                            &last_reported,
                        );
                        Ok(())
                    })();

                    if let Err(error) = result {
                        let mut slot = errors.lock().unwrap();
                        if slot.is_none() {
                            *slot = Some(error);
                        }
                    }
                }
            });
        }
    });

    if let Some(error) = errors.lock().unwrap().take() {
        return Err(error);
    }

    download_pb.finish_with_message("All segments downloaded");

    let use_concat = cfg!(not(target_os = "android"));
    let keep_segments = use_concat || cfg!(target_os = "android");
    let concat_list_path = PathBuf::from(format!("{}.concat.txt", output_file));
    if use_concat {
        let mut list_content = String::new();
        for (i, segment) in segments.iter().enumerate() {
            let segment_path = temp_dir.join(format!("{}_{:05}.part", segment_prefix, i));
            let absolute = if segment_path.is_absolute() {
                segment_path
            } else {
                std::env::current_dir()
                    .map(|dir| dir.join(&segment_path))
                    .unwrap_or(segment_path)
            };
            let normalized = absolute.to_string_lossy().replace('\\', "/");
            let escaped = normalized.replace('\'', "'\\''");
            list_content.push_str(&format!(
                "file '{}'\nduration {:.6}\n",
                escaped, segment.duration
            ));
        }
        std::fs::write(&concat_list_path, list_content).with_context(|| {
            format!(
                "Failed to write concat list for ffmpeg: {}",
                concat_list_path.display()
            )
        })?;
        info!(
            "Wrote ffmpeg concat list with {} segments: {}",
            total,
            concat_list_path.display()
        );
    }

    let merge_pb = multi_progress.add(ProgressBar::new(total as u64));
    merge_pb.set_style(
        ProgressStyle::with_template(
            "{msg} [{elapsed_precise}] {bar:40.green} {pos:>7}/{len:7} ({percent}%)",
        )?
        .progress_chars("##-"),
    );
    merge_pb.set_message("Merging segments");

    let mut output = std::fs::File::create(output_file)
        .with_context(|| format!("Failed to create output TS file: {}", output_file))?;

    for i in 0..total {
        let file_name = format!("{}_{:05}.part", segment_prefix, i);
        let tmp_path = temp_dir.join(&file_name);

        let mut segment = std::fs::File::open(&tmp_path)
            .with_context(|| format!("Failed to read segment: {}", tmp_path.display()))?;

        std::io::copy(&mut segment, &mut output)
            .with_context(|| format!("Failed to write to output TS: {}", output_file))?;

        if !keep_segments {
            let _ = std::fs::remove_file(&tmp_path);
        }
        merge_pb.inc(1);
        merge_pb.set_message(format!("Merging segments [{}/{}]", i + 1, total));
    }

    merge_pb.finish_with_message("Merge complete");
    Ok(())
}

pub(super) fn cleanup_segment_temp_files(temp_dir: &Path, output_file: &str) {
    // Remove interrupted cache writes but retain verified segments for retry.
    if let Ok(entries) = std::fs::read_dir(temp_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.contains(".tmp-"))
            {
                let _ = std::fs::remove_file(path);
            }
        }
    }
    let _ = std::fs::remove_file(output_file);
    let concat_list = PathBuf::from(format!("{}.concat.txt", output_file));
    let _ = std::fs::remove_file(concat_list);
}

#[cfg(test)]
mod regression_tests {
    use super::*;
    use crate::test_http::{response, serve};

    #[test]
    fn missing_origin_object_fails_before_selecting_a_transcoder() {
        let (url, server) = serve(1, |_, _, socket| {
            let body = b"<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code><Message>private server detail</Message></Error>";
            write!(
                socket,
                "HTTP/1.1 404 Not Found\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .unwrap();
            socket.write_all(body).unwrap();
        });
        let events = Arc::new(Mutex::new(Vec::new()));
        let captured = events.clone();
        let reporter: ProgressReporter =
            Arc::new(move |event| captured.lock().unwrap().push(event));
        let directory = crate::test_http::TestDirectory::new("missing-origin");
        let output = directory.path().join("video.mp4");
        let error = run_hls_pipeline(
            &reporter,
            &url,
            &RequestContext::default(),
            4,
            output.to_str().unwrap(),
            3,
            0,
            0,
            false,
        )
        .unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("HTTP 404: NoSuchKey"), "{message}");
        assert!(!message.contains("private server detail"));
        assert!(!output.exists());
        assert!(events
            .lock()
            .unwrap()
            .iter()
            .all(|event| !event.message.contains("backend")));
        server.join().unwrap();
    }

    #[test]
    fn permanent_segment_errors_do_not_restart_in_single_thread_mode() {
        let (url, server) = serve(1, |_, _, socket| {
            socket
                .write_all(
                    b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
        });
        let (_, Playlist::MediaPlaylist(playlist)) =
            parse_playlist(b"#EXTM3U\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n").unwrap()
        else {
            panic!("expected media playlist")
        };
        let directory = crate::test_http::TestDirectory::new("permanent-hls-error");
        let output = directory.path().join("video.ts");
        let error = download_and_merge(
            playlist,
            Some(Url::parse(&url).unwrap()),
            4,
            3,
            output.to_str().unwrap(),
            directory.path(),
            "v",
            &MultiProgress::new(),
            noop_progress_reporter(),
            RequestContext::default(),
        )
        .unwrap_err();
        assert!(error.downcast_ref::<HlsHttpError>().is_some(), "{error:#}");
        assert!(format!("{error:#}").contains("HTTP 403"));
        assert!(!output.exists());
        server.join().unwrap();
    }

    #[test]
    fn partial_hls_responses_require_the_requested_range_and_exact_length() {
        for (range, body, expected_error) in [
            ("", "abc", "omitted the Content-Range"),
            ("Content-Range: bytes 0-2/200\r\n", "abc", "does not match"),
            (
                "Content-Range: bytes 100-102/200\r\n",
                "ab",
                "length mismatch",
            ),
            (
                "Content-Range: bytes 100-102/200\r\n",
                "abcd",
                "length mismatch",
            ),
        ] {
            let (url, server) = serve(1, move |_, request, socket| {
                assert!(request
                    .to_ascii_lowercase()
                    .contains("range: bytes=100-102"));
                write!(socket, "HTTP/1.1 206 Partial Content\r\n{range}Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            });
            let error = download_hls_resource(
                &SyncHttpClient::new().unwrap(),
                &HlsResourceRequest {
                    url,
                    byte_range: Some((100, 102)),
                },
                &[],
                1,
            )
            .unwrap_err();
            assert!(format!("{error:#}").contains(expected_error), "{error:#}");
            server.join().unwrap();
        }
        assert!(hls_response_bytes(206, &[], vec![1, 2, 3], None).is_err());
        assert!(hls_response_bytes(204, &[], Vec::new(), None).is_err());
    }

    #[test]
    fn transient_hls_failure_retries_and_recovers() {
        let (url, server) = serve(2, |index, _, socket| {
            if index == 0 {
                socket.write_all(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
            } else {
                response(socket, b"segment");
            }
        });
        let data = download_hls_resource(
            &SyncHttpClient::new().unwrap(),
            &HlsResourceRequest {
                url,
                byte_range: None,
            },
            &[],
            2,
        )
        .unwrap();
        assert_eq!(data, b"segment");
        server.join().unwrap();
    }

    #[test]
    fn missing_segment_preserves_http_error_without_retrying() {
        let (url, server) = serve(1, |_, _, socket| {
            socket
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
        });
        let error = download_hls_resource(
            &SyncHttpClient::new().unwrap(),
            &HlsResourceRequest {
                url,
                byte_range: None,
            },
            &[],
            3,
        )
        .unwrap_err();
        assert!(format!("{error:#}").contains("HTTP 404"), "{error:#}");
        server.join().unwrap();
    }

    #[test]
    fn missing_playlist_reports_http_status_without_retrying() {
        let (url, server) = serve(1, |_, _, socket| {
            socket
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
        });
        let error = download_playlist_with_url(&url, &RequestContext::default()).unwrap_err();
        assert!(format!("{error:#}").contains("HTTP 404"), "{error:#}");
        server.join().unwrap();
    }

    #[test]
    fn redirected_master_and_media_resolve_keys_maps_and_segments() {
        let (url, server) = serve(7, |_, request, socket| {
            match request.split_whitespace().nth(1).unwrap() {
                "/entry" => write!(socket, "HTTP/1.1 302 Found\r\nLocation: /catalog/master.m3u8\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap(),
                "/catalog/master.m3u8" => response(socket, b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia/index.m3u8\n"),
                "/catalog/media/index.m3u8" => write!(socket, "HTTP/1.1 307 Temporary Redirect\r\nLocation: /assets/final/stream?playlist=1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap(),
                "/assets/final/stream?playlist=1" => response(socket, b"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"?asset=key\",IV=0x00000000000000000000000000000000\n#EXT-X-MAP:URI=\"?asset=init\"\n#EXTINF:6,\nsegments/1.m4s\n#EXT-X-ENDLIST\n"),
                "/assets/final/stream?asset=key" => response(socket, &[0; 16]),
                "/assets/final/stream?asset=init" | "/assets/final/segments/1.m4s" => {
                    response(socket, &hex::decode("c3af71addfe4fcac6941286a76ddedc2d873029f04adebdf8920b262bfa0d6d7").unwrap());
                }
                path => panic!("resource resolved against the wrong playlist: {path}"),
            }
        });
        let context = RequestContext::default();
        let (bytes, effective_master) =
            download_playlist_with_url(&format!("{url}/entry"), &context).unwrap();
        let (_, Playlist::MasterPlaylist(master)) = parse_playlist(&bytes).unwrap() else {
            panic!("expected master")
        };
        let media_url = playlist_base_url(&effective_master)
            .join(&select_best_hls_variant(&master).unwrap().uri)
            .unwrap();
        let (bytes, effective_media) =
            download_playlist_with_url(media_url.as_str(), &context).unwrap();
        let (_, Playlist::MediaPlaylist(media)) = parse_playlist(&bytes).unwrap() else {
            panic!("expected media")
        };
        let dir = crate::test_http::TestDirectory::new("hls-redirect");
        let output = dir.path().join("assembled.bin");
        download_and_merge_once(
            media,
            Some(playlist_base_url(&effective_media)),
            1,
            1,
            output.to_str().unwrap(),
            dir.path(),
            "v",
            &MultiProgress::new(),
            noop_progress_reporter(),
            context,
        )
        .unwrap();
        assert_eq!(
            std::fs::read(output).unwrap(),
            b"abcdefghijklmnopabcdefghijklmnop"
        );
        server.join().unwrap();
    }

    #[test]
    fn initialization_is_fetched_once_and_every_fragment_is_readable() {
        let (url, server) = serve(3, |_, request, socket| {
            let path = request.split_whitespace().nth(1).unwrap();
            response(
                socket,
                match path {
                    "/init.mp4" => b"INIT",
                    "/1.m4s" => b"S1",
                    "/2.m4s" => b"S2",
                    _ => panic!("unexpected request {path}"),
                },
            );
        });
        let (_, playlist) = parse_playlist(b"#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\n1.m4s\n#EXT-X-DISCONTINUITY\n#EXTINF:6,\n2.m4s\n#EXT-X-ENDLIST\n").unwrap();
        let Playlist::MediaPlaylist(playlist) = playlist else {
            panic!()
        };
        let dir = std::env::temp_dir().join(format!("hls-init-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let output = dir.join("assembled.bin");
        for _ in 0..2 {
            download_and_merge_once(
                playlist.clone(),
                Some(Url::parse(&format!("{url}/")).unwrap()),
                2,
                1,
                output.to_str().unwrap(),
                &dir,
                "v",
                &MultiProgress::new(),
                noop_progress_reporter(),
                RequestContext::default(),
            )
            .unwrap();
            assert_eq!(std::fs::read(dir.join("v_00000.part")).unwrap(), b"INITS1");
            assert_eq!(std::fs::read(dir.join("v_00001.part")).unwrap(), b"INITS2");
        }
        server.join().unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn declared_encryption_never_falls_back_to_clear_bytes() {
        let (url, server) = serve(1, |_, _, socket| response(socket, &vec![0x47; 188 * 7]));
        let request = HlsResourceRequest {
            url,
            byte_range: None,
        };
        assert!(download_and_decrypt_segment(
            &SyncHttpClient::new().unwrap(),
            &[],
            &request,
            None,
            Some(&(vec![0; 16], vec![0; 16])),
            1
        )
        .is_err());
        server.join().unwrap();
    }

    #[test]
    fn live_playlist_is_not_reported_as_complete() {
        let result = download_and_merge_once(
            MediaPlaylist::default(),
            None,
            1,
            1,
            "unused",
            &std::env::temp_dir(),
            "v",
            &MultiProgress::new(),
            noop_progress_reporter(),
            RequestContext::default(),
        );
        assert!(result.unwrap_err().to_string().contains("EXT-X-ENDLIST"));
    }
}

#[cfg(test)]
mod media_roundtrip_tests {
    use super::*;
    #[test]
    #[ignore = "requires a local FFmpeg installation"]
    fn fmp4_vod_remux_preserves_all_three_segments() {
        let ffmpeg = resolve_ffmpeg_path().expect("FFmpeg required");
        let dir = std::env::temp_dir().join(format!("segmeris-fmp4-roundtrip-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let manifest = dir.join("index.m3u8");
        let generated = command_with_timeout(
            Command::new(&ffmpeg)
                .current_dir(&dir)
                .args([
                    "-v",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    "testsrc=size=160x90:rate=10",
                    "-f",
                    "lavfi",
                    "-i",
                    "sine=frequency=440:sample_rate=48000",
                    "-t",
                    "18",
                    "-c:v",
                    "libx264",
                    "-pix_fmt",
                    "yuv420p",
                    "-g",
                    "60",
                    "-c:a",
                    "aac",
                    "-hls_time",
                    "6",
                    "-hls_playlist_type",
                    "vod",
                    "-hls_segment_type",
                    "fmp4",
                ])
                .arg(&manifest),
            Duration::from_secs(30),
        )
        .unwrap()
        .unwrap();
        assert!(
            generated.status.success(),
            "{}",
            String::from_utf8_lossy(&generated.stderr)
        );
        let source_dir = dir.clone();
        let (base, server) = crate::test_http::serve(5, move |_, request, socket| {
            let name = request
                .split_whitespace()
                .nth(1)
                .unwrap()
                .trim_start_matches('/');
            assert!(!name.contains(".."));
            crate::test_http::response(socket, &std::fs::read(source_dir.join(name)).unwrap());
        });
        let output = dir.join("output.mp4");
        let url = format!("{base}/index.m3u8");
        download_media_with_context_core(
            noop_progress_reporter(),
            MediaSource {
                page_url: url.clone(),
                media_url: url,
                ..Default::default()
            },
            output.to_string_lossy().into_owned(),
            DownloadOptions::default(),
            RequestContext::default(),
        )
        .unwrap();
        let seconds = plain_mp4_duration_seconds(&output).unwrap();
        assert!((17.5..19.0).contains(&seconds), "movie duration {seconds}");
        let probe = command_with_timeout(
            Command::new(ffmpeg.with_file_name(if cfg!(windows) {
                "ffprobe.exe"
            } else {
                "ffprobe"
            }))
            .args([
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-count_frames",
                "-show_entries",
                "stream=nb_read_frames",
                "-of",
                "csv=p=0",
            ])
            .arg(&output),
            Duration::from_secs(20),
        )
        .unwrap()
        .unwrap();
        assert!(probe.status.success());
        assert_eq!(
            String::from_utf8_lossy(&probe.stdout).trim(),
            "180",
            "all source frames must survive stream copy"
        );
        server.join().unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }
}
