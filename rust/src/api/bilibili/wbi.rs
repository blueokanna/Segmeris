//! Bilibili's `wbi` request signing.
//!
//! The scheme (shared by every web request the Bilibili frontend makes to
//! `api.bilibili.com` since 2023):
//!
//! 1. fetch the rotating `img_key` / `sub_key` pair from the `nav` API
//!    (we get them from `data.wbi_img.img_url` / `sub_url`),
//! 2. mix the two 32-character keys through [`MIXIN_KEY_ENC_TAB`] and keep
//!    the first 32 characters — the *mixin key*,
//! 3. sort the query parameters by name and join them as `k=v`, applying
//!    Bilibili's value encoding (see [`encode_component`]),
//! 4. `w_rid = md5(query + mixin_key)`.
//!
//! The encrypted table and the encoding rules are wire-format facts the
//! server verifies against; the routine work is kept pure so it can be
//! unit tested without a network.

use crate::crypto::md5_hex;

/// Character re-ordering table published as part of the `wbi` wire
/// format. It has exactly 64 entries, one per character of the
/// concatenated `img_key` + `sub_key`.
const MIXIN_KEY_ENC_TAB: [usize; 64] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
    28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25,
    54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

/// Derive the mixin key from an `img_key` / `sub_key` pair.
///
/// Returns `None` when the two keys together are shorter than 64
/// characters (a truncated `nav` response); callers surface that as a
/// signing failure instead of letting an index panic escape.
pub(crate) fn mixin_key(img_key: &str, sub_key: &str) -> Option<String> {
    let combined: Vec<char> = img_key.chars().chain(sub_key.chars()).collect();
    if combined.len() < MIXIN_KEY_ENC_TAB.len() {
        return None;
    }
    Some(
        MIXIN_KEY_ENC_TAB
            .iter()
            .take(32)
            .map(|&index| combined[index])
            .collect(),
    )
}

/// Percent-encode one query component the way the Bilibili frontend does:
/// ASCII alphanumerics and `-_.~` pass through, the four characters
/// `!'()*` are dropped entirely, and everything else (including UTF-8
/// continuation bytes) becomes `%XX`.
pub(crate) fn encode_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(*byte as char);
            }
            b'!' | b'\'' | b'(' | b')' | b'*' => {}
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

/// Sign `params` and return the final query string, ready to append to a
/// URL: sorted parameters, `wts`, then the `w_rid` signature.
pub(crate) fn signed_query(mixin_key: &str, params: &[(String, String)], wts: u64) -> String {
    let mut entries: Vec<(&str, &str)> = params
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_str()))
        .collect();
    let wts_text = wts.to_string();
    entries.push(("wts", wts_text.as_str()));
    entries.sort_by(|left, right| left.0.cmp(right.0));

    let query = entries
        .iter()
        .map(|(name, value)| format!("{}={}", encode_component(name), encode_component(value)))
        .collect::<Vec<_>>()
        .join("&");

    let signature = md5_hex(format!("{query}{mixin_key}").as_bytes());
    format!("{query}&w_rid={signature}")
}

/// Extract the key (file stem) from a `wbi` image URL like
/// `https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png`.
pub(crate) fn key_from_wbi_url(url: &str) -> Option<String> {
    let file = url.rsplit('/').next()?;
    let stem = file.split('.').next()?;
    if stem.is_empty() {
        None
    } else {
        Some(stem.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{encode_component, key_from_wbi_url, mixin_key, signed_query};

    #[test]
    fn mixin_key_uses_the_published_reordering_table() {
        // With `A`×32 + `B`×32 every table slot maps to either `A`
        // (index < 32) or `B`; the expected string is the table's first
        // 32 entries resolved by hand.
        let mixin = mixin_key(&"A".repeat(32), &"B".repeat(32)).expect("keys are long enough");
        assert_eq!(mixin, "BBAABAABABAABABBABABBABAAAABABBA");
        assert_eq!(mixin.len(), 32);
    }

    #[test]
    fn mixin_key_rejects_truncated_keys() {
        assert_eq!(mixin_key("short", "keys"), None);
        assert_eq!(mixin_key(&"A".repeat(63), ""), None);
    }

    #[test]
    fn encode_component_matches_wire_rules() {
        assert_eq!(encode_component("bvid"), "bvid");
        assert_eq!(encode_component("1.2-3_4~5"), "1.2-3_4~5");
        // The four dropped characters.
        assert_eq!(encode_component("a!b'c(d)e*f"), "abcdef");
        // Space, plus, ampersand and UTF-8 are percent-encoded.
        assert_eq!(encode_component("a b"), "a%20b");
        assert_eq!(encode_component("1+1"), "1%2B1");
        assert_eq!(encode_component("a&b=c"), "a%26b%3Dc");
        assert_eq!(encode_component("番剧"), "%E7%95%AA%E5%89%A7");
    }

    #[test]
    fn signed_query_is_order_independent_and_appends_signature() {
        let params_a = vec![
            ("bvid".to_string(), "BV1xx411c7mD".to_string()),
            ("cid".to_string(), "123".to_string()),
        ];
        let params_b = vec![
            ("cid".to_string(), "123".to_string()),
            ("bvid".to_string(), "BV1xx411c7mD".to_string()),
        ];

        let query = signed_query("test-mixin-key", &params_a, 1_700_000_000);
        assert_eq!(
            query,
            signed_query("test-mixin-key", &params_b, 1_700_000_000)
        );
        assert!(query.starts_with("bvid=BV1xx411c7mD&cid=123&wts=1700000000&w_rid="));
        let signature = query.rsplit("w_rid=").next().expect("signature present");
        assert_eq!(signature.len(), 32);
        assert!(signature
            .chars()
            .all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase()));
    }

    #[test]
    fn signed_query_signature_is_md5_of_query_plus_mixin_key() {
        // Cross-checked against an independent MD5 implementation:
        // md5("wts=123key") = "18c37754d587a9a65e1e0022976fce3b".
        let query = signed_query("key", &[], 123);
        assert_eq!(query, "wts=123&w_rid=18c37754d587a9a65e1e0022976fce3b");
    }

    #[test]
    fn key_from_wbi_url_extracts_file_stem() {
        assert_eq!(
            key_from_wbi_url("https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png"),
            Some("7cd084941338484aae1ad9425b84077c".to_string())
        );
        assert_eq!(key_from_wbi_url("https://i0.hdslb.com/bfs/wbi/.png"), None);
        assert_eq!(key_from_wbi_url(""), None);
    }
}
