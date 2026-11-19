use super::*;
use crate::test_http::{TestDirectory, serve};

#[test]
fn large_hls_segment_streams_past_the_memory_body_limit() {
    let length = crate::net::MAX_MEMORY_BODY + 17;
    let (url, server) = serve(1, move |_, _, socket| {
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
        let chunk = [0x47; 65536];
        let mut left = length;
        while left > 0 {
            let count = left.min(chunk.len());
            socket.write_all(&chunk[..count]).unwrap();
            left -= count;
        }
    });
    let dir = TestDirectory::new("large-hls-stream");
    let output = dir.path().join("segment.part");
    download_segment_to_cache(
        &SyncHttpClient::new().unwrap(),
        &[],
        &HlsResourceRequest {
            url,
            byte_range: None,
        },
        Some(b"INIT"),
        None,
        1,
        &output,
        "key",
    )
    .unwrap();
    assert_eq!(
        std::fs::metadata(&output).unwrap().len(),
        (length + 4) as u64
    );
    assert!(is_valid_hls_segment_cache(&output, "key"));
    server.join().unwrap();
}

#[test]
fn ignored_range_streams_only_the_requested_slice_of_a_large_object() {
    let (url, server) = serve(1, |_, request, socket| {
        assert!(request.to_ascii_lowercase().contains("range: bytes=3-5"));
        socket
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 1000000000\r\nConnection: close\r\n\r\n",
            )
            .unwrap();
        let mut chunk = vec![0; 65536];
        chunk[3..6].copy_from_slice(b"abc");
        socket.write_all(&chunk).unwrap();
    });
    let dir = TestDirectory::new("ignored-hls-range");
    let output = dir.path().join("segment.part");
    download_segment_to_cache(
        &SyncHttpClient::new().unwrap(),
        &[],
        &HlsResourceRequest {
            url,
            byte_range: Some((3, 5)),
        },
        None,
        None,
        1,
        &output,
        "key",
    )
    .unwrap();
    assert_eq!(std::fs::read(output).unwrap(), b"abc");
    server.join().unwrap();
}

#[test]
fn interrupted_hls_segment_never_replaces_verified_cached_segment() {
    let (url, server) = serve(1, |_, _, socket| {
        socket
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\ntruncated",
            )
            .unwrap();
    });
    let dir = TestDirectory::new("hls-interrupted");
    let output = dir.path().join("segment.part");
    write_hls_segment_cache(&output, b"old intact segment", "old-key").unwrap();
    assert!(
        download_segment_to_cache(
            &SyncHttpClient::new().unwrap(),
            &[],
            &HlsResourceRequest {
                url,
                byte_range: None
            },
            None,
            None,
            1,
            &output,
            "new-key"
        )
        .is_err()
    );
    assert!(is_valid_hls_segment_cache(&output, "old-key"));
    assert!(!is_valid_hls_segment_cache(&output, "new-key"));
    assert_eq!(std::fs::read(output).unwrap(), b"old intact segment");
    server.join().unwrap();
}

#[test]
fn streamed_aes_segment_validates_padding_before_publishing() {
    let (url, server) = serve(2, |index, _, socket| {
        let mut encrypted =
            hex::decode("c3af71addfe4fcac6941286a76ddedc2d873029f04adebdf8920b262bfa0d6d7")
                .unwrap();
        if index == 1 {
            encrypted[31] ^= 0xff;
        }
        crate::test_http::response(socket, &encrypted);
    });
    let dir = TestDirectory::new("streamed-aes");
    let output = dir.path().join("segment.part");
    let request = HlsResourceRequest {
        url,
        byte_range: None,
    };
    let crypto = (vec![0; 16], vec![0; 16]);
    download_segment_to_cache(
        &SyncHttpClient::new().unwrap(),
        &[],
        &request,
        Some(b"INIT"),
        Some(&crypto),
        1,
        &output,
        "good",
    )
    .unwrap();
    assert_eq!(std::fs::read(&output).unwrap(), b"INITabcdefghijklmnop");
    assert!(
        download_segment_to_cache(
            &SyncHttpClient::new().unwrap(),
            &[],
            &request,
            None,
            Some(&crypto),
            1,
            &output,
            "bad"
        )
        .is_err()
    );
    assert!(is_valid_hls_segment_cache(&output, "good"));
    server.join().unwrap();
}
