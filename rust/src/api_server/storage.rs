use std::collections::HashMap;
use std::fmt;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use tzcraft::Zoned;

use super::models::{DownloadRequest, DownloadStatus};

macro_rules! update_task {
    ($store:expr, $task_id:expr, $task:ident => $body:block) => {
        if let Some($task) = $store.lock().tasks.get_mut($task_id) {
            $body
        }
    };
}

/// All task mutations share the deletion lock. A download records its output
/// before starting file I/O, so deletion cannot race that ownership update.
/// This store is currently in-memory; there is no fallible history save after unlink.
#[derive(Clone, Default)]
pub struct TaskStore {
    inner: Arc<Mutex<StoreState>>,
}

#[derive(Default)]
struct StoreState {
    tasks: HashMap<String, DownloadStatus>,
    requests: HashMap<String, DownloadRequest>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum QueueTask {
    Inserted,
    Existing(String),
}

#[derive(Debug)]
pub(super) enum DeleteTaskError {
    NotFound,
    NotCompleted,
    OutputInUse,
    InvalidOutput(&'static str),
    FileIo(io::Error),
}

impl fmt::Display for DeleteTaskError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => formatter.write_str("Task not found"),
            Self::NotCompleted => formatter.write_str("Only completed downloads can be deleted"),
            Self::OutputInUse => formatter.write_str("Another task references this output file"),
            Self::InvalidOutput(message) => formatter.write_str(message),
            Self::FileIo(error) => write!(formatter, "Cannot delete download: {error}"),
        }
    }
}

impl From<io::Error> for DeleteTaskError {
    fn from(error: io::Error) -> Self {
        Self::FileIo(error)
    }
}

impl TaskStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, StoreState> {
        self.inner.lock().unwrap_or_else(|error| error.into_inner())
    }

    #[cfg(test)]
    pub(super) fn insert_queued(&self, task_id: String, source_url: String) {
        self.lock()
            .tasks
            .insert(task_id.clone(), DownloadStatus::queued(task_id, source_url));
    }

    /// Reserve a known output before returning HTTP 202. Identical retry requests
    /// reuse the task ID, including a completion whose response the client lost.
    pub(super) fn insert_if_output_available(
        &self,
        task_id: String,
        request: DownloadRequest,
        output: Option<String>,
    ) -> Result<QueueTask, DeleteTaskError> {
        let mut state = self.lock();
        if output.is_none()
            && let Some((id, _)) = state.tasks.iter().find(|(id, task)| {
                matches!(
                    task.status.as_str(),
                    "queued" | "running" | "paused" | "completed"
                ) && state.requests.get(*id).is_some_and(|old| old == &request)
            })
        {
            return Ok(QueueTask::Existing(id.clone()));
        }
        if let Some(ref path) = output {
            let key = output_key(path)?;
            for (id, task) in &state.tasks {
                let Some(ref owned) = task.output_path else {
                    continue;
                };
                if same_output_path(&key, &output_key(owned)?) {
                    let same_request = state
                        .requests
                        .get(id)
                        .is_some_and(|old| old.same_effective_download(&request));
                    if same_request
                        && matches!(
                            task.status.as_str(),
                            "queued" | "running" | "paused" | "completed"
                        )
                    {
                        return Ok(QueueTask::Existing(id.clone()));
                    }
                    // A failed task may leave reusable partial data. Permit only
                    // the same request to retry it; never hand another source its output.
                    if task.status != "failed" || !same_request {
                        return Err(DeleteTaskError::OutputInUse);
                    }
                }
            }
        }
        let mut task = DownloadStatus::queued(task_id.clone(), request.url.clone());
        task.output_path = output;
        state.requests.insert(task_id.clone(), request);
        state.tasks.insert(task_id, task);
        Ok(QueueTask::Inserted)
    }

    /// Bind inferred names after inspection, before the downloader opens files.
    pub(super) fn claim_output(&self, task_id: &str, output: &str) -> Result<(), DeleteTaskError> {
        let mut state = self.lock();
        let request = state
            .requests
            .get(task_id)
            .ok_or(DeleteTaskError::NotFound)?;
        let key = output_key(output)?;
        for (id, other) in &state.tasks {
            if id == task_id {
                continue;
            }
            let Some(ref owned) = other.output_path else {
                continue;
            };
            if same_output_path(&key, &output_key(owned)?) {
                let same_failed_request = other.status == "failed"
                    && state
                        .requests
                        .get(id)
                        .is_some_and(|old| old.same_effective_download(request));
                if !same_failed_request {
                    return Err(DeleteTaskError::OutputInUse);
                }
            }
        }
        // Failed matching attempts stop owning the path once a retry claims it.
        // Their history remains visible, but cannot block deletion of the retry.
        for (id, other) in &mut state.tasks {
            if id != task_id
                && other.status == "failed"
                && other.output_path.as_deref().is_some_and(|path| {
                    output_key(path).is_ok_and(|old| same_output_path(&key, &old))
                })
            {
                other.output_path = None;
            }
        }
        state
            .tasks
            .get_mut(task_id)
            .ok_or(DeleteTaskError::NotFound)?
            .output_path = Some(output.into());
        Ok(())
    }

    pub fn get(&self, task_id: &str) -> Option<DownloadStatus> {
        self.lock().tasks.get(task_id).cloned()
    }

    pub fn list(&self) -> Vec<DownloadStatus> {
        let mut tasks = self.lock().tasks.values().cloned().collect::<Vec<_>>();
        tasks.sort_by(|left, right| {
            let left_ns = left.created_at.ticks().as_unix_nanos();
            let right_ns = right.created_at.ticks().as_unix_nanos();
            right_ns.cmp(&left_ns)
        });
        tasks
    }

    /// Remove exactly the completed task's known output and then its record.
    /// The record is unchanged on any validation or filesystem failure.
    pub(super) fn delete_completed(
        &self,
        task_id: &str,
        download_dir: &Path,
    ) -> Result<(), DeleteTaskError> {
        let mut state = self.lock();
        let tasks = &state.tasks;
        let task = tasks.get(task_id).ok_or(DeleteTaskError::NotFound)?;
        if task.status != "completed" {
            return Err(DeleteTaskError::NotCompleted);
        }
        let output = task
            .output_path
            .as_deref()
            .filter(|path| !path.trim().is_empty())
            .ok_or(DeleteTaskError::InvalidOutput(
                "Completed task has no output path",
            ))?;
        let root = download_dir.canonicalize()?;
        if !root.is_dir() {
            return Err(DeleteTaskError::InvalidOutput(
                "DOWNLOAD_DIR is not a directory",
            ));
        }
        let target = confined_output_path(&root, output)?;
        // Check every other status, including a download whose writer is still
        // active. Canonical parents also catch alternate spellings of the path.
        if tasks.iter().any(|(id, other)| {
            id != task_id
                && other.output_path.as_deref().is_some_and(|path| {
                    confined_output_path(&root, path).is_ok_and(|other_target| {
                        same_output_path(&target, &other_target)
                            || other_target
                                .canonicalize()
                                .is_ok_and(|resolved| same_output_path(&target, &resolved))
                    })
                })
        }) {
            return Err(DeleteTaskError::OutputInUse);
        }
        match std::fs::symlink_metadata(&target) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
                return Err(DeleteTaskError::InvalidOutput(
                    "Refusing to delete a symlink, directory or non-regular output",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        match std::fs::remove_file(&target) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        // No recursive deletion or guessed sidecars: only output_path belongs to
        // this task. HashMap removal cannot fail after a successful unlink.
        state.tasks.remove(task_id);
        state.requests.remove(task_id);
        Ok(())
    }

    pub fn update_progress(
        &self,
        task_id: &str,
        status: &str,
        message: &str,
        progress_percent: Option<f64>,
        output_path: Option<String>,
    ) {
        update_task!(self, task_id, task => {
            if task.status != "paused" || status != "running" {
                task.status = if status == "resuming" { "running" } else { status }.to_string();
                task.message = message.to_string();
            }
            task.progress_percent = progress_percent;
            if let Some(output_path) = output_path {
                task.output_path = Some(output_path);
            }
        });
    }

    pub fn mark_completed(&self, task_id: &str, output_path: String) {
        update_task!(self, task_id, task => {
            task.status = "completed".to_string();
            task.message = "Download completed".to_string();
            task.progress_percent = Some(100.0);
            task.output_path = Some(output_path);
            task.error = None;
            task.completed_at = Some(Zoned::now_utc().unwrap_or_else(|_| Zoned::from_ticks(tzcraft::Ticks::EPOCH, tzcraft::Zone::Utc)));
        });
    }

    pub fn mark_failed(&self, task_id: &str, error: &str) {
        update_task!(self, task_id, task => {
            task.status = "failed".to_string();
            task.message = "Download failed".to_string();
            task.error = Some(error.to_string());
            task.completed_at = Some(Zoned::now_utc().unwrap_or_else(|_| Zoned::from_ticks(tzcraft::Ticks::EPOCH, tzcraft::Zone::Utc)));
        });
    }
}

/// The API downloader only creates direct children of DOWNLOAD_DIR. Use that
/// stricter boundary instead of permitting user-controlled nested directories.
/// Resolve the parent even when the output is already absent, then rebuild the
/// path from the canonical root so a symlinked parent cannot redirect unlink.
fn confined_output_path(root: &Path, output: &str) -> Result<PathBuf, DeleteTaskError> {
    let path = Path::new(output);
    if path.components().any(|part| part == Component::ParentDir) {
        return Err(DeleteTaskError::InvalidOutput(
            "Output path contains parent traversal",
        ));
    }
    let name = path.file_name().ok_or(DeleteTaskError::InvalidOutput(
        "Output path has no filename",
    ))?;
    let absolute = std::path::absolute(path)?;
    let parent = absolute
        .parent()
        .ok_or(DeleteTaskError::InvalidOutput(
            "Output path has no directory",
        ))?
        .canonicalize()?;
    if !same_output_path(&parent, root) {
        return Err(DeleteTaskError::InvalidOutput(
            "Output must be a direct file in DOWNLOAD_DIR",
        ));
    }
    Ok(root.join(name))
}

fn output_key(output: &str) -> Result<PathBuf, DeleteTaskError> {
    let path = std::path::absolute(Path::new(output))?;
    let name = path.file_name().ok_or(DeleteTaskError::InvalidOutput(
        "Output path has no filename",
    ))?;
    let parent = path
        .parent()
        .ok_or(DeleteTaskError::InvalidOutput(
            "Output path has no directory",
        ))?
        .canonicalize()?;
    Ok(parent.join(name))
}

fn same_output_path(left: &Path, right: &Path) -> bool {
    #[cfg(windows)]
    {
        left.as_os_str().to_string_lossy().to_lowercase()
            == right.as_os_str().to_string_lossy().to_lowercase()
    }
    #[cfg(not(windows))]
    {
        left == right
    }
}

#[cfg(test)]
mod delete_tests {
    use super::*;

    struct TestDirectory(PathBuf);
    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("segmeris-api-delete-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn completed(&self, store: &TaskStore, id: &str, name: &str) -> PathBuf {
            let path = self.0.join(name);
            store.insert_queued(id.into(), "https://example.com/video".into());
            store.mark_completed(id, path.to_string_lossy().into_owned());
            path
        }
    }
    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn delete_completed_removes_only_known_file_and_record() {
        let directory = TestDirectory::new();
        let store = TaskStore::new();
        let output = directory.completed(&store, "done", "movie.mp4");
        std::fs::write(&output, "download").unwrap();
        let sidecar = directory.0.join("movie.srt");
        std::fs::write(&sidecar, "user subtitle").unwrap();
        store.insert_queued("unrelated".into(), "https://example.com/other".into());
        store.delete_completed("done", &directory.0).unwrap();
        assert!(!output.exists());
        assert!(store.get("done").is_none());
        assert!(store.get("unrelated").is_some());
        assert_eq!(std::fs::read_to_string(sidecar).unwrap(), "user subtitle");
    }

    #[test]
    fn delete_missing_output_still_removes_record() {
        let directory = TestDirectory::new();
        let store = TaskStore::new();
        directory.completed(&store, "done", "absent.mp4");
        store.delete_completed("done", &directory.0).unwrap();
        assert!(store.list().is_empty());
    }

    #[test]
    fn delete_rejects_every_non_completed_status() {
        let directory = TestDirectory::new();
        for status in ["queued", "running", "paused", "failed"] {
            let store = TaskStore::new();
            let output = directory.completed(&store, "task", "movie.mp4");
            std::fs::write(&output, "keep").unwrap();
            store.update_progress("task", status, "state", None, None);
            assert!(matches!(
                store.delete_completed("task", &directory.0),
                Err(DeleteTaskError::NotCompleted)
            ));
            assert_eq!(store.get("task").unwrap().status, status);
            assert_eq!(std::fs::read_to_string(output).unwrap(), "keep");
        }
    }

    #[test]
    fn delete_unknown_or_unresolved_task_does_not_mutate_store() {
        let directory = TestDirectory::new();
        let store = TaskStore::new();
        assert!(matches!(
            store.delete_completed("missing", &directory.0),
            Err(DeleteTaskError::NotFound)
        ));
        store.insert_queued("broken".into(), "https://example.com/video".into());
        store.update_progress("broken", "completed", "broken", None, None);
        assert!(matches!(
            store.delete_completed("broken", &directory.0),
            Err(DeleteTaskError::InvalidOutput(_))
        ));
        assert!(store.get("broken").is_some());
    }

    #[test]
    fn delete_rejects_outside_paths_and_parent_traversal() {
        let directory = TestDirectory::new();
        let outside = TestDirectory::new();
        let output = outside.0.join("private.mp4");
        std::fs::write(&output, "private").unwrap();
        let store = TaskStore::new();
        for path in [
            output.clone(),
            directory
                .0
                .join("..")
                .join(outside.0.file_name().unwrap())
                .join("private.mp4"),
        ] {
            store.insert_queued("task".into(), "https://example.com/video".into());
            store.mark_completed("task", path.to_string_lossy().into_owned());
            assert!(matches!(
                store.delete_completed("task", &directory.0),
                Err(DeleteTaskError::InvalidOutput(_))
            ));
            assert!(store.get("task").is_some());
            assert_eq!(std::fs::read_to_string(&output).unwrap(), "private");
        }
    }

    #[test]
    fn delete_rejects_directory_without_removing_history() {
        let directory = TestDirectory::new();
        let store = TaskStore::new();
        let output = directory.completed(&store, "done", "folder.mp4");
        std::fs::create_dir(&output).unwrap();
        assert!(matches!(
            store.delete_completed("done", &directory.0),
            Err(DeleteTaskError::InvalidOutput(_))
        ));
        assert!(output.is_dir());
        assert!(store.get("done").is_some());
    }

    #[test]
    fn delete_rejects_shared_output_for_active_and_completed_tasks() {
        let directory = TestDirectory::new();
        for status in ["queued", "running", "paused", "completed", "failed"] {
            let store = TaskStore::new();
            let output = directory.completed(&store, "done", "shared.mp4");
            std::fs::write(&output, "shared").unwrap();
            store.insert_queued("other".into(), "https://example.com/other".into());
            store.update_progress(
                "other",
                status,
                "other",
                None,
                Some(output.to_string_lossy().into_owned()),
            );
            assert!(matches!(
                store.delete_completed("done", &directory.0),
                Err(DeleteTaskError::OutputInUse)
            ));
            assert_eq!(store.list().len(), 2);
            assert_eq!(std::fs::read_to_string(&output).unwrap(), "shared");
        }
    }

    #[test]
    fn delete_concurrent_requests_remove_the_task_once() {
        let directory = TestDirectory::new();
        let store = TaskStore::new();
        let output = directory.completed(&store, "done", "movie.mp4");
        std::fs::write(&output, "download").unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let workers: Vec<_> = (0..2)
            .map(|_| {
                let store = store.clone();
                let root = directory.0.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    store.delete_completed("done", &root)
                })
            })
            .collect();
        barrier.wait();
        let outcomes: Vec<_> = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect();
        assert_eq!(outcomes.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            outcomes
                .iter()
                .filter(|result| matches!(result, Err(DeleteTaskError::NotFound)))
                .count(),
            1
        );
        assert!(!output.exists());
    }

    #[cfg(unix)]
    #[test]
    fn delete_rejects_symlink_file_and_symlinked_outside_directory() {
        use std::os::unix::fs::symlink;
        let directory = TestDirectory::new();
        let outside = TestDirectory::new();
        let output = outside.0.join("private.mp4");
        std::fs::write(&output, "private").unwrap();
        let store = TaskStore::new();
        let link = directory.completed(&store, "linked-file", "link.mp4");
        symlink(&output, &link).unwrap();
        assert!(matches!(
            store.delete_completed("linked-file", &directory.0),
            Err(DeleteTaskError::InvalidOutput(_))
        ));
        let linked_directory = directory.0.join("outside");
        symlink(&outside.0, &linked_directory).unwrap();
        store.insert_queued("linked-parent".into(), "https://example.com/video".into());
        store.mark_completed(
            "linked-parent",
            linked_directory
                .join("private.mp4")
                .to_string_lossy()
                .into_owned(),
        );
        assert!(matches!(
            store.delete_completed("linked-parent", &directory.0),
            Err(DeleteTaskError::InvalidOutput(_))
        ));
        assert_eq!(std::fs::read_to_string(output).unwrap(), "private");
        assert_eq!(store.list().len(), 2);
    }

    fn request(url: &str) -> DownloadRequest {
        nextjson::from_str(&format!(
            r#"{{"url":"{url}","output_filename":"same.mp4"}}"#
        ))
        .unwrap()
    }

    #[test]
    fn queue_retry_reuses_active_and_completed_id_without_duplicate_record() {
        let directory = TestDirectory::new();
        let output = directory.0.join("same.mp4").to_string_lossy().into_owned();
        let store = TaskStore::new();
        let original = request("https://example.com/video");
        assert_eq!(
            store
                .insert_if_output_available("first".into(), original.clone(), Some(output.clone()))
                .unwrap(),
            QueueTask::Inserted
        );
        for status in ["queued", "running", "paused", "completed"] {
            store.update_progress("first", status, "state", None, None);
            assert_eq!(
                store
                    .insert_if_output_available(
                        "retry".into(),
                        original.clone(),
                        Some(output.clone())
                    )
                    .unwrap(),
                QueueTask::Existing("first".into())
            );
            assert_eq!(store.list().len(), 1);
        }
    }

    #[test]
    fn queue_same_output_rejects_other_source_options_and_credentials() {
        let directory = TestDirectory::new();
        let output = directory.0.join("same.mp4").to_string_lossy().into_owned();
        let store = TaskStore::new();
        let original = request("https://example.com/video");
        store
            .insert_if_output_available("first".into(), original.clone(), Some(output.clone()))
            .unwrap();
        let other_source = request("https://example.com/different");
        let mut other_options = original.clone();
        other_options.video_bitrate = Some(1000);
        let mut other_context = original.clone();
        other_context.request_context = Some(super::super::models::ApiRequestContext {
            cookie: Some("private-session".into()),
            ..Default::default()
        });
        for different in [other_source, other_options, other_context] {
            assert!(matches!(
                store.insert_if_output_available("second".into(), different, Some(output.clone())),
                Err(DeleteTaskError::OutputInUse)
            ));
        }
        assert_eq!(store.list().len(), 1);
    }

    #[test]
    fn queue_matching_failed_retry_can_claim_partial_without_leaving_output_alias() {
        let directory = TestDirectory::new();
        let output = directory.0.join("same.mp4").to_string_lossy().into_owned();
        let store = TaskStore::new();
        let original = request("https://example.com/video");
        store
            .insert_if_output_available("first".into(), original.clone(), Some(output.clone()))
            .unwrap();
        store.mark_failed("first", "network disconnected");
        assert_eq!(
            store
                .insert_if_output_available("retry".into(), original, Some(output.clone()))
                .unwrap(),
            QueueTask::Inserted
        );
        store.claim_output("retry", &output).unwrap();
        assert!(store.get("first").unwrap().output_path.is_none());
        store.mark_completed("retry", output);
        store.delete_completed("retry", &directory.0).unwrap();
        assert!(store.get("retry").is_none());
        assert!(store.get("first").is_some());
    }

    #[test]
    fn queue_concurrent_retries_reserve_one_output() {
        let directory = TestDirectory::new();
        let output = directory.0.join("same.mp4").to_string_lossy().into_owned();
        let store = TaskStore::new();
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let workers: Vec<_> = (0..2)
            .map(|index| {
                let store = store.clone();
                let barrier = barrier.clone();
                let output = output.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    store.insert_if_output_available(
                        format!("task-{index}"),
                        request("https://example.com/video"),
                        Some(output),
                    )
                })
            })
            .collect();
        barrier.wait();
        let results: Vec<_> = workers
            .into_iter()
            .map(|worker| worker.join().unwrap().unwrap())
            .collect();
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, QueueTask::Inserted))
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, QueueTask::Existing(_)))
                .count(),
            1
        );
        assert_eq!(store.list().len(), 1);
    }

    #[test]
    fn queue_inferred_output_rejects_another_task_before_file_io() {
        let directory = TestDirectory::new();
        let output = directory.0.join("same.mp4").to_string_lossy().into_owned();
        let store = TaskStore::new();
        store
            .insert_if_output_available("first".into(), request("https://example.com/video"), None)
            .unwrap();
        store.claim_output("first", &output).unwrap();
        store
            .insert_if_output_available("other".into(), request("https://example.com/other"), None)
            .unwrap();
        assert!(matches!(
            store.claim_output("other", &output),
            Err(DeleteTaskError::OutputInUse)
        ));
        assert!(store.get("other").unwrap().output_path.is_none());
    }

    #[cfg(windows)]
    #[test]
    fn delete_locked_file_preserves_record_on_io_failure() {
        use std::os::windows::fs::OpenOptionsExt;
        let directory = TestDirectory::new();
        let store = TaskStore::new();
        let output = directory.completed(&store, "done", "locked.mp4");
        std::fs::write(&output, "keep").unwrap();
        // Permit reading/writing but withhold FILE_SHARE_DELETE. Modern Windows
        // can unlink readonly files, so the readonly attribute is not a denial fixture.
        let held_file = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(0x1 | 0x2)
            .open(&output)
            .unwrap();
        let outcome = store.delete_completed("done", &directory.0);
        drop(held_file);
        assert!(matches!(outcome, Err(DeleteTaskError::FileIo(_))));
        assert_eq!(std::fs::read_to_string(&output).unwrap(), "keep");
        assert!(store.get("done").is_some());
    }
}
