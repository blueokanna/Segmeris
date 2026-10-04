//! MD5 (RFC 1321) implemented from scratch for Bilibili's WBI request
//! signing.
//!
//! This is deliberately *not* a security primitive: the algorithm is
//! cryptographically broken and is used here only because Bilibili's
//! `w_rid` query parameter is defined as `md5(query + mixin_key)`. Keeping
//! it in-tree (like the SHA-256 and AES modules) avoids pulling a new
//! dependency that only exists for a compatibility signature.

#![allow(clippy::unreadable_literal)]

/// Per-round left-rotation schedule (RFC 1321 §3.4).
const SHIFT: [u32; 64] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

/// Additive constants `floor(2^32 * abs(sin(i + 1)))` (RFC 1321 §3.4).
const SINE: [u32; 64] = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

/// Streaming MD5 state.
#[derive(Clone)]
pub struct Md5 {
    state: [u32; 4],
    buffer: [u8; 64],
    buffered: usize,
    length: u64,
}

impl Default for Md5 {
    fn default() -> Self {
        Self::new()
    }
}

impl Md5 {
    /// A fresh hasher with the RFC 1321 initial state.
    pub fn new() -> Self {
        Self {
            state: [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476],
            buffer: [0; 64],
            buffered: 0,
            length: 0,
        }
    }

    /// Feed bytes into the hash.
    pub fn update(&mut self, mut data: &[u8]) {
        self.length = self.length.wrapping_add(data.len() as u64);

        if self.buffered > 0 {
            let take = (64 - self.buffered).min(data.len());
            self.buffer[self.buffered..self.buffered + take].copy_from_slice(&data[..take]);
            self.buffered += take;
            data = &data[take..];
            if self.buffered == 64 {
                let block = self.buffer;
                self.compress(&block);
                self.buffered = 0;
            }
        }

        while data.len() >= 64 {
            let mut block = [0u8; 64];
            block.copy_from_slice(&data[..64]);
            self.compress(&block);
            data = &data[64..];
        }

        if !data.is_empty() {
            self.buffer[..data.len()].copy_from_slice(data);
            self.buffered = data.len();
        }
    }

    /// Finalize and return the 16-byte digest.
    pub fn finalize(mut self) -> [u8; 16] {
        let bit_length = self.length.wrapping_mul(8);
        self.update(&[0x80]);
        // Pad with zeroes until 56 bytes mod 64, then append the length.
        while self.buffered != 56 {
            self.update(&[0]);
        }
        self.update(&bit_length.to_le_bytes());

        let mut digest = [0u8; 16];
        for (index, word) in self.state.iter().enumerate() {
            digest[index * 4..index * 4 + 4].copy_from_slice(&word.to_le_bytes());
        }
        digest
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let mut words = [0u32; 16];
        for (index, word) in words.iter_mut().enumerate() {
            let base = index * 4;
            *word = u32::from_le_bytes([
                block[base],
                block[base + 1],
                block[base + 2],
                block[base + 3],
            ]);
        }

        let [mut a, mut b, mut c, mut d] = self.state;

        for step in 0..64 {
            let (mix, word) = match step / 16 {
                0 => ((b & c) | (!b & d), step),
                1 => ((d & b) | (!d & c), (5 * step + 1) % 16),
                2 => (b ^ c ^ d, (3 * step + 5) % 16),
                _ => (c ^ (b | !d), (7 * step) % 16),
            };
            let rotated = a
                .wrapping_add(mix)
                .wrapping_add(SINE[step])
                .wrapping_add(words[word])
                .rotate_left(SHIFT[step]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(rotated);
        }

        self.state[0] = self.state[0].wrapping_add(a);
        self.state[1] = self.state[1].wrapping_add(b);
        self.state[2] = self.state[2].wrapping_add(c);
        self.state[3] = self.state[3].wrapping_add(d);
    }
}

/// One-shot MD5 over a byte slice.
pub fn md5(data: &[u8]) -> [u8; 16] {
    let mut hasher = Md5::new();
    hasher.update(data);
    hasher.finalize()
}

/// Lowercase hexadecimal MD5 digest.
pub fn md5_hex(data: &[u8]) -> String {
    let mut output = String::with_capacity(32);
    for byte in md5(data) {
        output.push_str(&format!("{byte:02x}"));
    }
    output
}

#[cfg(test)]
mod tests {
    use super::{md5, md5_hex, Md5};

    /// RFC 1321 Appendix A.5 test suite.
    const RFC1321_SUITE: [(&str, &str); 7] = [
        ("", "d41d8cd98f00b204e9800998ecf8427e"),
        ("a", "0cc175b9c0f1b6a831c399e269772661"),
        ("abc", "900150983cd24fb0d6963f7d28e17f72"),
        ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
        (
            "abcdefghijklmnopqrstuvwxyz",
            "c3fcd3d76192e4007dfb496cca67e13b",
        ),
        (
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            "d174ab98d277d9f5a5611c2c9f419d9f",
        ),
        (
            "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
            "57edf4a22be3c955ac49da2e2107b67a",
        ),
    ];

    #[test]
    fn matches_rfc1321_vectors() {
        for (input, expected) in RFC1321_SUITE {
            assert_eq!(md5_hex(input.as_bytes()), expected, "input: {input:?}");
        }
    }

    #[test]
    fn streaming_updates_match_one_shot() {
        let payload: Vec<u8> = (0..4096u32).map(|value| (value % 251) as u8).collect();

        for chunk_size in [1usize, 7, 63, 64, 65, 128, 1000] {
            let mut hasher = Md5::new();
            for chunk in payload.chunks(chunk_size) {
                hasher.update(chunk);
            }
            assert_eq!(
                hasher.finalize(),
                md5(&payload),
                "chunk size {chunk_size} diverged"
            );
        }
    }

    #[test]
    fn block_boundaries_are_padded_correctly() {
        // 55/56/57 and 119/120 bytes hit every padding branch (one byte short
        // of the length field, exactly at it, and one past it).
        for length in [0usize, 55, 56, 57, 63, 64, 65, 119, 120, 121, 128] {
            let payload = vec![0xA5u8; length];
            let mut hasher = Md5::new();
            for chunk in payload.chunks(3) {
                hasher.update(chunk);
            }
            assert_eq!(hasher.finalize(), md5(&payload), "length {length}");
        }
    }
}
