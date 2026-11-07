use super::*;
use crate::test_http::{response, serve};
use std::io::Write;

#[test]
fn redirects_recheck_address_policy_before_connecting() {
    const FIXTURE: &str = "SEGMERIS_REDIRECT_POLICY_FIXTURE";
    if let Ok(case) = std::env::var(FIXTURE) {
        let (status, host) = case.split_once(',').unwrap();
        let status: u16 = status.parse().unwrap();
        let target = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        target.set_nonblocking(true).unwrap();
        let destination = format!(
            "http://{host}:{}/private",
            target.local_addr().unwrap().port()
        );
        // Policy is enabled only after two accepted requests, in this isolated
        // process. This exercises the real redirect loop and socket connector
        // without public-network fixtures or global races with other tests.
        let (source, server) = serve(2, move |index, _, socket| {
            let location = if index == 0 {
                "/second-hop"
            } else {
                crate::network_policy::enable_api_policy();
                &destination
            };
            write!(socket, "HTTP/1.1 {status} Redirect\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
        });
        let client = SyncHttpClient::new().unwrap();
        let error = client.get(&source, &[]).unwrap_err();
        assert!(
            error.to_string().contains("blocked by address policy"),
            "{error:#}"
        );
        assert_eq!(
            target.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        server.join().unwrap();
        return;
    }
    for case in [
        "301,127.0.0.1",
        "302,[::ffff:127.0.0.1]",
        "303,localhost",
        "307,0x7f000001",
        "308,[::ffff:127.0.0.1]",
    ] {
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "net::regression_tests::redirects_recheck_address_policy_before_connecting",
                "--nocapture",
            ])
            .env(FIXTURE, case)
            .env_remove("FERRISLOAD_ALLOW_PRIVATE_NETWORKS");
        let output = crate::process::command_with_timeout(&mut command, Duration::from_secs(10))
            .expect("address-policy fixture timed out")
            .unwrap();
        assert!(
            output.status.success(),
            "{case}: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn memory_reads_remain_bounded_for_fixed_and_chunked_bodies() {
    let (url, server) = serve(2, |index, _, socket| {
        if index == 0 {
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                MAX_MEMORY_BODY + 1
            )
            .unwrap();
        } else {
            socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n9\r\n123456789\r\n0\r\n\r\n").unwrap();
        }
    });
    let client = SyncHttpClient::new().unwrap();
    assert!(client
        .get(&url, &[])
        .unwrap_err()
        .to_string()
        .contains("memory limit"));
    let body = client.stream(&url, &[]).unwrap().body;
    assert!(body
        .collect_limited(8)
        .unwrap_err()
        .to_string()
        .contains("memory limit"));
    server.join().unwrap();
}

#[test]
fn redirects_report_effective_url_and_resolve_relative_paths() {
    let (url, server) = serve(2, |i, request, socket| {
        if i == 0 {
            write!(socket, "HTTP/1.1 302 Found\r\nLocation: /media/final/index.m3u8\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
        } else {
            assert!(request.starts_with("GET /media/final/index.m3u8 "));
            response(socket, b"#EXTM3U\n");
        }
    });
    let ((status, _, _), effective) = SyncHttpClient::new()
        .unwrap()
        .get_with_url(&format!("{url}/old"), &[])
        .unwrap();
    assert_eq!(status, 200);
    assert_eq!(
        effective.join("segment.ts").unwrap().as_str(),
        format!("{url}/media/final/segment.ts")
    );
    server.join().unwrap();
}

#[test]
fn cross_origin_redirects_do_not_forward_credentials() {
    let (target, target_server) = serve(1, |_, request, socket| {
        let request = request.to_ascii_lowercase();
        assert!(
            !request.contains("cookie:")
                && !request.contains("authorization:")
                && !request.contains("x-api-key:")
        );
        response(socket, b"ok");
    });
    let (source, source_server) = serve(1, move |_, _, socket| {
        write!(socket, "HTTP/1.1 302 Found\r\nLocation: {target}/media\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
    });
    let headers = ["Cookie", "Authorization", "X-Api-Key"].map(|key| (key.into(), "secret".into()));
    assert_eq!(
        SyncHttpClient::new()
            .unwrap()
            .get(&source, &headers)
            .unwrap()
            .2,
        b"ok"
    );
    source_server.join().unwrap();
    target_server.join().unwrap();
}

#[test]
fn no_range_response_larger_than_memory_limit_streams_in_bounded_chunks() {
    let length = MAX_MEMORY_BODY + 123;
    let (url, server) = serve(1, move |_, request, socket| {
        assert!(request.to_ascii_lowercase().contains("range: bytes=0-"));
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
        let chunk = [0x51; 65536];
        let mut left = length;
        while left > 0 {
            let n = left.min(chunk.len());
            socket.write_all(&chunk[..n]).unwrap();
            left -= n;
        }
    });
    let mut body = SyncHttpClient::new()
        .unwrap()
        .stream_range(&url, &[], 0, 8388607)
        .unwrap()
        .body;
    let mut received = 0;
    while let Some(chunk) = body.next_chunk().unwrap() {
        assert!(chunk.len() <= 65536);
        assert!(chunk.iter().all(|byte| *byte == 0x51));
        received += chunk.len();
    }
    assert_eq!(received, length);
    server.join().unwrap();
}

#[test]
fn chunked_body_and_truncated_fixed_length_are_distinguished() {
    let (url, server) = serve(2, |i, _, socket| {
        if i == 0 {
            socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\nChecksum: test\r\n\r\n").unwrap();
        } else {
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\nshort",
                )
                .unwrap();
        }
    });
    let client = SyncHttpClient::new().unwrap();
    assert_eq!(client.get(&url, &[]).unwrap().2, b"abcde");
    assert!(client.get(&url, &[]).is_err());
    server.join().unwrap();
}
