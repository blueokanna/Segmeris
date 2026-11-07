//! Synchronous HTTP streaming with Courierust and verified TLS path building.
//! Metadata reads are bounded; media bodies stream directly to disk.
//! Trust comes from Mozilla roots and optional PEM/DER files configured through
//! SEGMERIS_EXTRA_CA_FILE. Cross-signed paths that Courierust cannot anchor are
//! retried with rustls using the same trust store and certificate validation.

use anyhow::{bail, Context, Result};
mod tls;
mod transport;
use courierust::courierust_client::{ClientConfig, TlsSettings as ClientTls};
use courierust::courierust_fingerprint::profile::{chrome_tls_profile, TlsProfile};
use courierust::courierust_http::header::{HeaderName, HeaderValue};
use courierust::courierust_http::method::Method;
use courierust::courierust_http::request::Request;
use courierust::courierust_tls::x509::parse_certificate;
use courierust::courierust_tls::{RootStore, TlsVersion};
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use transport::Client;

/// Environment variable naming additional PEM/DER trust-anchor files.
pub const EXTRA_CA_ENV: &str = "SEGMERIS_EXTRA_CA_FILE";

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

pub(crate) struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: transport::ResponseBody,
    pub url: url::Url,
}

/// A synchronous HTTP client backed by `courierust` with Mozilla trust
/// roots, per-request headers, Range support and sane timeouts.
///
/// Requests use Courierust's TLS stack with Mozilla trust roots, per-request
/// headers, Range support and bounded redirects and response bodies.
///
/// ## Non-compliant TLS 1.2 edges
///
/// Some media CDNs (Bilibili's `upos-sz-mirrorcos*.bilivideo.com` COS
/// mirrors, for example) answer a TLS 1.3-capable ClientHello with a
/// TLS 1.2 ServerHello but omit the RFC 8446 downgrade sentinel. The
/// engine — like BoringSSL — rightly rejects that; OpenSSL and Schannel
/// clients ignore it, which is why `curl`-based downloaders reach such
/// hosts. To stay compatible without weakening anything else, a request
/// that fails with *exactly* that condition is retried once with
/// [`Self::tls12_fallback`], a client capped at TLS 1.2 (no downgrade
/// detection applies below 1.3). The host is remembered process-wide so
/// later Range requests skip the doomed attempt. Certificate chain,
/// hostname and validity verification are identical on both clients.
#[derive(Clone)]
pub struct SyncHttpClient {
    inner: Client,
    tls12_fallback: Client,
    max_redirects: usize,
}

impl SyncHttpClient {
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
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        Ok(Self {
            max_redirects,
            inner: make_client(connect_timeout, read_timeout, 0, now, TlsVersion::Tls13)?,
            tls12_fallback: make_client(connect_timeout, read_timeout, 0, now, TlsVersion::Tls12)?,
        })
    }

    pub fn get(&self, url: &str, headers: &[(String, String)]) -> Result<GetResult> {
        self.get_with_url(url, headers).map(|(result, _)| result)
    }

    pub fn get_with_url(
        &self,
        url: &str,
        headers: &[(String, String)],
    ) -> Result<(GetResult, url::Url)> {
        let response = self.response(url, headers, None)?;
        let effective = response.url.clone();
        Ok((collect_response(response)?, effective))
    }

    pub fn get_range(
        &self,
        url: &str,
        headers: &[(String, String)],
        start: u64,
        end: u64,
    ) -> Result<GetResult> {
        collect_response(self.stream_range(url, headers, start, end)?)
    }

    pub(crate) fn stream(&self, url: &str, headers: &[(String, String)]) -> Result<HttpResponse> {
        self.response(url, headers, None)
    }

    pub(crate) fn stream_range(
        &self,
        url: &str,
        headers: &[(String, String)],
        start: u64,
        end: u64,
    ) -> Result<HttpResponse> {
        self.response(url, headers, Some((start, end)))
    }

    fn response(
        &self,
        url: &str,
        headers: &[(String, String)],
        range: Option<(u64, u64)>,
    ) -> Result<HttpResponse> {
        let mut current = url::Url::parse(url)?;
        let mut headers = headers.to_vec();
        let mut seen = HashSet::new();
        for hop in 0..=self.max_redirects {
            ensure_http_url(current.as_str())?;
            crate::download_control::checkpoint()?;
            if !seen.insert(current.clone()) {
                bail!("HTTP redirect loop");
            }
            let perform = |client: &Client| -> Result<_> {
                let mut request = Request::new(Method::GET, "/");
                for (name, value) in &headers {
                    if matches!(
                        name.to_ascii_lowercase().as_str(),
                        "host"
                            | "content-length"
                            | "transfer-encoding"
                            | "connection"
                            | "accept-encoding"
                            | "range"
                    ) {
                        continue;
                    }
                    let name = parse_header_name(name).context("Invalid HTTP header name")?;
                    let value = parse_header_value(value).context("Invalid HTTP header value")?;
                    request = request.header(name, value);
                }
                if let Some((start, end)) = range {
                    request = request.header(
                        HeaderName::from_lowercase("range"),
                        HeaderValue::from_bytes(format!("bytes={start}-{end}").as_bytes())?,
                    );
                }
                request = request.header(
                    HeaderName::from_lowercase("accept-encoding"),
                    HeaderValue::from_bytes(b"identity")?,
                );
                client.execute(current.as_str(), request)
            };
            let host = current.host_str().unwrap_or_default();
            let response = if host_needs_tls12(host) {
                perform(&self.tls12_fallback)?
            } else {
                match perform(&self.inner) {
                    Ok(response) => response,
                    Err(error) if is_missing_downgrade_sentinel(&error) => {
                        remember_tls12_host(host);
                        perform(&self.tls12_fallback)?
                    }
                    Err(error) => return Err(error),
                }
            };
            let status = response.status.as_u16();
            if matches!(status, 301 | 302 | 303 | 307 | 308) && self.max_redirects > 0 {
                if hop == self.max_redirects {
                    bail!("HTTP redirect limit exceeded");
                }
                let location = response
                    .headers
                    .get("location")
                    .and_then(|v| v.to_str().ok())
                    .context("Redirect has no Location")?;
                let next = current.join(location)?;
                if current.origin() != next.origin() {
                    headers.retain(|(name, _)| {
                        matches!(
                            name.to_ascii_lowercase().as_str(),
                            "user-agent" | "accept" | "referer" | "origin" | "if-range"
                        )
                    });
                    if current.scheme() == "https" && next.scheme() == "http" {
                        headers.retain(|(name, _)| {
                            !matches!(name.to_ascii_lowercase().as_str(), "referer" | "origin")
                        });
                    }
                }
                current = next;
                continue;
            }
            let headers = response
                .headers
                .iter()
                .map(|(n, v)| {
                    (
                        n.as_str().to_owned(),
                        String::from_utf8_lossy(v.as_bytes()).into_owned(),
                    )
                })
                .collect();
            return Ok(HttpResponse {
                status,
                headers,
                body: response.body,
                url: current,
            });
        }
        unreachable!()
    }
}

/// The `ClientHello` profile for the TLS 1.2 compatibility client.
///
/// It keeps Chrome's cipher list, extension order and signature
/// algorithms, but advertises only TLS 1.2 and only the P-256 group: the
/// engine's TLS 1.2 handshake implements ECDHE on secp256r1 alone, so
/// offering X25519 / P-384 (as the full Chrome profile does) lets a server
/// choose a group the client cannot finish.
///
/// Both RFC 7627 (`extended_master_secret`) and RFC 5077
/// (`session_ticket`) stay in the offer, since the Courierust engine handles
/// the server's echo and the pre-`ChangeCipherSpec` ticket — Bilibili's
/// `upos-sz-mirrorcos*` edges exercise both.
fn tls12_client_profile() -> TlsProfile {
    let mut profile = chrome_tls_profile();
    profile.supported_versions = vec![0x0303];
    profile.groups = vec![23];
    profile
}

/// Build one `courierust` client with the default trust set.
///
/// `max_tls` is the highest TLS version the client offers. Every other
/// setting — including the Chrome ClientHello profile, ALPN, timeouts and
/// the certificate verifier — is identical across clients, so the TLS 1.2
/// fallback used for non-compliant CDNs never differs in authentication
/// behaviour from the primary client.
fn make_client(
    connect_timeout: Duration,
    read_timeout: Duration,
    max_redirects: usize,
    now: i64,
    max_tls: TlsVersion,
) -> Result<Client> {
    let mut roots = default_roots();
    for anchor in extra_trust_anchors()? {
        roots.add_der(anchor);
    }
    if roots.is_empty() {
        bail!("no TLS trust anchors could be loaded");
    }

    let config = ClientConfig {
        http2: false,
        http3: false,
        max_connections_per_host: 4,
        connect_timeout: Some(connect_timeout),
        read_timeout: Some(read_timeout),
        handshake_timeout: Some(Duration::from_secs(10)),
        max_redirects,
        user_agent: Some(concat!("Segmeris/", env!("CARGO_PKG_VERSION")).to_string()),
        max_header_list: 1 << 20,
        max_body: MAX_MEMORY_BODY,
        tls: Some(ClientTls {
            roots,
            verify: true,
            alpn: vec![b"http/1.1".to_vec()],
            min_version: TlsVersion::Tls12,
            max_version: max_tls,
            now,
            identity: None,
            profile: Some(if max_tls >= TlsVersion::Tls13 {
                chrome_tls_profile()
            } else {
                tls12_client_profile()
            }),
        }),
        ..Default::default()
    };
    Ok(Client::with_config(config))
}

/// The Mozilla trust set; retired roots are not restored for CDN compatibility.
fn default_roots() -> RootStore {
    let mut roots = RootStore::new();
    for certificate in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
        roots.add_der(certificate.as_ref().to_vec());
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

/// Whether `error` is Courierust rejecting a TLS 1.2 ServerHello that came
/// back without the RFC 8446 downgrade sentinel. Only this exact condition
/// is retried over the TLS 1.2 client: a sentinel that is present but
/// wrong (or any other protocol error) stays a hard failure.
fn is_missing_downgrade_sentinel(error: &anyhow::Error) -> bool {
    error
        .chain()
        .any(|cause| cause.to_string().contains("missing downgrade sentinel"))
}

/// Hosts whose TLS handshake previously omitted the downgrade sentinel,
/// remembered process-wide so later Range requests skip the TLS 1.3
/// attempt that is known to fail.
fn tls12_sentinel_hosts() -> &'static Mutex<HashSet<String>> {
    static HOSTS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    HOSTS.get_or_init(|| Mutex::new(HashSet::new()))
}

fn host_needs_tls12(host: &str) -> bool {
    tls12_sentinel_hosts()
        .lock()
        .map(|hosts| hosts.contains(host))
        .unwrap_or(false)
}

fn remember_tls12_host(host: &str) {
    if host.is_empty() {
        return;
    }
    if let Ok(mut hosts) = tls12_sentinel_hosts().lock() {
        hosts.insert(host.to_string());
    }
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
        assert!(parse_header_name("User-Agent").is_some());
        assert!(parse_header_name("x-custom-header_1").is_some());
        assert!(parse_header_name("X-Evil\r\nInjected").is_none());
        assert!(parse_header_name("X-Evil:value").is_none());
        assert!(parse_header_name("Bad Header").is_none());
        assert!(parse_header_name("X-中文").is_none());
    }

    #[test]
    fn header_value_rejects_crlf() {
        assert!(parse_header_value("application/json").is_some());
        assert!(parse_header_value("").is_some());
        assert!(parse_header_value("text/html\r\nX-Evil: 1").is_none());
        assert!(parse_header_value("a\nb").is_none());
        assert!(parse_header_value("a\rb").is_none());
    }

    #[test]
    fn url_scheme_allowlist() {
        assert!(ensure_http_url("https://example.com/a.m3u8").is_ok());
        assert!(ensure_http_url("http://example.com/a.ts").is_ok());
        assert!(ensure_http_url("file:///etc/passwd").is_err());
        assert!(ensure_http_url("ftp://example.com/a.ts").is_err());
        assert!(ensure_http_url("data:text/plain;base64,AAAA").is_err());
        assert!(ensure_http_url("javascript:alert(1)").is_err());
    }

    #[test]
    fn detects_missing_downgrade_sentinel_errors() {
        let sentinel = anyhow::anyhow!(
            "Io: TLS protocol error: TLS 1.2 ServerHello missing downgrade sentinel"
        );
        assert!(is_missing_downgrade_sentinel(&sentinel));
        let other = anyhow::anyhow!("Io: TLS protocol error: bad record mac");
        assert!(!is_missing_downgrade_sentinel(&other));
        let wrapped = sentinel.context("HTTP GET failed: https://example.com/a.m4s");
        assert!(is_missing_downgrade_sentinel(&wrapped));
    }

    #[test]
    fn remembers_tls12_compatibility_hosts() {
        assert!(!host_needs_tls12("cdn.example.invalid"));
        remember_tls12_host("cdn.example.invalid");
        assert!(host_needs_tls12("cdn.example.invalid"));
        // Empty hosts are never remembered nor matched.
        remember_tls12_host("");
        assert!(!host_needs_tls12(""));
    }

    #[test]
    fn tls12_compatibility_profile_stays_within_engine_capabilities() {
        let profile = tls12_client_profile();
        assert_eq!(profile.supported_versions, vec![0x0303]);
        assert_eq!(profile.groups, vec![23]);
        let chrome = chrome_tls_profile();
        assert_eq!(profile.ciphers, chrome.ciphers);
        assert_eq!(profile.extensions, chrome.extensions);
        assert!(profile.extensions.contains(&0x0017));
        assert!(profile.extensions.contains(&0x0023));
    }

    #[test]
    fn parses_pem_certificate_bundles() {
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

#[cfg(test)]
mod regression_tests;

fn collect_response(response: HttpResponse) -> Result<GetResult> {
    let mut headers = response.headers;
    let encoding = headers
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("content-encoding"))
        .map(|(_, v)| v.trim().to_ascii_lowercase())
        .unwrap_or_default();
    let body = response.body.collect_limited(MAX_MEMORY_BODY)?;
    let body = match encoding.as_str() {
        "" | "identity" => body,
        "gzip" => {
            let decoded = courierust::courierust_deflate::gunzip(&body, MAX_MEMORY_BODY)?;
            headers.retain(|(name, _)| {
                !name.eq_ignore_ascii_case("content-encoding")
                    && !name.eq_ignore_ascii_case("content-length")
            });
            decoded
        }
        _ => bail!("Server ignored identity encoding request: {encoding}"),
    };
    Ok((response.status, headers, body))
}
