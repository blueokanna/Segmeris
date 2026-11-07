use super::*;
use crate::test_http::{response, serve};

fn download_to(url: &str, path: &Path) -> Result<()> {
    stream_media_response_to_file(
        &SyncHttpClient::new().unwrap(),
        url,
        &[],
        path,
        0.0,
        1.0,
        &noop_progress_reporter(),
        "test",
    )
}

#[test]
fn full_response_replaces_stale_partial_instead_of_appending() {
    let (url, server) = serve(1, |_, request, socket| {
        let request = request.to_ascii_lowercase();
        assert!(request.contains("range: bytes=3-"));
        assert!(request.contains("if-range: \"old\""));
        response(socket, b"new representation");
    });
    let dir = crate::test_http::TestDirectory::new("full-restart");
    let output = dir.path().join("output.bin");
    let partial = resumable_partial_path(&output, &url, &[]);
    std::fs::write(&partial, b"old").unwrap();
    write_resumable_metadata(
        &partial,
        &ResumableMetadata {
            etag: Some("\"old\"".into()),
            last_modified: None,
            total_length: Some(100),
        },
    )
    .unwrap();
    download_to(&url, &output).unwrap();
    assert_eq!(std::fs::read(&output).unwrap(), b"new representation");
    assert!(!partial.exists());
    assert!(!resumable_metadata_path(&partial).exists());
    server.join().unwrap();
}

#[test]
fn chunked_and_close_delimited_full_responses_stream_to_disk() {
    let (url, server) = serve(2, |index, _, socket| {
        if index == 0 {
            socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n").unwrap();
        } else {
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabcdef")
                .unwrap();
        }
    });
    let dir = crate::test_http::TestDirectory::new("unbounded-framing");
    for index in 0..2 {
        let path = dir.path().join(format!("output-{index}.bin"));
        download_to(&url, &path).unwrap();
        assert_eq!(std::fs::read(path).unwrap(), b"abcdef");
    }
    server.join().unwrap();
}

#[test]
fn oversized_partial_body_is_discarded_before_it_can_be_resumed() {
    let (url, server) = serve(1, |_, _, socket| {
        socket.write_all(b"HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\nContent-Range: bytes 0-2/6\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n6\r\nabcdef\r\n0\r\n\r\n").unwrap();
    });
    let dir = crate::test_http::TestDirectory::new("oversized-partial");
    let output = dir.path().join("output.bin");
    std::fs::write(&output, b"previous output").unwrap();
    let error = download_to(&url, &output).unwrap_err();
    assert!(error.to_string().contains("exceeded its declared length"));
    let partial = resumable_partial_path(&output, &url, &[]);
    assert!(!partial.exists());
    assert!(!resumable_metadata_path(&partial).exists());
    assert_eq!(std::fs::read(output).unwrap(), b"previous output");
    server.join().unwrap();
}

#[test]
fn truncated_full_response_never_replaces_completed_output() {
    let (url, server) = serve(1, |_, _, socket| {
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\nshort")
            .unwrap();
    });
    let dir = crate::test_http::TestDirectory::new("truncated-full");
    let output = dir.path().join("output.bin");
    std::fs::write(&output, b"previous output").unwrap();
    assert!(download_to(&url, &output).is_err());
    assert_eq!(std::fs::read(output).unwrap(), b"previous output");
    server.join().unwrap();
}

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
