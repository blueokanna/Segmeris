//! API egress policy, enforced on the resolved address used for the connection.
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};

static PUBLIC_ONLY: AtomicBool = AtomicBool::new(false);

pub(crate) fn enable_api_policy() {
    let allow = std::env::var("FERRISLOAD_ALLOW_PRIVATE_NETWORKS")
        .is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true"));
    PUBLIC_ONLY.store(!allow, Ordering::SeqCst);
}

pub(crate) fn public_only() -> bool {
    PUBLIC_ONLY.load(Ordering::SeqCst)
}
pub(crate) fn address_allowed(address: SocketAddr) -> bool {
    !public_only() || !is_private_ip(address.ip())
}

/// Reject the complete DNS answer if any address is unsafe. Callers connect
/// directly to these addresses, without resolving the hostname a second time.
pub(crate) fn validate_addresses(
    addresses: &[SocketAddr],
    public_only: bool,
) -> anyhow::Result<()> {
    if addresses.is_empty() {
        anyhow::bail!("Network destination resolved to no addresses");
    }
    if public_only && addresses.iter().any(|address| is_private_ip(address.ip())) {
        anyhow::bail!("Network destination blocked by address policy");
    }
    Ok(())
}

pub(crate) fn is_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_documentation()
                || o[0] == 0
                || (o[0] == 100 && o[1] & 0xc0 == 0x40)
                || (o[0] == 192 && o[1] == 0 && o[2] == 0)
                || (o[0] == 198 && o[1] & 0xfe == 18)
                || o[0] >= 224
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_private_ip(IpAddr::V4(v4));
            }
            let s = v6.segments();
            s[0] & 0xe000 != 0x2000
                || s[0] == 0x2002
                || (s[0] == 0x2001 && (s[1] < 0x200 || s[1] == 0xdb8))
                || (s[0] == 0x3fff && s[1] < 0x1000)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mapped_and_special_addresses_are_not_public() {
        for value in [
            "::ffff:127.0.0.1",
            "::ffff:10.1.2.3",
            "::ffff:169.254.169.254",
            "::ffff:172.16.0.1",
            "::ffff:192.168.1.1",
            "::ffff:0.0.0.0",
            "::ffff:100.64.0.1",
            "::ffff:224.0.0.1",
            "::1",
            "64:ff9b::7f00:1",
            "2002:7f00:1::",
            "2001:db8::1",
            "100.64.0.1",
            "198.18.0.1",
        ] {
            assert!(is_private_ip(value.parse().unwrap()), "{value}");
        }
        for value in ["8.8.8.8", "::ffff:8.8.8.8", "2606:4700:4700::1111"] {
            assert!(!is_private_ip(value.parse().unwrap()), "{value}");
        }
    }

    #[test]
    fn rejects_empty_and_mixed_dns_answers() {
        let public = "8.8.8.8:443".parse().unwrap();
        let private = "[::ffff:127.0.0.1]:443".parse().unwrap();
        assert!(validate_addresses(&[], false).is_err());
        assert!(validate_addresses(&[public], true).is_ok());
        assert!(validate_addresses(&[public, private], true).is_err());
        assert!(validate_addresses(&[private, public], true).is_err());
        assert!(validate_addresses(&[private], false).is_ok());
    }
}
