//! Self-contained cryptographic primitives (SHA-256, MD5, AES-128,
//! AES-128-CBC, HMAC-SHA-256, MurmurHash3) with no unsafe code and no
//! third-party dependencies: the HLS AES-128 segment cipher, the SHA-256
//! used to verify downloaded binaries, the MD5 behind Bilibili's WBI
//! request signing, and the HMAC/MurmurHash3 pair behind Bilibili's
//! anonymous device bootstrap are all implemented from scratch so the
//! crate never outgrows its declared MSRV (Rust 1.88).

pub mod aes128;
pub mod aes_cbc;
pub mod base64;
pub mod hmac;
pub mod md5;
pub mod murmur3;
pub mod sha256;

pub use aes_cbc::{aes_128_cbc_decrypt, AesCbcError};
pub use hmac::hmac_sha256;
pub use md5::{md5, md5_hex, Md5};
pub use murmur3::murmur3_x64_128;
pub use sha256::{sha256, sha256_hex, Sha256};
