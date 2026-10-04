//! Minimal Base64 (RFC 4648 §4) decoding, used to unpack PEM certificate
//! bundles configured through `SEGMERIS_EXTRA_CA_FILE`.
//!
//! Only decoding is needed (PEM trust anchors are never written back), so
//! the encoder is deliberately omitted.

/// Decode standard-alphabet Base64, ignoring ASCII whitespace and allowing
/// missing padding (as PEM bodies often wrap lines). Returns `None` for
/// any byte outside the alphabet or a `=` before the end of the input.
pub(crate) fn decode(input: &str) -> Option<Vec<u8>> {
    let mut output = Vec::with_capacity(input.len() / 4 * 3);
    let mut buffer: u32 = 0;
    let mut bits: u32 = 0;
    let mut padding = 0usize;

    for byte in input.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => {
                padding += 1;
                continue;
            }
            b' ' | b'\t' | b'\r' | b'\n' => continue,
            _ => return None,
        };
        // No data may follow a padding character.
        if padding > 0 {
            return None;
        }
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }

    if bits >= 6 || padding > 2 {
        return None;
    }
    Some(output)
}

#[cfg(test)]
mod tests {
    use super::decode;

    /// RFC 4648 §10 test vectors (decode direction).
    #[test]
    fn decodes_rfc4648_vectors() {
        assert_eq!(decode("").unwrap(), b"");
        assert_eq!(decode("Zg==").unwrap(), b"f");
        assert_eq!(decode("Zm8=").unwrap(), b"fo");
        assert_eq!(decode("Zm9v").unwrap(), b"foo");
        assert_eq!(decode("Zm9vYg==").unwrap(), b"foob");
        assert_eq!(decode("Zm9vYmE=").unwrap(), b"fooba");
        assert_eq!(decode("Zm9vYmFy").unwrap(), b"foobar");
    }

    #[test]
    fn tolerates_whitespace_and_missing_padding() {
        assert_eq!(decode("Zm9v\n YmFy\n").unwrap(), b"foobar");
        assert_eq!(decode("Zm9vYg").unwrap(), b"foob");
        assert_eq!(decode("Zm8").unwrap(), b"fo");
    }

    #[test]
    fn rejects_invalid_input() {
        assert_eq!(decode("Zm9v!"), None);
        assert_eq!(decode("Zm=v"), None);
        assert_eq!(decode("===="), None);
        assert_eq!(decode("A"), None);
    }
}
