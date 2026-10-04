//! HMAC-SHA-256 (RFC 2104) built on the local streaming SHA-256.
//!
//! Bilibili's anonymous device bootstrap signs its ticket request with
//! this MAC (key `XgwSnGZ1p`, message `ts<unix-seconds>`), so the
//! implementation is pinned to the RFC 4231 vectors below.

use crate::crypto::sha256::{sha256, Sha256};

/// Computes the HMAC-SHA-256 tag of `message` under `key`.
///
/// Keys longer than the 64-byte block are hashed first, as the RFC
/// requires.
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut key_block = [0u8; 64];
    if key.len() > 64 {
        key_block[..32].copy_from_slice(&sha256(key));
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }

    let mut pad = [0u8; 64];
    for (slot, byte) in pad.iter_mut().zip(key_block.iter()) {
        *slot = byte ^ 0x36;
    }
    let mut inner = Sha256::new();
    inner.update(&pad);
    inner.update(message);
    let inner_digest = inner.finalize();

    for (slot, byte) in pad.iter_mut().zip(key_block.iter()) {
        *slot = byte ^ 0x5c;
    }
    let mut outer = Sha256::new();
    outer.update(&pad);
    outer.update(&inner_digest);
    outer.finalize()
}

#[cfg(test)]
mod tests {
    use super::hmac_sha256;

    #[test]
    fn rfc4231_vectors() {
        // Case 1.
        let tag = hmac_sha256(&[0x0b; 20], b"Hi There");
        assert_eq!(
            tag,
            [
                0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53, 0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b,
                0xf1, 0x2b, 0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7, 0x26, 0xe9, 0x37, 0x6c,
                0x2e, 0x32, 0xcf, 0xf7
            ]
        );
        // Case 2.
        let tag = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(
            tag,
            [
                0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e, 0x6a, 0x04, 0x24, 0x26, 0x08, 0x95,
                0x75, 0xc7, 0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83, 0x9d, 0xec, 0x58, 0xb9,
                0x64, 0xec, 0x38, 0x43
            ]
        );
        // Case 6: 131-byte key, exercising the > block-size path.
        let tag = hmac_sha256(
            &[0xaa; 131],
            b"Test Using Larger Than Block-Size Key - Hash Key First",
        );
        assert_eq!(
            tag,
            [
                0x60, 0xe4, 0x31, 0x59, 0x1e, 0xe0, 0xb6, 0x7f, 0x0d, 0x8a, 0x26, 0xaa, 0xcb, 0xf5,
                0xb7, 0x7f, 0x8e, 0x0b, 0xc6, 0x21, 0x37, 0x28, 0xc5, 0x14, 0x05, 0x46, 0x04, 0x0f,
                0x0e, 0xe3, 0x7f, 0x54
            ]
        );
    }
}
