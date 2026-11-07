//! Streaming adapter over Courierust's public HTTP and TLS codecs.
//! DNS is resolved once; the checked socket address is the one we connect to.
use anyhow::{bail, Context, Result};
use courierust::courierust_client::ClientConfig;
use courierust::courierust_error::Error;
use courierust::courierust_h1::{self as h1, BodyLen};
use courierust::courierust_http::{
    header::{HeaderName, HeaderValue},
    method::Method,
    request::Request,
    response::Response,
    version::Version,
};
use courierust::courierust_io::{BufReader, Read, Write};
use courierust::courierust_tls::{TlsConnector, TlsStream};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};

enum TlsSocket {
    Courierust(Box<TlsStream<Arc<TcpStream>, Arc<TcpStream>>>),
    Rustls(Box<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>),
}
struct Socket {
    tcp: Arc<TcpStream>,
    tls: Option<TlsSocket>,
    pending: Vec<u8>,
    offset: usize,
}

impl Read for Socket {
    fn read(&mut self, buf: &mut [u8]) -> courierust::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let Some(tls) = &mut self.tls else {
            return self.tcp.read(buf);
        };
        let tls = match tls {
            TlsSocket::Courierust(tls) => tls,
            TlsSocket::Rustls(tls) => {
                return std::io::Read::read(tls, buf).map_err(|e| Error::io(e.to_string()));
            }
        };
        if self.offset == self.pending.len() {
            self.pending = tls.read_record().map_err(|e| Error::io(e.to_string()))?;
            self.offset = 0;
        }
        let n = buf.len().min(self.pending.len() - self.offset);
        buf[..n].copy_from_slice(&self.pending[self.offset..self.offset + n]);
        self.offset += n;
        Ok(n)
    }
}

impl Write for Socket {
    fn write(&mut self, data: &[u8]) -> courierust::Result<usize> {
        match &mut self.tls {
            Some(TlsSocket::Courierust(tls)) => {
                tls.write_all(data).map_err(|e| Error::io(e.to_string()))?;
                Ok(data.len())
            }
            Some(TlsSocket::Rustls(tls)) => {
                std::io::Write::write(tls, data).map_err(|e| Error::io(e.to_string()))
            }
            None => self.tcp.write(data),
        }
    }
    fn flush(&mut self) -> courierust::Result<()> {
        if let Some(TlsSocket::Rustls(tls)) = &mut self.tls {
            return std::io::Write::flush(tls).map_err(|e| Error::io(e.to_string()));
        }
        self.tcp.flush()
    }
}

#[derive(Clone)]
struct SharedSocket(Arc<Mutex<Socket>>);
impl Read for SharedSocket {
    fn read(&mut self, buf: &mut [u8]) -> courierust::Result<usize> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).read(buf)
    }
}
impl Write for SharedSocket {
    fn write(&mut self, data: &[u8]) -> courierust::Result<usize> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).write(data)
    }
    fn flush(&mut self) -> courierust::Result<()> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).flush()
    }
}
struct Reader {
    input: BufReader<SharedSocket>,
    socket: SharedSocket,
}
impl Reader {
    fn get_mut(&mut self) -> &mut SharedSocket {
        &mut self.socket
    }
}
impl std::ops::Deref for Reader {
    type Target = BufReader<SharedSocket>;
    fn deref(&self) -> &Self::Target {
        &self.input
    }
}
impl std::ops::DerefMut for Reader {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.input
    }
}
type Pool = Arc<Mutex<Vec<(String, Reader)>>>;

#[derive(Clone)]
pub(super) struct Client {
    config: ClientConfig,
    tls: Option<TlsConnector>,
    pool: Pool,
}

impl Client {
    pub fn with_config(config: ClientConfig) -> Self {
        let tls = config.tls.as_ref().map(|t| {
            TlsConnector::new(courierust::courierust_tls::ClientConfig {
                roots: t.roots.clone(),
                verify: t.verify,
                alpn: t.alpn.clone(),
                now: t.now,
                min_version: t.min_version,
                max_version: t.max_version,
                identity: t.identity.clone(),
                profile: t.profile.clone(),
            })
        });
        Self {
            config,
            tls,
            pool: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub fn execute(
        &self,
        raw: &str,
        mut request: Request<courierust::courierust_body::Body>,
    ) -> Result<Response<ResponseBody>> {
        let url = url::Url::parse(raw)?;
        let host = url.host().context("URL has no host")?.to_string();
        let host = host.trim_matches(['[', ']']);
        let port = url.port_or_known_default().context("URL has no port")?;
        let addresses: Vec<_> = (host, port).to_socket_addrs()?.collect();
        crate::network_policy::validate_addresses(
            &addresses,
            crate::network_policy::public_only(),
        )?;
        let key = url.origin().ascii_serialization();
        let pooled = {
            let mut pool = self.pool.lock().unwrap_or_else(|e| e.into_inner());
            pool.iter()
                .position(|(origin, _)| origin == &key)
                .map(|i| pool.swap_remove(i).1)
        };
        let connect = || -> Result<Reader> {
            let mut last_error = None;
            for addr in &addresses {
                let mut tcp = match TcpStream::connect_timeout(
                    addr,
                    self.config
                        .connect_timeout
                        .unwrap_or(std::time::Duration::from_secs(10)),
                ) {
                    Ok(tcp) => Arc::new(tcp),
                    Err(e) => {
                        last_error = Some(e);
                        continue;
                    }
                };
                tcp.set_read_timeout(self.config.handshake_timeout)?;
                tcp.set_write_timeout(self.config.read_timeout)?;
                tcp.set_nodelay(true)?;
                let tls = if url.scheme() == "https" {
                    let mut settings = self
                        .tls
                        .as_ref()
                        .context("TLS is not configured")?
                        .config()
                        .clone();
                    settings.now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)?
                        .as_secs()
                        .try_into()?;
                    let connector = TlsConnector::new(settings);
                    let stream = match connector.connect(host, tcp.clone(), tcp.clone()) {
                        Ok(stream) => TlsSocket::Courierust(Box::new(stream)),
                        Err(courierust::courierust_tls::TlsError::Certificate(reason))
                            if reason == "no trusted root found" =>
                        {
                            let config = super::tls::config(
                                self.config.tls.as_ref().context("TLS is not configured")?,
                            )?;
                            let (handle, stream) = super::tls::connect(
                                config,
                                host,
                                *addr,
                                self.config
                                    .connect_timeout
                                    .unwrap_or(std::time::Duration::from_secs(10)),
                                self.config.handshake_timeout,
                                self.config.read_timeout,
                            )?;
                            tcp = handle;
                            TlsSocket::Rustls(Box::new(stream))
                        }
                        Err(error) => return Err(anyhow::anyhow!("TLS handshake failed: {error}")),
                    };
                    Some(stream)
                } else {
                    None
                };
                tcp.set_read_timeout(self.config.read_timeout)?;
                let socket = SharedSocket(Arc::new(Mutex::new(Socket {
                    tcp,
                    tls,
                    pending: Vec::new(),
                    offset: 0,
                })));
                return Ok(Reader {
                    input: BufReader::new(socket.clone(), 64 * 1024),
                    socket,
                });
            }
            Err(last_error.context("No usable network address")?.into())
        };
        let mut path = url.path().to_owned();
        if let Some(query) = url.query() {
            path.push('?');
            path.push_str(query);
        }
        request.uri = courierust::courierust_http::uri::PathAndQuery::from_bytes(path.as_bytes())?;
        let authority = &url[url::Position::BeforeHost..url::Position::AfterPort];
        request.headers.insert(
            HeaderName::from_lowercase("host"),
            HeaderValue::from_bytes(authority.as_bytes())?,
        );
        if !request.headers.contains_key("user-agent") {
            request.headers.insert(
                HeaderName::from_lowercase("user-agent"),
                HeaderValue::from_bytes(
                    concat!("Segmeris/", env!("CARGO_PKG_VERSION")).as_bytes(),
                )?,
            );
        }
        let mut wire = Vec::new();
        h1::write_request_head(
            &mut wire,
            &Method::GET,
            &request.uri,
            Version::HTTP_11,
            &request.headers,
        )?;
        let send = |reader: &mut Reader| -> Result<_> {
            reader.get_mut().write_all(&wire)?;
            reader.get_mut().flush()?;
            for _ in 0..16 {
                let line = reader.read_until(b'\n', 16 * 1024)?;
                let (status, version) = h1::parse_status_line(&line)?;
                let headers = h1::read_headers(reader)?;
                if status.is_informational() {
                    continue;
                }
                return Ok((status, version, headers));
            }
            bail!("Too many informational responses")
        };
        // A client can outlive API policy initialization. A pooled connection
        // must satisfy the current policy even if today's DNS answer is public.
        if let Some(reader) = &pooled {
            let socket = reader.socket.0.lock().unwrap_or_else(|e| e.into_inner());
            if !crate::network_policy::address_allowed(socket.tcp.peer_addr()?) {
                bail!("Pooled network destination blocked by address policy");
            }
        }
        let reused = pooled.is_some();
        let mut reader = match pooled {
            Some(reader) => reader,
            None => connect()?,
        };
        let (status, version, headers) = match send(&mut reader) {
            Ok(head) => head,
            Err(_) if reused => {
                reader = connect()?;
                send(&mut reader)?
            }
            Err(e) => return Err(e),
        };
        let framing = h1::body_length(&headers, Some(&Method::GET), Some(status))?;
        let reusable = version == Version::HTTP_11
            && !h1::wants_close(&headers)
            && !matches!(framing, BodyLen::None);
        let body = ResponseBody {
            reader: Some(reader),
            framing,
            chunk_left: 0,
            needs_crlf: false,
            done: status.as_u16() == 204 || status.as_u16() == 304,
            pool: self.pool.clone(),
            key,
            reusable,
        };
        Ok(Response {
            status,
            version,
            headers,
            body,
            trailers: None,
        })
    }
}

pub(crate) struct ResponseBody {
    reader: Option<Reader>,
    framing: BodyLen,
    chunk_left: usize,
    needs_crlf: bool,
    done: bool,
    pool: Pool,
    key: String,
    reusable: bool,
}

impl ResponseBody {
    pub fn next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        crate::download_control::checkpoint()?;
        if self.done {
            return Ok(None);
        }
        let reader = self.reader.as_mut().context("Response already consumed")?;
        let mut bytes = vec![0; 64 * 1024];
        let n = match &mut self.framing {
            BodyLen::Length(left) => {
                let n = (*left).min(bytes.len());
                reader.read_exact_into(&mut bytes[..n])?;
                *left -= n;
                n
            }
            BodyLen::None => {
                // read_more treats EOF as an error and can consume bytes before
                // reporting it. For a close-delimited response, clean EOF is
                // the framing boundary; return each buffered slice first.
                let buffered = reader.fill_buf()?;
                let n = buffered.len().min(bytes.len());
                bytes[..n].copy_from_slice(&buffered[..n]);
                reader.consume(n);
                n
            }
            BodyLen::Chunked => {
                if self.chunk_left == 0 {
                    if self.needs_crlf && reader.read_exact(2)? != b"\r\n" {
                        bail!("Invalid chunk terminator");
                    }
                    let line = reader.read_until(b'\n', 8192)?;
                    let line = line.strip_suffix(b"\r\n").context("Invalid chunk line")?;
                    let digits = line.split(|b| *b == b';').next().unwrap_or_default();
                    let digits = std::str::from_utf8(digits)?.trim_end_matches([' ', '\t']);
                    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
                        bail!("Invalid chunk size");
                    }
                    self.chunk_left = usize::from_str_radix(digits, 16)?;
                    if self.chunk_left == 0 {
                        let mut total = 0;
                        loop {
                            let line = reader.read_until(b'\n', 8192)?;
                            total += line.len();
                            if total > 65536 {
                                bail!("HTTP trailers exceed limit");
                            }
                            if line == b"\r\n" {
                                break;
                            }
                        }
                        self.done = true;
                        return Ok(None);
                    }
                    self.needs_crlf = true;
                }
                let n = self.chunk_left.min(bytes.len());
                reader.read_exact_into(&mut bytes[..n])?;
                self.chunk_left -= n;
                n
            }
        };
        if n == 0 {
            self.done = true;
            return Ok(None);
        }
        bytes.truncate(n);
        Ok(Some(bytes))
    }

    pub fn collect_limited(mut self, limit: usize) -> Result<Vec<u8>> {
        if matches!(self.framing, BodyLen::Length(n) if n > limit) {
            bail!("HTTP body exceeds memory limit");
        }
        let mut data = Vec::new();
        while let Some(bytes) = self.next_chunk()? {
            if bytes.len() > limit.saturating_sub(data.len()) {
                bail!("HTTP body exceeds memory limit");
            }
            data.extend_from_slice(&bytes);
        }
        Ok(data)
    }
}

impl Drop for ResponseBody {
    fn drop(&mut self) {
        if self.done && self.reusable {
            if let Some(reader) = self.reader.take() {
                let mut pool = self.pool.lock().unwrap_or_else(|e| e.into_inner());
                if pool.len() < 32 && pool.iter().filter(|(key, _)| key == &self.key).count() < 8 {
                    pool.push((self.key.clone(), reader));
                }
            }
        }
    }
}
