//! Diagnose HTTP responses through the downloader's production transport.
use anyhow::{bail, Context, Result};
use rust_lib_segmeris::net::SyncHttpClient;

fn main() -> Result<()> {
    let url = std::env::args().nth(1).context("Usage: http_probe <URL>")?;
    let ((status, headers, body), effective) = SyncHttpClient::new()?.get_with_url(&url, &[])?;
    println!(
        "HTTP {status}; {} bytes; host={}",
        body.len(),
        effective.host_str().unwrap_or_default()
    );
    for (name, value) in headers {
        if matches!(name.as_str(), "content-type" | "content-length" | "server") {
            println!("{name}: {value}");
        }
    }
    if !(200..300).contains(&status) {
        bail!("Server returned HTTP {status}");
    }
    Ok(())
}
