//! HTTP API server backed by `courierust_server`.
//!
//! Exposes a small REST API for queueing and inspecting media
//! downloads. Unlike the previous `warp`/tokio implementation, the
//! handler is synchronous: `courierust_server` dispatches each request
//! to a worker thread, and long-running download tasks run on their own
//! dedicated threads so the accept loop is never blocked.

use anyhow::{anyhow, bail, Context, Result};
use courierust::courierust_body::Body;
use courierust::courierust_http::header::HeaderName;
use courierust::courierust_http::request::Request;
use courierust::courierust_http::response::Response;
use courierust::courierust_http::status::StatusCode;
use courierust::courierust_server::Server;
use std::net::ToSocketAddrs;
use uuid::Uuid;

use crate::api::downloader::RequestContext;

mod download;
mod models;
mod storage;

pub use models::{ApiRequestContext, DownloadRequest, DownloadStatus};

use self::storage::TaskStore;

/// Maximum request body accepted by the API (defense in depth; the
/// server config also bounds it).
const MAX_REQUEST_BODY: usize = 1024 * 1024;

/// Optional bearer token read from `FERRISLOAD_API_TOKEN`.
///
/// When set, every endpoint except `GET /health` requires
/// `Authorization: Bearer <token>`. This keeps a Docker deployment that
/// forwards/publishes port 3000 from acting as an open download proxy for
/// anyone on the network.
fn configured_api_token() -> Option<&'static str> {
    static TOKEN: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    TOKEN
        .get_or_init(|| {
            std::env::var("FERRISLOAD_API_TOKEN")
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
        .as_deref()
}

/// Whether the request carries the configured bearer token (or no token is
/// required at all).
fn request_authorized(request: &Request<Body>) -> bool {
    let Some(expected) = configured_api_token() else {
        return true;
    };
    let provided = request
        .headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    let expected_header = format!("Bearer {expected}");
    // Compare every byte of equal-length tokens without an early mismatch exit.
    provided.len() == expected_header.len()
        && provided
            .bytes()
            .zip(expected_header.bytes())
            .fold(0u8, |diff, (left, right)| diff | (left ^ right))
            == 0
}

/// Whether `FERRISLOAD_ALLOW_PRIVATE_NETWORKS` explicitly permits
/// private/loopback/link-local targets (legitimate local-network media
/// servers such as a NAS).
fn allow_private_networks() -> bool {
    std::env::var("FERRISLOAD_ALLOW_PRIVATE_NETWORKS")
        .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// SSRF guard for the network-exposed API server.
///
/// Accepts only `http`/`https` URLs whose host does not resolve to a
/// private / loopback / link-local / reserved address. Without this, a
/// client on the LAN could make the container probe or download
/// internal-only services (cloud metadata endpoints, the Docker network,
/// the host loopback). Set `FERRISLOAD_ALLOW_PRIVATE_NETWORKS=1` to opt out
/// for local-network media sources.
pub(crate) fn validate_public_http_url(url: &str) -> Result<()> {
    let parsed = url::Url::parse(url).with_context(|| format!("Invalid URL: {url}"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        bail!("Only http/https URLs are allowed: {url}");
    }
    if allow_private_networks() {
        return Ok(());
    }
    if let Some(host) = parsed.host() {
        let ip = match host {
            url::Host::Ipv4(ip) => Some(ip.into()),
            url::Host::Ipv6(ip) => Some(ip.into()),
            _ => None,
        };
        if let Some(ip) = ip {
            if is_private_ip(ip) {
                bail!("Refusing private/loopback network target");
            }
            return Ok(());
        }
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow!("URL has no host: {url}"))?;

    // Hostname: resolve and reject any private address (best effort; the
    // network layer also checks the actual address immediately before connecting).
    let port = parsed.port_or_known_default().context("URL has no port")?;
    let addresses: Vec<_> = (host, port)
        .to_socket_addrs()
        .with_context(|| format!("Failed to resolve host: {host}"))?
        .collect();
    crate::network_policy::validate_addresses(&addresses, true)
}

use crate::network_policy::is_private_ip;

/// Bind and serve the API forever (blocking).
pub fn run_server() -> std::io::Result<()> {
    crate::network_policy::enable_api_policy();
    let tasks = TaskStore::new();

    let host = std::env::var("API_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port = std::env::var("API_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(3000);
    let bind_ip = host
        .parse::<std::net::IpAddr>()
        .unwrap_or(std::net::IpAddr::from([0, 0, 0, 0]));

    let config = courierust::courierust_server::ServerConfig {
        max_body: MAX_REQUEST_BODY,
        http2: true,
        ..Default::default()
    };
    let server = Server::bind_with_config((bind_ip, port), config)?;
    let bound = server.local_addr()?;
    log::info!("Segmeris API listening on http://{}", bound);

    if configured_api_token().is_some() {
        log::info!("Segmeris API authentication is enabled (FERRISLOAD_API_TOKEN)");
    }

    server.serve(move |request: Request<Body>| handle_request(request, &tasks))
}

fn handle_request(request: Request<Body>, tasks: &TaskStore) -> Response<Body> {
    let method = request.method.as_str().to_ascii_uppercase();
    let path = request.uri.path().to_string();

    // CORS preflight: browsers send OPTIONS before a cross-origin request
    // that carries a non-simple header (`content-type`, `authorization`).
    // It must succeed (2xx) with the allow lists or the browser blocks the
    // actual request — this is what makes the web build able to talk to the
    // API server at all.
    let mut response = if method == "OPTIONS" {
        json_response(StatusCode::NO_CONTENT, "")
    } else if path == "/health" && method == "GET" {
        // Health checks (Docker HEALTHCHECK / orchestrator probes) stay open
        // so the container liveness probe works even with a token configured.
        handle_health()
    } else if !request_authorized(&request) {
        json_response(StatusCode::UNAUTHORIZED, r#"{"error":"Unauthorized"}"#)
    } else if method == "POST" && path == "/inspect" {
        handle_inspect(request)
    } else if method == "POST" && path == "/download" {
        handle_download(request, tasks)
    } else if method == "POST" && path.starts_with("/tasks/") {
        let parts: Vec<_> = path.trim_start_matches("/tasks/").split('/').collect();
        match parts.as_slice() {
            [id, "pause"] => handle_pause(id, true, tasks),
            [id, "resume"] => handle_pause(id, false, tasks),
            _ => json_response(StatusCode::NOT_FOUND, r#"{"error":"Not found"}"#),
        }
    } else if method == "GET" && path == "/tasks" {
        handle_list(tasks)
    } else if method == "GET" && path.starts_with("/status/") {
        let task_id = path.trim_start_matches("/status/").to_string();
        handle_status(task_id, tasks)
    } else {
        json_response(StatusCode::NOT_FOUND, r#"{"error":"Not found"}"#)
    };

    // CORS: allow browser clients from any origin for this local service.
    // The `authorization` header must be listed so the optional bearer token
    // survives the preflight. A token header (not cookies) keeps
    // `Access-Control-Allow-Origin: *` safe.
    response = response.header(
        HeaderName::from_lowercase("access-control-allow-origin"),
        "*",
    );
    response = response.header(
        HeaderName::from_lowercase("access-control-allow-methods"),
        "GET, POST, OPTIONS",
    );
    response = response.header(
        HeaderName::from_lowercase("access-control-allow-headers"),
        "content-type, authorization",
    );
    // JSON content type on every payload-bearing response (a 204 preflight is
    // bodyless; the header is harmless there too).
    response = response.header(
        HeaderName::from_lowercase("content-type"),
        "application/json",
    );
    response
}

fn handle_pause(id: &str, paused: bool, tasks: &TaskStore) -> Response<Body> {
    let Some(task) = tasks.get(id) else {
        return json_response(StatusCode::NOT_FOUND, r#"{"error":"Task not found"}"#);
    };
    if !matches!(task.status.as_str(), "running" | "paused")
        || !crate::download_control::set_paused(id, paused)
    {
        return json_response(StatusCode::CONFLICT, r#"{"error":"Task is not active"}"#);
    }
    tasks.update_progress(
        id,
        if paused { "paused" } else { "resuming" },
        if paused {
            "Download paused"
        } else {
            "Resuming download"
        },
        task.progress_percent,
        None,
    );
    json_response(StatusCode::OK, r#"{"ok":true}"#)
}

fn handle_health() -> Response<Body> {
    json_response(
        StatusCode::OK,
        r#"{"status":"ok","service":"segmeris-api"}"#,
    )
}

/// `POST /inspect` — run the analysis pipeline and return the candidate list.
/// Used by the web client, which cannot embed the Rust engine in a browser.
fn handle_inspect(request: Request<Body>) -> Response<Body> {
    let body = match request.body.collect_limited(MAX_REQUEST_BODY) {
        Ok(bytes) => bytes,
        Err(error) => {
            let message = format!(r#"{{"error":"{}"}}"#, escape_json(&error.to_string()));
            return json_response(StatusCode::BAD_REQUEST, &message);
        }
    };
    let req: models::InspectRequest = match nextjson::from_slice(&body) {
        Ok(parsed) => parsed,
        Err(error) => {
            let message = format!(
                r#"{{"error":"Invalid JSON body: {}"}}"#,
                escape_json(&error.to_string())
            );
            return json_response(StatusCode::BAD_REQUEST, &message);
        }
    };
    if req.url.trim().is_empty() {
        return json_response(StatusCode::BAD_REQUEST, r#"{"error":"url is required"}"#);
    }
    // SSRF guard: the API is network-exposed; refuse private targets.
    if let Err(error) = validate_public_http_url(&req.url) {
        let message = format!(r#"{{"error":"{}"}}"#, escape_json(&format!("{error:#}")));
        return json_response(StatusCode::BAD_REQUEST, &message);
    }

    let request_context: RequestContext = req.request_context.unwrap_or_default().into();
    match crate::api::downloader::inspect_media_with_context_sync(req.url, request_context) {
        Ok(result) => {
            let response: models::InspectionResponse = (&result).into();
            match nextjson::to_string(&response) {
                Ok(payload) => json_response(StatusCode::OK, &payload),
                Err(error) => {
                    let message = format!(r#"{{"error":"{}"}}"#, escape_json(&error.to_string()));
                    json_response(StatusCode::INTERNAL_SERVER_ERROR, &message)
                }
            }
        }
        Err(error) => {
            let message = format!(r#"{{"error":"{}"}}"#, escape_json(&format!("{error:#}")));
            json_response(StatusCode::BAD_REQUEST, &message)
        }
    }
}

fn handle_download(request: Request<Body>, tasks: &TaskStore) -> Response<Body> {
    // Read and bound the request body.
    let body = match request.body.collect_limited(MAX_REQUEST_BODY) {
        Ok(bytes) => bytes,
        Err(error) => {
            let message = format!(r#"{{"error":"{}"}}"#, escape_json(&error.to_string()));
            return json_response(StatusCode::BAD_REQUEST, &message);
        }
    };
    let req: DownloadRequest = match nextjson::from_slice(&body) {
        Ok(parsed) => parsed,
        Err(error) => {
            let message = format!(
                r#"{{"error":"Invalid JSON body: {}"}}"#,
                escape_json(&error.to_string())
            );
            return json_response(StatusCode::BAD_REQUEST, &message);
        }
    };
    if req.url.trim().is_empty() {
        return json_response(StatusCode::BAD_REQUEST, r#"{"error":"url is required"}"#);
    }

    let task_id = Uuid::new_v4().to_string();
    tasks.insert_queued(task_id.clone(), req.url.clone());

    let background_tasks = tasks.clone();
    let background_request = req.clone();
    let background_task_id = task_id.clone();
    std::thread::Builder::new()
        .name("segmeris-download".into())
        .spawn(move || {
            download::run_download_task(background_task_id, background_request, background_tasks);
        })
        .expect("failed to spawn download thread");

    let payload = format!(
        r#"{{"task_id":"{}","status":"accepted","message":"Download task accepted"}}"#,
        task_id
    );
    json_response(StatusCode::ACCEPTED, &payload)
}

fn handle_status(task_id: String, tasks: &TaskStore) -> Response<Body> {
    match tasks.get(&task_id) {
        Some(status) => match nextjson::to_string(&status) {
            Ok(payload) => json_response(StatusCode::OK, &payload),
            Err(error) => {
                let message = format!(r#"{{"error":"{}"}}"#, escape_json(&error.to_string()));
                json_response(StatusCode::INTERNAL_SERVER_ERROR, &message)
            }
        },
        None => {
            let payload = format!(
                r#"{{"error":"Task not found","task_id":"{}"}}"#,
                escape_json(&task_id)
            );
            json_response(StatusCode::NOT_FOUND, &payload)
        }
    }
}

fn handle_list(tasks: &TaskStore) -> Response<Body> {
    match nextjson::to_string(&tasks.list()) {
        Ok(payload) => json_response(StatusCode::OK, &payload),
        Err(error) => {
            let message = format!(r#"{{"error":"{}"}}"#, escape_json(&error.to_string()));
            json_response(StatusCode::INTERNAL_SERVER_ERROR, &message)
        }
    }
}

fn json_response(status: StatusCode, payload: &str) -> Response<Body> {
    let mut response = Response::with_status(status);
    response.body = Body::Bytes(payload.as_bytes().to_vec().into());
    response
}

/// Escape a string for safe embedding inside a JSON string literal.
fn escape_json(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}
