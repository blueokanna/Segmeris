use super::*;
use crate::api::downloader::noop_progress_reporter;
use crate::test_http::{TestDirectory, serve, serve_parallel};
use std::io::{Read, Write};
use std::sync::{Arc, Condvar};
use std::time::Duration;

fn requested_range(request: &str) -> (u64, u64) {
    let range = request
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase()
                .strip_prefix("range: bytes=")
                .map(str::to_owned)
        })
        .unwrap();
    let (start, end) = range.split_once('-').unwrap();
    (start.parse().unwrap(), end.parse().unwrap())
}

fn range_response(socket: &mut std::net::TcpStream, start: u64, end: u64, total: u64, value: u8) {
    write!(socket, "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{total}\r\nETag: \"stable\"\r\nConnection: close\r\n\r\n", end - start + 1).unwrap();
    let buffer = [value; 64 * 1024];
    let mut remaining = end - start + 1;
    while remaining > 0 {
        let count = remaining.min(buffer.len() as u64) as usize;
        socket.write_all(&buffer[..count]).unwrap();
        remaining -= count as u64;
    }
}

#[test]
fn range_workers_overlap_and_assemble_in_order_with_a_fixed_budget() {
    let total = RANGE_CHUNK * 3;
    let gate = Arc::new((Mutex::new(0usize), Condvar::new()));
    let gate_handler = gate.clone();
    let (url, server) = serve_parallel(4, move |request, socket| {
        let (start, end) = requested_range(&request);
        if end == 0 {
            return range_response(socket, 0, 0, total, 1);
        }
        assert!(
            request
                .to_ascii_lowercase()
                .contains("if-range: \"stable\"")
        );
        let (count, wake) = &*gate_handler;
        let mut count = count.lock().unwrap();
        *count += 1;
        wake.notify_all();
        let (count, _) = wake
            .wait_timeout_while(count, Duration::from_secs(3), |n| *n < 3)
            .unwrap();
        assert_eq!(*count, 3, "all three ranges must be in flight concurrently");
        drop(count);
        range_response(socket, start, end, total, (start / RANGE_CHUNK + 1) as u8);
    });
    let dir = TestDirectory::new("parallel-order");
    let output = dir.path().join("result.bin");
    assert!(
        try_parallel_transfer(
            &SyncHttpClient::new().unwrap(),
            &url,
            &[],
            &output,
            3,
            0.0,
            1.0,
            &noop_progress_reporter(),
            "test"
        )
        .unwrap()
    );
    assert_eq!(std::fs::metadata(&output).unwrap().len(), total);
    let mut file = std::fs::File::open(&output).unwrap();
    let mut buffer = [0u8; 64 * 1024];
    for index in 0..3 {
        for _ in 0..RANGE_CHUNK / buffer.len() as u64 {
            file.read_exact(&mut buffer).unwrap();
            assert!(buffer.iter().all(|value| *value == index + 1));
        }
    }
    server.join().unwrap();
}

#[test]
fn restarting_reuses_complete_ranges_and_resumes_incomplete_ranges() {
    let total = RANGE_CHUNK * 2;
    let (url, server) = serve(2, move |index, request, socket| {
        let (start, end) = requested_range(&request);
        if index == 0 {
            return range_response(socket, 0, 0, total, 0x55);
        }
        assert_eq!(start, RANGE_CHUNK + 65536);
        assert_eq!(end, total - 1);
        range_response(socket, start, end, total, 0x55);
    });
    let dir = TestDirectory::new("parallel-resume");
    let output = dir.path().join("result.bin");
    let ranges = resumable_partial_path(&output, &url, &[]).with_extension("ranges");
    std::fs::create_dir(&ranges).unwrap();
    write_resumable_metadata(
        &ranges.join("entity"),
        &ResumableMetadata {
            etag: Some("\"stable\"".into()),
            last_modified: None,
            total_length: Some(total),
        },
    )
    .unwrap();
    crate::api::downloader::hls::write_hls_segment_cache(
        &ranges.join(format!("0-{}.chunk", RANGE_CHUNK - 1)),
        &vec![0x55; RANGE_CHUNK as usize],
        &format!("range-v1:0:{}", RANGE_CHUNK - 1),
    )
    .unwrap();
    std::fs::write(
        ranges.join(format!("{}-{}.part", RANGE_CHUNK, total - 1)),
        vec![0x55; 65536],
    )
    .unwrap();
    assert!(
        try_parallel_transfer(
            &SyncHttpClient::new().unwrap(),
            &url,
            &[],
            &output,
            6,
            0.0,
            1.0,
            &noop_progress_reporter(),
            "test"
        )
        .unwrap()
    );
    assert_eq!(std::fs::metadata(output).unwrap().len(), total);
    assert!(!ranges.exists());
    server.join().unwrap();
}

#[test]
fn cdn_rejecting_parallel_ranges_can_fall_back_to_one_connection() {
    let total = RANGE_CHUNK * 2;
    let gate = Arc::new((Mutex::new(0), Condvar::new()));
    let (url, server) = serve_parallel(4, move |request, socket| {
        let (start, end) = requested_range(&request);
        if (start, end) == (0, 0) || (start, end) == (0, total - 1) {
            return range_response(socket, start, end, total, 0x55);
        }
        let (count, wake) = &*gate;
        let mut count = count.lock().unwrap();
        *count += 1;
        wake.notify_all();
        let (count, _) = wake
            .wait_timeout_while(count, Duration::from_secs(3), |n| *n < 2)
            .unwrap();
        assert_eq!(*count, 2);
        socket.write_all(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
    });
    let dir = TestDirectory::new("parallel-downgrade");
    let output = dir.path().join("result.bin");
    download_with_retries(
        &SyncHttpClient::new().unwrap(),
        &url,
        &[],
        &output,
        true,
        2,
        1,
        0.0,
        1.0,
        &noop_progress_reporter(),
        "test",
    )
    .unwrap();
    assert_eq!(std::fs::metadata(output).unwrap().len(), total);
    server.join().unwrap();
}

#[test]
fn invalid_parallel_ranges_never_publish_or_append_untrusted_bytes() {
    for (status, content_range, etag) in [
        ("200 OK", "bytes 0-2/6", "stable"),
        ("206 Partial Content", "bytes 1-3/6", "stable"),
        ("206 Partial Content", "bytes 0-2/7", "stable"),
        ("206 Partial Content", "bytes 0-2/6", "changed"),
    ] {
        let (url, server) = serve(1, move |_, _, socket| {
            write!(socket, "HTTP/1.1 {status}\r\nContent-Length: 3\r\nContent-Range: {content_range}\r\nETag: \"{etag}\"\r\nConnection: close\r\n\r\nabc").unwrap();
        });
        let dir = TestDirectory::new("invalid-parallel");
        let metadata = ResumableMetadata {
            etag: Some("\"stable\"".into()),
            last_modified: None,
            total_length: Some(6),
        };
        assert!(
            download_range(
                &SyncHttpClient::new().unwrap(),
                &url,
                &[],
                dir.path(),
                &metadata,
                0,
                2,
                &AtomicU64::new(0),
                &|_| {}
            )
            .is_err()
        );
        assert!(!dir.path().join("0-2.chunk").exists());
        assert_eq!(
            std::fs::metadata(dir.path().join("0-2.part"))
                .unwrap()
                .len(),
            0
        );
        server.join().unwrap();
    }
}
