use std::io::{self, Read};
use std::process::{Command, Output, Stdio};
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
                    let n = pipe.read(&mut chunk)?;
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
            let _ = child.kill();
            let _ = child.wait();
            return Some(Err(error));
        }
    };
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Some(Err(error));
            }
            Ok(None) => {}
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        std::thread::sleep(
            Duration::from_millis(10).min(timeout.saturating_sub(started.elapsed())),
        );
    };
    let out = stdout
        .recv_timeout(timeout.saturating_sub(started.elapsed()))
        .ok()?;
    let err = stderr
        .recv_timeout(timeout.saturating_sub(started.elapsed()))
        .ok()?;
    Some(out.and_then(|stdout| {
        err.map(|stderr| Output {
            status,
            stdout,
            stderr,
        })
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
    #[test]
    fn hung_child_is_killed_at_deadline() {
        #[cfg(windows)]
        let mut command = {
            let mut c = Command::new("powershell.exe");
            c.args(["-NoProfile", "-Command", "Start-Sleep -Seconds 10"]);
            c
        };
        #[cfg(unix)]
        let mut command = {
            let mut c = Command::new("sleep");
            c.arg("10");
            c
        };
        let start = Instant::now();
        assert!(command_with_timeout(&mut command, Duration::from_millis(100)).is_none());
        assert!(start.elapsed() < Duration::from_secs(2));
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
