//! Synchronous network helpers for the downloader.
//!
//! The `courierust` client is a blocking engine, so every network call
//! here is synchronous. These helpers mirror the small `reqwest` surface
//! the downloader previously used: per-request headers, retries, Range
//! support, and streaming to disk.
//!
//! Courierust handles HTTP and TLS directly, including TLS 1.2 and 1.3.
//!
//! ## Trust anchors
//!
//! The default trust set is the Mozilla root set compiled into this
//! binary plus [`COMPATIBILITY_ANCHORS`] (see below). Managed networks
//! with TLS inspection (corporate proxies, anti-virus products) re-sign
//! every connection with a private root; deployments like that can
//! install their private root through `SEGMERIS_EXTRA_CA_FILE` — a
//! PEM/DER certificate file, or a platform-separated list of them. The
//! setting is opt-in and audit-able: whoever controls the process
//! environment can already control the process, and an unset variable
//! keeps the default trust set exactly.

use anyhow::{bail, Context, Result};
use courierust::courierust_client::{Client, ClientConfig, TlsSettings as ClientTls};
use courierust::courierust_fingerprint::profile::chrome_tls_profile;
use courierust::courierust_http::header::{HeaderName, HeaderValue};
use courierust::courierust_http::method::Method;
use courierust::courierust_http::request::Request;
use courierust::courierust_tls::x509::parse_certificate;
use courierust::courierust_tls::{RootStore, TlsVersion};
use std::time::Duration;

/// Environment variable naming additional PEM/DER trust-anchor files.
pub const EXTRA_CA_ENV: &str = "SEGMERIS_EXTRA_CA_FILE";

/// Compiled-in anchors beyond the Mozilla root set.
///
/// `GlobalSign Root CA` (R1, 1998) left the Mozilla program, but real
/// operators still chain to it: `api.bilibili.com` serves
/// `leaf → GlobalSign RSA OV SSL CA 2018 → GlobalSign Root CA - R3`,
/// where the final certificate is R3 *cross-signed by R1*. Browsers
/// rebuild such chains against their local R3 anchor; the TLS engine
/// here validates the sent chain as-is, so without R1 the service is
/// unreachable. R1 expires 2028-01-28 — drop this anchor once chains
/// stop referencing it.
const COMPATIBILITY_ANCHORS: &[&[u8]] = &[include_bytes!("../assets/GlobalSign-Root-CA-R1.der")];

/// Maximum body accepted for in-memory reads (playlists, keys, JSON).
pub const MAX_MEMORY_BODY: usize = 64 * 1024 * 1024;
/// Default connect timeout.
const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Default read timeout.
const DEFAULT_READ_TIMEOUT: Duration = Duration::from_secs(45);
/// Maximum redirects followed by the HTTP engine (mirrors the courierust
/// config and RFC 9110 guidance; bounded to prevent redirect loops).
const MAX_REDIRECTS: usize = 10;

/// A GET response: `(status, headers, body)`.
type GetResult = (u16, Vec<(String, String)>, Vec<u8>);

/// A synchronous HTTP client backed by `courierust` with Mozilla trust
/// roots, per-request headers, Range support and sane timeouts.
///
/// Requests use Courierust's TLS stack with Mozilla trust roots, per-request
/// headers, Range support and bounded redirects and response bodies.
#[derive(Clone)]
pub struct SyncHttpClient {
    inner: Client,
}

impl SyncHttpClient {
    /// Build a client with Mozilla TLS roots and production timeouts.
    pub fn new() -> Result<Self> {
        Self::with_timeouts(DEFAULT_CONNECT_TIMEOUT, DEFAULT_READ_TIMEOUT)
    }

    /// Build a client with explicit timeouts.
    pub fn with_timeouts(connect_timeout: Duration, read_timeout: Duration) -> Result<Self> {
        Self::build(connect_timeout, read_timeout, MAX_REDIRECTS)
    }

    /// Build a client that does **not** follow redirects: the caller
    /// receives the raw 3xx response and can inspect its `Location`
    /// header.
    ///
    /// Used to resolve short-link chains (e.g. `b23.tv`): the interesting
    /// URL is a redirect target, and `courierust::Response` does not
    /// expose the URL a redirect chain ended on, so the chain is followed
    /// manually here.
    pub fn without_redirects() -> Result<Self> {
        Self::build(DEFAULT_CONNECT_TIMEOUT, DEFAULT_READ_TIMEOUT, 0)
    }

    fn build(
        connect_timeout: Duration,
        read_timeout: Duration,
        max_redirects: usize,
    ) -> Result<Self> {
        let mut roots = default_roots();
        for anchor in extra_trust_anchors()? {
            roots.add_der(anchor);
        }
        if roots.is_empty() {
            bail!("no TLS trust anchors could be loaded");
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        let config = ClientConfig {
            http2: false,
            http3: false,
            max_connections_per_host: 4,
            connect_timeout: Some(connect_timeout),
            read_timeout: Some(read_timeout),
            handshake_timeout: Some(Duration::from_secs(10)),
            max_redirects,
            user_agent: Some("Segmeris/1.0".to_string()),
            max_header_list: 1 << 20,
            max_body: MAX_MEMORY_BODY,
            tls: Some(ClientTls {
                roots,
                verify: true,
                alpn: vec![b"http/1.1".to_vec()],
                min_version: TlsVersion::Tls12,
                max_version: TlsVersion::Tls13,
                now,
                identity: None,
                // Traffic-risk engines score the ClientHello: Bilibili
                // answers the built-in, sparse shape with HTTP 412 and
                // the Chrome parameter set resolves it.
                profile: Some(chrome_tls_profile()),
            }),
            ..Default::default()
        };

        Ok(Self {
            inner: Client::with_config(config),
        })
    }

    /// Perform a GET and return the full body (bounded by
    /// `MAX_MEMORY_BODY`). Returns `(status, headers, body)`.
    pub fn get(&self, url: &str, headers: &[(String, String)]) -> Result<GetResult> {
        self.get_impl(url, headers, None)
    }

    /// Perform a GET with a Range header and return the body.
    pub fn get_range(
        &self,
        url: &str,
        headers: &[(String, String)],
        start: u64,
        end: u64,
    ) -> Result<GetResult> {
        self.get_impl(url, headers, Some((start, end)))
    }

    fn get_impl(
        &self,
        url: &str,
        headers: &[(String, String)],
        range: Option<(u64, u64)>,
    ) -> Result<GetResult> {
        ensure_http_url(url)?;
        self.get_via_courierust(url, headers, range)
    }

    fn get_via_courierust(
        &self,
        url: &str,
        headers: &[(String, String)],
        range: Option<(u64, u64)>,
    ) -> Result<GetResult> {
        let mut request = Request::new(Method::GET, "/");
        for (name, value) in headers {
            let Some(header_name) = parse_header_name(name) else {
                continue;
            };
            let Some(header_value) = parse_header_value(value) else {
                continue;
            };
            request = request.header(header_name, header_value);
        }
        if let Some((start, end)) = range {
            request = request.header(
                HeaderName::from_lowercase("range"),
                HeaderValue::from_bytes(format!("bytes={}-{}", start, end).as_bytes())?,
            );
        }
        let response = self
            .inner
            .execute(url, request)
            .with_context(|| format!("HTTP GET failed: {url}"))?;
        let status = response.status.as_u16();
        let response_headers = response
            .headers
            .iter()
            .map(|(name, value)| {
                (
                    name.as_str().to_string(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                )
            })
            .collect();
        let body = response
            .body
            .collect_limited(MAX_MEMORY_BODY)
            .context("failed to read HTTP response body")?
            .to_vec();
        Ok((status, response_headers, body))
    }

    /// Underlying Courierust client (for advanced uses).
    pub fn inner(&self) -> &Client {
        &self.inner
    }
}

/// The default trust set: the bundled Mozilla roots plus the compiled-in
/// compatibility anchors.
fn default_roots() -> RootStore {
    let mut roots = RootStore::new();
    for certificate in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
        roots.add_der(certificate.as_ref().to_vec());
    }
    for anchor in COMPATIBILITY_ANCHORS {
        roots.add_der(anchor.to_vec());
    }
    roots
}

/// Load additional DER trust anchors configured through [`EXTRA_CA_ENV`].
///
/// The value is a single file or a platform-separated list of them. Each
/// file is a PEM bundle, or — when it does not start with the PEM marker
/// — a single DER certificate. A malformed file is an error: a deployment
/// that deliberately installed a private root must not silently keep
/// running without it.
fn extra_trust_anchors() -> Result<Vec<Vec<u8>>> {
    let Some(spec) = std::env::var_os(EXTRA_CA_ENV) else {
        return Ok(Vec::new());
    };
    let mut anchors = Vec::new();
    for path in std::env::split_paths(&spec) {
        if path.as_os_str().is_empty() {
            continue;
        }
        anchors.extend(load_trust_anchor_file(&path)?);
    }
    if anchors.is_empty() {
        bail!("{EXTRA_CA_ENV} was set but did not yield any trust anchors");
    }
    Ok(anchors)
}

/// Read one configured trust-anchor file: a PEM bundle when it starts
/// with the PEM marker, otherwise a single DER certificate. An empty
/// file contributes nothing; every certificate that is loaded must
/// parse.
fn load_trust_anchor_file(path: &std::path::Path) -> Result<Vec<Vec<u8>>> {
    let data = std::fs::read(path).with_context(|| {
        format!(
            "Failed to read extra CA file configured in {EXTRA_CA_ENV}: {}",
            path.display()
        )
    })?;
    if data.is_empty() {
        return Ok(Vec::new());
    }
    if contains_bytes(&data, b"-----BEGIN CERTIFICATE-----") {
        let certificates = pem_certificates(&data).with_context(|| {
            format!("Failed to parse PEM trust anchors from {}", path.display())
        })?;
        for certificate in &certificates {
            parse_certificate(certificate).map_err(|e| {
                anyhow::anyhow!(
                    "PEM block in {} is not a valid certificate: {e:?}",
                    path.display()
                )
            })?;
        }
        return Ok(certificates);
    }
    parse_certificate(&data)
        .map_err(|e| anyhow::anyhow!("{} is not a valid DER certificate: {e:?}", path.display()))?;
    Ok(vec![data])
}

/// Whether `haystack` contains `needle`. Used to recognise PEM framing
/// even when a bundle carries leading comments or other prose.
fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// Extract the DER certificates out of PEM text.
fn pem_certificates(data: &[u8]) -> Result<Vec<Vec<u8>>> {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";

    let text = std::str::from_utf8(data).context("PEM file is not valid UTF-8")?;
    let mut certificates = Vec::new();
    let mut rest = text;
    while let Some(begin) = rest.find(BEGIN) {
        let body = &rest[begin + BEGIN.len()..];
        let end = body
            .find(END)
            .context("PEM certificate block is not terminated")?;
        let der = crate::crypto::base64::decode(&body[..end])
            .context("PEM certificate body is not valid base64")?;
        if der.is_empty() {
            bail!("PEM certificate block decoded to zero bytes");
        }
        certificates.push(der);
        rest = &body[end + END.len()..];
    }
    if certificates.is_empty() {
        bail!("no -----BEGIN CERTIFICATE----- blocks found");
    }
    Ok(certificates)
}

/// Reject any URL whose scheme is not http or https. This is the final
/// network-layer guard (defense in depth) against SSRF / local-file access
/// even if a caller fails to validate a resolved playlist/segment URL.
fn ensure_http_url(url: &str) -> Result<()> {
    let parsed = url::Url::parse(url).with_context(|| format!("Invalid URL: {url}"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        bail!(
            "Refusing non-HTTP(S) request URL (scheme: {}): {}",
            parsed.scheme(),
            url
        );
    }
    Ok(())
}

/// Parse an HTTP header name, returning `None` for any value that does not
/// conform to HTTP token rules. Callers must DROP invalid headers rather than
/// forwarding them (fail-closed), preventing header injection.
fn parse_header_name(name: &str) -> Option<HeaderName> {
    HeaderName::from_bytes(name.trim().as_bytes()).ok()
}

/// Parse an HTTP header value, returning `None` for any value containing
/// CR/LF/control bytes (which would enable response-splitting / header
/// injection). Callers must DROP invalid headers rather than forwarding them.
fn parse_header_value(value: &str) -> Option<HeaderValue> {
    HeaderValue::from_bytes(value.as_bytes()).ok()
}

/// A simple semaphore built on `std` for bounded concurrency.
pub struct SyncSemaphore {
    permits: std::sync::Mutex<usize>,
    condvar: std::sync::Condvar,
    max: usize,
}

impl SyncSemaphore {
    pub fn new(permits: usize) -> Self {
        Self {
            permits: std::sync::Mutex::new(permits),
            condvar: std::sync::Condvar::new(),
            max: permits,
        }
    }

    pub fn acquire(&self) {
        let mut guard = self.permits.lock().unwrap();
        while *guard == 0 {
            guard = self.condvar.wait(guard).unwrap();
        }
        *guard -= 1;
    }

    pub fn release(&self) {
        let mut guard = self.permits.lock().unwrap();
        if *guard < self.max {
            *guard += 1;
            self.condvar.notify_one();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semaphore_acquire_release() {
        let sem = SyncSemaphore::new(2);
        sem.acquire();
        sem.acquire();
        sem.release();
        sem.release();
    }

    #[test]
    fn header_name_rejects_injection() {
        // Valid token names pass.
        assert!(parse_header_name("User-Agent").is_some());
        assert!(parse_header_name("x-custom-header_1").is_some());
        // CR/LF / colon / space / non-graphic bytes must be rejected.
        assert!(parse_header_name("X-Evil\r\nInjected").is_none());
        assert!(parse_header_name("X-Evil:value").is_none());
        assert!(parse_header_name("Bad Header").is_none());
        assert!(parse_header_name("X-中文").is_none());
    }

    #[test]
    fn header_value_rejects_crlf() {
        // Normal values pass.
        assert!(parse_header_value("application/json").is_some());
        assert!(parse_header_value("").is_some());
        // CR / LF / NUL and other control bytes must be rejected.
        assert!(parse_header_value("text/html\r\nX-Evil: 1").is_none());
        assert!(parse_header_value("a\nb").is_none());
        assert!(parse_header_value("a\rb").is_none());
    }

    #[test]
    fn url_scheme_allowlist() {
        assert!(ensure_http_url("https://example.com/a.m3u8").is_ok());
        assert!(ensure_http_url("http://example.com/a.ts").is_ok());
        // Non-HTTP schemes are refused.
        assert!(ensure_http_url("file:///etc/passwd").is_err());
        assert!(ensure_http_url("ftp://example.com/a.ts").is_err());
        assert!(ensure_http_url("data:text/plain;base64,AAAA").is_err());
        assert!(ensure_http_url("javascript:alert(1)").is_err());
    }

    #[test]
    fn parses_pem_certificate_bundles() {
        // The parser only verifies PEM framing plus base64, so synthetic
        // payloads exercise every branch without real certificates.
        let pem = "-----BEGIN CERTIFICATE-----\nZm9vYmFy\n-----END CERTIFICATE-----\n\
                   -----BEGIN CERTIFICATE-----\r\nZm9v\r\n-----END CERTIFICATE-----\r\n";
        let certificates = pem_certificates(pem.as_bytes()).expect("bundle parses");
        assert_eq!(certificates, vec![b"foobar".to_vec(), b"foo".to_vec()]);
    }

    #[test]
    fn rejects_malformed_pem_bundles() {
        // No certificate blocks at all.
        assert!(pem_certificates(b"not a pem file").is_err());
        // Unterminated block.
        assert!(pem_certificates(b"-----BEGIN CERTIFICATE-----\nZm9v\n").is_err());
        // Invalid base64 body.
        assert!(
            pem_certificates(b"-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----")
                .is_err()
        );
        // A block that decodes to nothing carries no anchor.
        assert!(
            pem_certificates(b"-----BEGIN CERTIFICATE-----\n\n-----END CERTIFICATE-----").is_err()
        );
    }

    /// The chain a production CDN actually serves must anchor to the
    /// default trust set. The fixture is a real capture of what
    /// `api.bilibili.com` sends: a leaf, its intermediate, and a
    /// cross-signed `GlobalSign Root CA - R3` whose issuer is the 1998
    /// `GlobalSign Root CA` in [`COMPATIBILITY_ANCHORS`].
    #[test]
    fn anchors_cross_signed_chains_like_the_ones_served_in_production() {
        use courierust::courierust_tls::x509::validate_chain;

        let pem = include_str!("../tests/data/bilibili-chain.pem");
        let chain = pem_certificates(pem.as_bytes()).expect("fixture parses");
        assert_eq!(
            chain.len(),
            3,
            "fixture is leaf + intermediate + cross-signed root"
        );

        let roots = default_roots();

        // Fixed to the capture day: the fixture is a snapshot, so the
        // assertion must not depend on when the suite runs.
        const CAPTURED_AT: i64 = 1_791_072_000; // 2026-10-04T00:00:00Z
        validate_chain(&roots, &chain, CAPTURED_AT)
            .expect("the default trust set must anchor the chain served in production");
    }

    /// `SEGMERIS_EXTRA_CA_FILE` accepts PEM bundles and DER files; an
    /// empty file contributes nothing while garbage must fail loudly.
    #[test]
    fn loads_configured_trust_anchor_files() {
        let fixture = include_bytes!("../tests/data/bilibili-chain.pem");
        let chain = pem_certificates(fixture).expect("fixture parses");

        let dir = std::env::temp_dir().join(format!("segmeris-net-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let result = (|| {
            let pem_path = dir.join("anchor.pem");
            std::fs::write(&pem_path, fixture).expect("write pem");
            assert_eq!(load_trust_anchor_file(&pem_path)?, chain);

            let der_path = dir.join("anchor.der");
            std::fs::write(&der_path, &chain[0]).expect("write der");
            assert_eq!(load_trust_anchor_file(&der_path)?, vec![chain[0].clone()]);

            let empty_path = dir.join("empty");
            std::fs::write(&empty_path, b"").expect("write empty");
            assert!(load_trust_anchor_file(&empty_path)?.is_empty());

            Ok::<(), anyhow::Error>(())
        })();
        result.expect("valid anchor files load");

        let garbage_path = dir.join("garbage.der");
        std::fs::write(&garbage_path, b"not a certificate").expect("write garbage");
        assert!(load_trust_anchor_file(&garbage_path).is_err());
        assert!(load_trust_anchor_file(&dir.join("missing.pem")).is_err());

        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    /// Temporary diagnostic: fetch the TLS-fingerprint report for this
    /// client's actual ClientHello.
    #[test]
    #[ignore = "diagnostic: hits the public tls.peet.ws fingerprint service"]
    fn dump_tls_fingerprint() {
        let client = SyncHttpClient::new().expect("client builds");
        let (status, _headers, body) = client
            .get("https://tls.peet.ws/api/all", &[])
            .expect("fingerprint fetch");
        eprintln!("status: {status}");
        let text = String::from_utf8_lossy(&body);
        for line in text.lines() {
            let line = line.trim();
            if line.starts_with("\"ja3\"")
                || line.starts_with("\"ja4\"")
                || line.starts_with("\"ja3_hash\"")
            {
                eprintln!("{line}");
            }
        }
    }
}
