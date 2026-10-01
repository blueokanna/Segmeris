//! Self-contained cryptographic primitives (SHA-256, AES-128, AES-128-CBC)
//! with no unsafe code and no third-party dependencies: the HLS AES-128
//! segment cipher and the SHA-256 used to verify downloaded binaries are
//! both implemented from scratch so the crate never outgrows its declared
//! MSRV (Rust 1.88).

pub mod aes128;
pub mod aes_cbc;
pub mod sha256;

pub use aes_cbc::{aes_128_cbc_decrypt, AesCbcError};
pub use sha256::{sha256, sha256_hex, Sha256};
