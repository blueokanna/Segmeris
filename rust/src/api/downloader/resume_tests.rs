use super::*;
use crate::test_http::{TestDirectory, response, serve};

fn transfer(url: &str, output: &Path) -> Result<()> {
    stream_media_response_to_file(
        &SyncHttpClient::new()?,
        url,
        &[],
        output,
        0.0,
        1.0,
        &noop_progress_reporter(),
        "test",
    )
}

#[test]
fn interrupted_full_response_resumes_after_a_new_invocation() {
    const TOTAL: usize = 192 * 1024;
    let (url, server) = serve(2, |index, request, socket| {
        if index == 0 {
            write!(socket, "HTTP/1.1 200 OK\r\nContent-Length: {TOTAL}\r\nETag: \"stable\"\r\nConnection: close\r\n\r\n").unwrap();
            socket.write_all(&vec![0x41; 64 * 1024]).unwrap();
        } else {
            let request = request.to_ascii_lowercase();
            assert!(request.contains("range: bytes=65536-"), "{request}");
            assert!(request.contains("if-range: \"stable\""));
            write!(socket, "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes 65536-{}/{TOTAL}\r\nETag: \"stable\"\r\nConnection: close\r\n\r\n", TOTAL - 65536, TOTAL - 1).unwrap();
            socket.write_all(&vec![0x41; TOTAL - 65536]).unwrap();
        }
    });
    let dir = TestDirectory::new("resume-new-call");
    let output = dir.path().join("result.bin");
    std::fs::write(&output, b"previous completed output").unwrap();
    assert!(transfer(&url, &output).is_err());
    let partial = resumable_partial_path(&output, &url, &[]);
    assert_eq!(std::fs::metadata(&partial).unwrap().len(), 65536);
    assert_eq!(
        std::fs::read(&output).unwrap(),
        b"previous completed output"
    );
    transfer(&url, &output).unwrap();
    assert_eq!(std::fs::read(&output).unwrap(), vec![0x41; TOTAL]);
    server.join().unwrap();
}

#[test]
fn short_chunked_body_keeps_validated_prefix_for_retry() {
    let (url, server) = serve(2, |index, request, socket| {
        if index == 0 {
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\nContent-Range: bytes 0-5/6\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n3\r\nabc\r\n0\r\n\r\n").unwrap();
        } else {
            assert!(request.to_ascii_lowercase().contains("range: bytes=3-"));
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 3-5/6\r\nETag: \"v1\"\r\nConnection: close\r\n\r\ndef").unwrap();
        }
    });
    let dir = TestDirectory::new("short-chunked");
    let output = dir.path().join("result.bin");
    assert!(transfer(&url, &output).is_err());
    assert_eq!(
        std::fs::read(resumable_partial_path(&output, &url, &[])).unwrap(),
        b"abc"
    );
    transfer(&url, &output).unwrap();
    assert_eq!(std::fs::read(output).unwrap(), b"abcdef");
    server.join().unwrap();
}

#[test]
fn changed_validator_restarts_without_splicing_representations() {
    let (url, server) = serve(2, |index, request, socket| {
        if index == 0 {
            assert!(request.to_ascii_lowercase().contains("range: bytes=3-"));
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 3-5/6\r\nETag: \"new\"\r\nConnection: close\r\n\r\nNEW").unwrap();
        } else {
            assert!(request.to_ascii_lowercase().contains("range: bytes=0-"));
            response(socket, b"newnew");
        }
    });
    let dir = TestDirectory::new("changed-validator");
    let output = dir.path().join("result.bin");
    let partial = resumable_partial_path(&output, &url, &[]);
    std::fs::write(&partial, b"old").unwrap();
    write_resumable_metadata(
        &partial,
        &ResumableMetadata {
            etag: Some("\"old\"".into()),
            last_modified: None,
            total_length: Some(6),
        },
    )
    .unwrap();
    transfer(&url, &output).unwrap();
    assert_eq!(std::fs::read(output).unwrap(), b"newnew");
    server.join().unwrap();
}

#[test]
fn completed_media_reuse_requires_current_validator_and_local_integrity() {
    let (url, server) = serve(3, |index, request, socket| {
        if index == 1 {
            assert!(
                request
                    .to_ascii_lowercase()
                    .contains("range: bytes=0-0\r\n")
            );
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 1\r\nContent-Range: bytes 0-0/6\r\nETag: \"v1\"\r\nConnection: close\r\n\r\na").unwrap();
        } else {
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 6\r\nContent-Range: bytes 0-5/6\r\nETag: \"v1\"\r\nConnection: close\r\n\r\nabcdef").unwrap();
        }
    });
    let dir = TestDirectory::new("completed-receipt");
    let output = dir.path().join("result.bin");
    let download = || {
        download_with_retries(
            &SyncHttpClient::new().unwrap(),
            &url,
            &[],
            &output,
            true,
            1,
            1,
            0.0,
            1.0,
            &noop_progress_reporter(),
            "test",
        )
    };
    download().unwrap();
    download().unwrap();
    std::fs::write(&output, b"damage").unwrap();
    download().unwrap();
    assert_eq!(std::fs::read(output).unwrap(), b"abcdef");
    server.join().unwrap();
}

#[test]
fn bilibili_signature_refresh_preserves_only_the_same_representation() {
    let old =
        "https://upos-a.bilivideo.com/upgcxcode/12/34/55/55-80.m4s?deadline=1&upsig=old&quality=80";
    let fresh =
        "https://upos-b.bilivideo.cn/upgcxcode/12/34/55/55-80.m4s?upsig=new&quality=80&deadline=2";
    assert_eq!(media_resume_identity(old), media_resume_identity(fresh));
    assert_ne!(
        media_resume_identity(old),
        media_resume_identity(&fresh.replace("quality=80", "quality=120"))
    );
    assert_ne!(
        media_resume_identity(old),
        media_resume_identity(&fresh.replace("55-80", "55-120"))
    );
    assert_ne!(
        media_resume_identity("https://example.org/object?token=one"),
        media_resume_identity("https://example.org/object?token=two")
    );
    assert_ne!(
        media_resume_identity("https://bilivideo.com.evil.org/upgcxcode/file?deadline=1"),
        media_resume_identity("https://bilivideo.com.evil.org/upgcxcode/file?deadline=2")
    );
    let dir = TestDirectory::new("stable-resume-path");
    let output = dir.path().join("result.mp4");
    assert_eq!(
        create_resume_temp_dir(dir.path(), &output, media_resume_identity(old).as_bytes()).unwrap(),
        create_resume_temp_dir(dir.path(), &output, media_resume_identity(fresh).as_bytes())
            .unwrap()
    );
    assert_eq!(
        resumable_partial_path(&output, old, &[]),
        resumable_partial_path(&output, fresh, &[])
    );
}

#[test]
fn invalid_staged_result_preserves_existing_final_output() {
    let dir = TestDirectory::new("publication");
    let output = dir.path().join("result.mp4");
    std::fs::write(&output, b"previous good file").unwrap();
    let staged = staged_output_path(&output);
    std::fs::write(&staged, b"").unwrap();
    assert!(publish_media_output(&staged, &output).is_err());
    assert_eq!(std::fs::read(&output).unwrap(), b"previous good file");
    std::fs::write(&staged, vec![0x47; 2048]).unwrap();
    assert!(publish_media_output(&staged, &output).is_err());
    assert_eq!(std::fs::read(output).unwrap(), b"previous good file");
}

#[test]
fn audio_video_pair_obeys_one_slot_and_overlaps_with_multiple_slots() {
    for concurrency in [1, 6] {
        let gate = Arc::new((Mutex::new(0), std::sync::Condvar::new()));
        let handler_gate = gate.clone();
        let (url, server) = crate::test_http::serve_parallel(2, move |request, socket| {
            let path = request.split_whitespace().nth(1).unwrap();
            let (count, wake) = &*handler_gate;
            let mut count = count.lock().unwrap();
            if concurrency == 1 {
                assert_eq!(path, if *count == 0 { "/video" } else { "/audio" });
            }
            *count += 1;
            wake.notify_all();
            if concurrency > 1 {
                let (current, _) = wake
                    .wait_timeout_while(count, Duration::from_secs(3), |count| *count < 2)
                    .unwrap();
                count = current;
                assert_eq!(*count, 2, "audio and video should be in flight together");
            }
            drop(count);
            response(socket, if path == "/video" { b"video" } else { b"audio" });
        });
        let dir = TestDirectory::new("pair-budget");
        let video = dir.path().join("video.bin");
        let audio = dir.path().join("audio.bin");
        download_stream_pair(
            &SyncHttpClient::new().unwrap(),
            &format!("{url}/video"),
            &[],
            &format!("{url}/audio"),
            &[],
            &[],
            &video,
            &audio,
            concurrency,
            1,
            &noop_progress_reporter(),
        )
        .unwrap();
        assert_eq!(std::fs::read(video).unwrap(), b"video");
        assert_eq!(std::fs::read(audio).unwrap(), b"audio");
        server.join().unwrap();
    }
}

#[test]
fn legacy_hls_entry_rejects_invalid_concurrency_before_any_io() {
    let dir = TestDirectory::new("legacy-validation");
    let output = dir.path().join("result.mp4");
    for concurrency in [0, -1, 257] {
        assert!(
            hls2mp4_core(
                noop_progress_reporter(),
                "https://example.com/hls".into(),
                concurrency,
                output.to_string_lossy().into_owned(),
                1,
                0,
                0,
                false
            )
            .is_err()
        );
    }
    assert!(!output.exists());
}

#[test]
fn output_aliases_share_the_same_resume_directory() {
    let dir = TestDirectory::new("output-aliases");
    let first = normalized_output_path(dir.path().join("result.mp4").to_str().unwrap()).unwrap();
    let second =
        normalized_output_path(dir.path().join(".").join("result.mp4").to_str().unwrap()).unwrap();
    assert_eq!(first, second);
    assert_eq!(DownloadOptions::default().concurrency, 6);
}
