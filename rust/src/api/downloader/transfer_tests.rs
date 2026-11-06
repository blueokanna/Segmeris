use super::*;
use crate::test_http::{response, serve};

#[test]
fn large_non_range_body_is_written_to_disk() {
    let length = 65 * 1024 * 1024 + 17;
    let (url, server) = serve(1, move |_, request, socket| {
        assert!(request.to_ascii_lowercase().contains("range: bytes=0-"));
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
        let chunk = [0x55; 65536];
        let mut left = length;
        while left > 0 {
            let n = left.min(chunk.len());
            socket.write_all(&chunk[..n]).unwrap();
            left -= n;
        }
    });
    let dir = std::env::temp_dir().join(format!("segmeris-stream-test-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("output.bin");
    stream_media_response_to_file(
        &SyncHttpClient::new().unwrap(),
        &url,
        &[],
        &file,
        0.0,
        1.0,
        &noop_progress_reporter(),
        "test",
    )
    .unwrap();
    assert_eq!(std::fs::metadata(&file).unwrap().len(), length as u64);
    let mut input = std::fs::File::open(&file).unwrap();
    let mut buf = [0; 65536];
    loop {
        let n = input.read(&mut buf).unwrap();
        if n == 0 {
            break;
        }
        assert!(buf[..n].iter().all(|b| *b == 0x55));
    }
    drop(input);
    server.join().unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn unvalidated_partial_response_retries_as_full_request() {
    let (url, server) = serve(2, |i, request, socket| {
        if i == 0 {
            write!(socket, "HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 0-2/6\r\nConnection: close\r\n\r\nabc").unwrap();
        } else {
            assert!(!request.to_ascii_lowercase().contains("range:"));
            response(socket, b"abcdef");
        }
    });
    let dir = std::env::temp_dir().join(format!("segmeris-range-test-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("output.bin");
    stream_media_response_to_file(
        &SyncHttpClient::new().unwrap(),
        &url,
        &[],
        &file,
        0.0,
        1.0,
        &noop_progress_reporter(),
        "test",
    )
    .unwrap();
    assert_eq!(std::fs::read(&file).unwrap(), b"abcdef");
    server.join().unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}
