//! Bilibili's own web QR-code login, driven straight from the passport API.
//!
//! The app needs the *user's* session for everything an anonymous request
//! cannot reach: higher tiers, membership episodes, subtitle tracks. That
//! session belongs to the account holder, so the honest way to get it is the
//! way the website does — show a QR code, let the user confirm it in the
//! Bilibili app, and keep the cookies the server issues in return.
//!
//! That is all this module does: two passport endpoints (`qrcode/generate`
//! and `qrcode/poll`) plus the cookie plumbing between them. Nothing is
//! derived, guessed or shared: an account that cannot watch a video still
//! cannot download it after logging in, and that is the point.
//!
//! Starting an attempt also collects Bilibili's device cookies (`buvid3` /
//! `b_nut`) from the homepage and carries them through every poll, because
//! that is what a browser does and the endpoint's risk control is measurably
//! friendlier to a client that keeps them.

use std::time::Duration;

use anyhow::{bail, Context, Result};
use nextjson::Value;

use crate::api::downloader::{request_headers, RequestContext};
use crate::net::SyncHttpClient;

const PASSPORT_BASE: &str = "https://passport.bilibili.com";
const QR_GENERATE_PATH: &str = "/x/passport-login/web/qrcode/generate";
const QR_POLL_PATH: &str = "/x/passport-login/web/qrcode/poll";

/// Cookie names a Bilibili request actually needs. Anything else the passport
/// endpoint sets (`b_lsid`, `buvid_fp`, …) is dropped: forwarding cookies
/// nothing asked for is how a session leaks into unrelated requests.
const SESSION_COOKIE_NAMES: &[&str] = &[
    "SESSDATA",
    "bili_jct",
    "DedeUserID",
    "DedeUserID__ckMd5",
    "sid",
    "buvid3",
    "buvid4",
    "b_nut",
];

/// A QR-code login attempt: what to render, and the key the poll needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct QrLoginSession {
    /// The URL to draw as a QR code — the same one Bilibili's login page
    /// encodes.
    pub url: String,
    /// Opaque key identifying this attempt to the poll endpoint.
    pub key: String,
    /// Device cookies to send with every poll (see the module docs).
    pub cookie: String,
}

/// State of one poll, mapped from the endpoint's own status codes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum QrLoginState {
    /// `86101` — nobody has scanned the code yet.
    Waiting,
    /// `86090` — scanned; the user still has to confirm on their phone.
    Scanned,
    /// `0` — confirmed, and `cookie` is the session.
    Confirmed { cookie: String },
    /// `86038` — the code expired; start a new attempt.
    Expired,
    /// Any other code, reported verbatim instead of reinterpreted.
    Failed(String),
}

pub(crate) struct QrLoginApi {
    http: SyncHttpClient,
    headers: Vec<(String, String)>,
}

impl QrLoginApi {
    pub(crate) fn new(request_context: &RequestContext) -> Result<Self> {
        let http = SyncHttpClient::with_timeouts(Duration::from_secs(10), Duration::from_secs(30))?;
        let base = url::Url::parse("https://www.bilibili.com/")?;
        let headers = request_headers(&base, request_context)?;
        Ok(Self { http, headers })
    }

    /// Start an attempt: collect device cookies, then ask for a QR code.
    pub(crate) fn start(&self) -> Result<QrLoginSession> {
        let cookie = self.device_cookies().unwrap_or_default();
        let (payload, _) = self.get_json(PASSPORT_BASE, QR_GENERATE_PATH, &cookie)?;
        let data = payload
            .get("data")
            .context("QR login response had no data")?;
        let url = data
            .get("url")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .context("QR login response had no scan URL")?;
        let key = data
            .get("qrcode_key")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .context("QR login response had no qrcode_key")?;
        Ok(QrLoginSession {
            url: url.to_string(),
            key: key.to_string(),
            cookie,
        })
    }

    /// Ask whether the QR code has been scanned and confirmed.
    ///
    /// The caller polls this on a timer and passes back the `cookie` set from
    /// [`Self::start`], so the endpoint sees one continuous client instead of
    /// a stranger every two seconds.
    pub(crate) fn poll(&self, key: &str, cookie: &str) -> Result<QrLoginState> {
        let key = key.trim();
        if key.is_empty() {
            bail!("QR login poll needs the key from the generate call");
        }
        let (payload, headers) = self.get_json(
            PASSPORT_BASE,
            &format!("{QR_POLL_PATH}?qrcode_key={}", encode_query_value(key)),
            cookie,
        )?;
        let data = payload.get("data").context("QR poll had no data")?;
        let code = data.get("code").and_then(Value::as_i64).unwrap_or(-1);
        let message = data
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        Ok(match code {
            86101 => QrLoginState::Waiting,
            86090 => QrLoginState::Scanned,
            0 => {
                let handoff = data.get("url").and_then(Value::as_str);
                match session_cookie(&headers, handoff, cookie) {
                    Some(cookie) => QrLoginState::Confirmed { cookie },
                    None => QrLoginState::Failed(
                        "the QR code was confirmed but the response carried no session cookie"
                            .to_string(),
                    ),
                }
            }
            86038 => QrLoginState::Expired,
            _ => QrLoginState::Failed(if message.is_empty() {
                format!("QR login poll returned code {code}")
            } else {
                format!("{message} (code {code})")
            }),
        })
    }

    /// The homepage's device cookies (`buvid3`, `b_nut`), when it sets any.
    fn device_cookies(&self) -> Result<String> {
        let (status, headers, _) = self
            .http
            .get("https://www.bilibili.com/", &self.headers)
            .context("Failed to collect Bilibili device cookies")?;
        if !(200..300).contains(&status) {
            bail!("Bilibili homepage answered HTTP {status}");
        }
        Ok(cookies_from_headers(&headers, SESSION_COOKIE_NAMES).unwrap_or_default())
    }

    /// One passport request. The response headers come back with the body
    /// because the poll's own `Set-Cookie` *is* the session.
    fn get_json(
        &self,
        base: &str,
        path: &str,
        cookie: &str,
    ) -> Result<(Value, Vec<(String, String)>)> {
        let url = format!("{base}{path}");
        let mut headers = self.headers.clone();
        let cookie = cookie.trim();
        if !cookie.is_empty() {
            headers.retain(|(name, _)| !name.eq_ignore_ascii_case("cookie"));
            headers.push(("cookie".to_string(), cookie.to_string()));
        }
        let (status, response_headers, body) = self
            .http
            .get(&url, &headers)
            .with_context(|| format!("Bilibili passport request failed: {path}"))?;
        if !(200..300).contains(&status) {
            bail!("Bilibili passport answered HTTP {status} for {path}");
        }
        let payload = nextjson::from_slice::<Value>(&body)
            .with_context(|| format!("Failed to parse Bilibili passport response from {path}"))?;
        Ok((payload, response_headers))
    }
}

/// `name=value` pairs worth keeping, from every `Set-Cookie` in a response.
///
/// Each header carries exactly one cookie, and everything after the first `;`
/// is an attribute list that is dropped here — which is also why these
/// headers are never parsed by splitting on commas: an `Expires` attribute
/// contains one.
fn cookies_from_headers(headers: &[(String, String)], names: &[&str]) -> Option<String> {
    let mut pairs: Vec<(String, String)> = Vec::new();
    for (name, value) in headers {
        if !name.eq_ignore_ascii_case("set-cookie") {
            continue;
        }
        let pair = value.split(';').next().unwrap_or_default();
        let Some((cookie_name, cookie_value)) = pair.split_once('=') else {
            continue;
        };
        let cookie_name = cookie_name.trim();
        let cookie_value = cookie_value.trim();
        if cookie_value.is_empty()
            || !names
                .iter()
                .any(|known| known.eq_ignore_ascii_case(cookie_name))
        {
            continue;
        }
        pairs.retain(|(existing, _)| !existing.eq_ignore_ascii_case(cookie_name));
        pairs.push((cookie_name.to_string(), cookie_value.to_string()));
    }
    join_cookie_pairs(pairs)
}

/// The session cookie for a confirmed login: what `Set-Cookie` provided,
/// anything the endpoint published as query parameters in `data.url` (the
/// cross-domain hand-off shape), and the device cookies of the attempt.
fn session_cookie(
    headers: &[(String, String)],
    data_url: Option<&str>,
    attempt_cookie: &str,
) -> Option<String> {
    let mut pairs: Vec<(String, String)> = Vec::new();
    if let Some(from_headers) = cookies_from_headers(headers, SESSION_COOKIE_NAMES) {
        for pair in from_headers.split("; ") {
            if let Some((name, value)) = pair.split_once('=') {
                pairs.push((name.to_string(), value.to_string()));
            }
        }
    }
    if let Some(url) = data_url {
        if let Ok(parsed) = url::Url::parse(url) {
            for (name, value) in parsed.query_pairs() {
                if !SESSION_COOKIE_NAMES
                    .iter()
                    .any(|known| known.eq_ignore_ascii_case(&name))
                {
                    continue;
                }
                pairs.retain(|(existing, _)| !existing.eq_ignore_ascii_case(&name));
                pairs.push((name.into_owned(), value.into_owned()));
            }
        }
    }
    // Device cookies last: they are the weakest evidence and must never
    // overwrite a session value that arrived in the same response.
    for pair in attempt_cookie.split("; ") {
        let Some((name, value)) = pair.split_once('=') else {
            continue;
        };
        if pairs.iter().any(|(existing, _)| existing == name)
            || !SESSION_COOKIE_NAMES
                .iter()
                .any(|known| known.eq_ignore_ascii_case(name))
        {
            continue;
        }
        pairs.push((name.to_string(), value.to_string()));
    }
    // A session without SESSDATA cannot authenticate anything; reporting
    // success would hand the UI a cookie string that silently does nothing.
    if !pairs
        .iter()
        .any(|(name, _)| name.eq_ignore_ascii_case("SESSDATA"))
    {
        return None;
    }
    join_cookie_pairs(pairs)
}

fn join_cookie_pairs(pairs: Vec<(String, String)>) -> Option<String> {
    if pairs.is_empty() {
        return None;
    }
    Some(
        pairs
            .into_iter()
            .map(|(name, value)| format!("{name}={value}"))
            .collect::<Vec<_>>()
            .join("; "),
    )
}

/// Percent-encode a query value (the key is a hex token today, but never
/// assume that of a value about to be pasted into a URL).
fn encode_query_value(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(values: &[&str]) -> Vec<(String, String)> {
        values
            .iter()
            .map(|value| ("Set-Cookie".to_string(), (*value).to_string()))
            .collect()
    }

    #[test]
    fn keeps_only_the_session_cookies() {
        let parsed = cookies_from_headers(
            &headers(&[
                "buvid3=ABC123infoc; path=/; expires=Tue, 05 Oct 2027 10:57:32 GMT; domain=.bilibili.com",
                "b_nut=1791197852; path=/",
                "b_lsid=DEADBEEF; path=/",
                "buvid_fp=abcdef; path=/",
            ]),
            SESSION_COOKIE_NAMES,
        )
        .expect("device cookies are kept");
        // The comma inside `expires` must not split anything, and cookies
        // nothing asks for must not be forwarded.
        assert_eq!(parsed, "buvid3=ABC123infoc; b_nut=1791197852");
        assert!(
            cookies_from_headers(&headers(&["b_lsid=x; path=/"]), SESSION_COOKIE_NAMES).is_none()
        );
    }

    #[test]
    fn reads_the_session_from_set_cookie_headers() {
        let cookie = session_cookie(
            &headers(&[
                "SESSDATA=abc%2Cdef; Path=/; Domain=.bilibili.com; HttpOnly",
                "bili_jct=token; Path=/",
                "DedeUserID=12345; Path=/",
                "DedeUserID__ckMd5=md5; Path=/",
                "sid=xyz; Path=/",
            ]),
            None,
            "buvid3=device",
        )
        .expect("a session is assembled");
        assert_eq!(
            cookie,
            "SESSDATA=abc%2Cdef; bili_jct=token; DedeUserID=12345; DedeUserID__ckMd5=md5; sid=xyz; buvid3=device"
        );
    }

    #[test]
    fn reads_the_session_from_the_cross_domain_url() {
        // The hand-off shape: the query carries the same values, URL-encoded,
        // so one decode yields the cookie value Bilibili itself stores.
        // `SESSDATA` legitimately contains percent sequences (`abc%2Cdef` is
        // a comma and an asterisk in the raw token), which is why the fixture
        // encodes the percent sign as well: `abc%252Cdef` -> `abc%2Cdef`.
        let cookie = session_cookie(
            &headers(&["buvid3=device; path=/"]),
            Some(
                "https://passport.biligame.com/crossDomain?DedeUserID=42&SESSDATA=abc%252Cdef&bili_jct=jct&gourl=https%3A%2F%2Fwww.bilibili.com",
            ),
            "buvid3=device",
        )
        .expect("the URL query carries the session");
        assert_eq!(
            cookie,
            "buvid3=device; DedeUserID=42; SESSDATA=abc%2Cdef; bili_jct=jct"
        );
    }

    #[test]
    fn refuses_a_confirmation_without_sessdata() {
        // Device cookies alone are not a login.
        assert!(
            session_cookie(&headers(&["buvid3=device; path=/"]), None, "buvid3=device").is_none()
        );
        assert!(session_cookie(&[], None, "").is_none());
    }

    #[test]
    fn a_response_cookie_wins_over_the_attempt_cookie() {
        let cookie = session_cookie(
            &headers(&["SESSDATA=fresh; Path=/", "buvid3=fresh-device; Path=/"]),
            None,
            "buvid3=stale-device; b_nut=1",
        )
        .expect("session assembles");
        assert_eq!(cookie, "SESSDATA=fresh; buvid3=fresh-device; b_nut=1");
    }

    #[test]
    fn encodes_query_values() {
        assert_eq!(encode_query_value("a1b2c3"), "a1b2c3");
        assert_eq!(encode_query_value("a b&c=d"), "a%20b%26c%3Dd");
        assert_eq!(encode_query_value("中文"), "%E4%B8%AD%E6%96%87");
    }
}
