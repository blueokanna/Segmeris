use std::io::{self, Read};
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const MAX_CAPTURE: usize = 4 * 1024 * 1024;

fn capture(
    mut pipe: impl Read + Send + 'static,
) -> io::Result<mpsc::Receiver<io::Result<Vec<u8>>>> {
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("process-output".into())
        .spawn(move || {
            let result = (|| {
                let mut captured = Vec::new();
                let mut chunk = [0; 8192];
                loop {
                    let n = match pipe.read(&mut chunk) {
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        result => result?,
                    };
                    if n == 0 {
                        break;
                    }
                    let remaining = MAX_CAPTURE.saturating_sub(captured.len());
                    captured.extend_from_slice(&chunk[..n.min(remaining)]);
                }
                Ok(captured)
            })();
            let _ = tx.send(result);
        })?;
    Ok(rx)
}

fn terminate_and_reap(child: &mut Child) -> io::Result<()> {
    if let Err(error) = child.kill() {
        // The process may have exited between try_wait and kill. Never wait
        // without a successful kill or an observed exit: that defeats the cap.
        return match child.try_wait()? {
            Some(_) => Ok(()),
            None => Err(error),
        };
    }
    child.wait().map(|_| ())
}

fn receive_capture(
    receiver: mpsc::Receiver<io::Result<Vec<u8>>>,
    remaining: Duration,
) -> Option<io::Result<Vec<u8>>> {
    match receiver.recv_timeout(remaining) {
        Ok(result) => Some(result),
        Err(mpsc::RecvTimeoutError::Timeout) => None,
        Err(mpsc::RecvTimeoutError::Disconnected) => Some(Err(io::Error::other(
            "Process output reader stopped unexpectedly",
        ))),
    }
}

/// The calling thread owns the child throughout its lifetime. Output readers
/// drain both pipes concurrently, but cannot take away the handle needed to
/// terminate and reap a timed-out process. `None` means the deadline expired;
/// spawn, capture and termination failures remain distinguishable I/O errors.
pub(crate) fn command_with_timeout(
    command: &mut Command,
    timeout: Duration,
) -> Option<io::Result<Output>> {
    let started = Instant::now();
    let mut child = match command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => return Some(Err(error)),
    };
    let readers = capture(child.stdout.take().unwrap())
        .and_then(|out| capture(child.stderr.take().unwrap()).map(|err| (out, err)));
    let (stdout, stderr) = match readers {
        Ok(readers) => readers,
        Err(error) => {
            if let Err(cleanup) = terminate_and_reap(&mut child) {
                return Some(Err(cleanup));
            }
            return Some(Err(error));
        }
    };
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Err(error) => {
                if let Err(cleanup) = terminate_and_reap(&mut child) {
                    return Some(Err(cleanup));
                }
                return Some(Err(error));
            }
            Ok(None) => {}
        }
        if started.elapsed() >= timeout {
            return terminate_and_reap(&mut child).err().map(Err);
        }
        std::thread::sleep(
            Duration::from_millis(10).min(timeout.saturating_sub(started.elapsed())),
        );
    };
    let stdout = match receive_capture(stdout, timeout.saturating_sub(started.elapsed()))? {
        Ok(bytes) => bytes,
        Err(error) => return Some(Err(error)),
    };
    let stderr = match receive_capture(stderr, timeout.saturating_sub(started.elapsed()))? {
        Ok(bytes) => bytes,
        Err(error) => return Some(Err(error)),
    };
    Some(Ok(Output {
        status,
        stdout,
        stderr,
    }))
}

pub(crate) fn failed_exit_status() -> std::process::ExitStatus {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(124 << 8)
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(124)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn fixture(mode: &str) -> Command {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command.args([
            "--exact",
            "process::tests::subprocess_fixture",
            "--nocapture",
        ]);
        command.env("SEGMERIS_PROCESS_FIXTURE", mode);
        command
    }

    #[test]
    fn subprocess_fixture() {
        let Ok(mode) = std::env::var("SEGMERIS_PROCESS_FIXTURE") else {
            return;
        };
        match mode.as_str() {
            "sleep" => {
                std::thread::sleep(Duration::from_secs(2));
                std::fs::write(
                    std::env::var_os("SEGMERIS_PROCESS_MARKER").unwrap(),
                    b"alive",
                )
                .unwrap();
            }
            "output" => {
                let chunk = [b'x'; 8192];
                for _ in 0..(MAX_CAPTURE / chunk.len() + 4) {
                    std::io::stdout().write_all(&chunk).unwrap();
                    std::io::stderr().write_all(&chunk).unwrap();
                }
            }
            "failure" => {
                assert_eq!(std::io::stdin().read(&mut [0]).unwrap(), 0);
                std::io::stderr().write_all(b"intentional failure").unwrap();
                std::process::exit(42);
            }
            _ => panic!("unknown process fixture"),
        }
        std::process::exit(0);
    }

    #[test]
    fn hung_child_is_killed_at_deadline() {
        let marker = std::env::temp_dir().join(format!("segmeris-child-{}", uuid::Uuid::new_v4()));
        let mut command = fixture("sleep");
        command.env("SEGMERIS_PROCESS_MARKER", &marker);
        let start = Instant::now();
        assert!(command_with_timeout(&mut command, Duration::from_millis(100)).is_none());
        assert!(start.elapsed() < Duration::from_secs(1));
        std::thread::sleep(Duration::from_millis(2200));
        let survived = marker.exists();
        let _ = std::fs::remove_file(marker);
        assert!(!survived, "timed-out process continued running");
    }

    #[test]
    fn drains_both_pipes_after_reaching_the_capture_limit() {
        let output = command_with_timeout(&mut fixture("output"), Duration::from_secs(10))
            .expect("output capture timed out")
            .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout.len(), MAX_CAPTURE);
        assert_eq!(output.stderr, vec![b'x'; MAX_CAPTURE]);
    }

    #[test]
    fn preserves_exit_status_and_stderr() {
        let output = command_with_timeout(&mut fixture("failure"), Duration::from_secs(10))
            .expect("command timed out")
            .unwrap();
        assert_eq!(output.status.code(), Some(42));
        assert_eq!(output.stderr, b"intentional failure");
    }
    #[test]
    fn spawn_errors_are_not_timeouts() {
        assert!(command_with_timeout(
            &mut Command::new("segmeris-no-such-command"),
            Duration::from_secs(1)
        )
        .unwrap()
        .is_err());
        assert!(!failed_exit_status().success());
    }
}
