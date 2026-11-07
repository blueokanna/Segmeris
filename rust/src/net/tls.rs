//! Verified path-building fallback for cross-signed certificate chains.
use anyhow::{Context, Result};
use courierust::courierust_client::TlsSettings;
use rustls::{pki_types::ServerName, ClientConnection, RootCertStore, StreamOwned};
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::Duration;

fn root_store(settings: &TlsSettings) -> Result<RootCertStore> {
    let mut roots = RootCertStore::empty();
    for root in settings.roots.roots() {
        roots
            .add(root.der.clone().into())
            .context("Invalid TLS trust anchor")?;
    }
    Ok(roots)
}

pub(super) fn config(settings: &TlsSettings) -> Result<Arc<rustls::ClientConfig>> {
    let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .with_root_certificates(root_store(settings)?)
    .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

pub(super) fn connect(
    config: Arc<rustls::ClientConfig>,
    host: &str,
    address: SocketAddr,
    connect_timeout: Duration,
    handshake_timeout: Option<Duration>,
    read_timeout: Option<Duration>,
) -> Result<(Arc<TcpStream>, StreamOwned<ClientConnection, TcpStream>)> {
    if !crate::network_policy::address_allowed(address) {
        anyhow::bail!("TLS destination blocked by address policy");
    }
    // Reuse the checked address, never resolve again during TLS fallback.
    let mut tcp = TcpStream::connect_timeout(&address, connect_timeout)?;
    tcp.set_read_timeout(handshake_timeout)?;
    tcp.set_write_timeout(handshake_timeout)?;
    tcp.set_nodelay(true)?;
    let name = ServerName::try_from(host.to_owned()).context("Invalid TLS server name")?;
    let mut connection = ClientConnection::new(config, name)?;
    while connection.is_handshaking() {
        connection
            .complete_io(&mut tcp)
            .context("Verified TLS handshake failed")?;
    }
    tcp.set_read_timeout(read_timeout)?;
    tcp.set_write_timeout(read_timeout)?;
    let handle = Arc::new(tcp.try_clone()?);
    Ok((handle, StreamOwned::new(connection, tcp)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::client::danger::ServerCertVerifier;
    use rustls::client::WebPkiServerVerifier;
    use rustls::pki_types::{CertificateDer, UnixTime};

    #[test]
    fn cross_signed_paths_use_current_roots_and_enforce_identity() {
        let settings = TlsSettings {
            roots: crate::net::default_roots(),
            ..Default::default()
        };
        let verifier = WebPkiServerVerifier::builder_with_provider(
            Arc::new(root_store(&settings).unwrap()),
            Arc::new(rustls::crypto::ring::default_provider()),
        )
        .build()
        .unwrap();
        for (pem, host, captured) in [
            (
                include_bytes!("../../tests/data/hqwx-chain.pem").as_slice(),
                "oss-hqwx-video.hqwx.com",
                1_794_096_000,
            ),
            (
                include_bytes!("../../tests/data/bilibili-chain.pem").as_slice(),
                "api.bilibili.com",
                1_791_072_000,
            ),
        ] {
            let chain: Vec<CertificateDer<'static>> = crate::net::pem_certificates(pem)
                .unwrap()
                .into_iter()
                .map(CertificateDer::from)
                .collect();
            let name = ServerName::try_from(host).unwrap();
            let now = UnixTime::since_unix_epoch(Duration::from_secs(captured));
            verifier
                .verify_server_cert(&chain[0], &chain[1..], &name, &[], now)
                .unwrap();
            let wrong = ServerName::try_from("unrelated.example").unwrap();
            assert!(verifier
                .verify_server_cert(&chain[0], &chain[1..], &wrong, &[], now)
                .is_err());
            let expired = UnixTime::since_unix_epoch(Duration::from_secs(2_524_608_000));
            assert!(verifier
                .verify_server_cert(&chain[0], &chain[1..], &name, &[], expired)
                .is_err());
            let mut tampered = chain[0].as_ref().to_vec();
            *tampered.last_mut().unwrap() ^= 1;
            assert!(verifier
                .verify_server_cert(&tampered.into(), &chain[1..], &name, &[], now)
                .is_err());
            assert!(verifier
                .verify_server_cert(&chain[0], &[], &name, &[], now)
                .is_err());
        }
    }
}
