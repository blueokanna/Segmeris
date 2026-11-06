//! Cooperative task control shared by the API, Flutter and segment workers.
use anyhow::{bail, Result};
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};

#[derive(Default)]
pub(crate) struct Control {
    paused: Mutex<bool>,
    wake: Condvar,
}
type Controls = Mutex<HashMap<String, Weak<Control>>>;
fn registry() -> &'static Controls {
    static REGISTRY: OnceLock<Controls> = OnceLock::new();
    REGISTRY.get_or_init(Controls::default)
}
thread_local! { static CURRENT: RefCell<Option<Arc<Control>>> = const { RefCell::new(None) }; }

pub(crate) fn current() -> Option<Arc<Control>> {
    CURRENT.with(|slot| slot.borrow().clone())
}

pub(crate) struct Scope {
    previous: Option<Arc<Control>>,
    id: Option<String>,
}
pub(crate) fn enter(control: Option<Arc<Control>>) -> Scope {
    let previous = CURRENT.with(|slot| slot.replace(control));
    Scope { previous, id: None }
}
pub(crate) fn register(id: &str) -> Result<Scope> {
    let control = current().unwrap_or_else(|| Arc::new(Control::default()));
    let mut registry = registry().lock().unwrap_or_else(|e| e.into_inner());
    registry.retain(|_, value| value.strong_count() > 0);
    if let Some(owner) = registry.get(id).and_then(Weak::upgrade) {
        if Arc::ptr_eq(&owner, &control) {
            return Ok(enter(Some(control)));
        }
        bail!("A download already owns this output path");
    }
    registry.insert(id.to_owned(), Arc::downgrade(&control));
    let mut scope = enter(Some(control));
    scope.id = Some(id.to_owned());
    Ok(scope)
}
impl Drop for Scope {
    fn drop(&mut self) {
        if let Some(id) = &self.id {
            registry()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(id);
        }
        CURRENT.with(|slot| slot.replace(self.previous.take()));
    }
}
pub(crate) fn set_paused(id: &str, paused: bool) -> bool {
    let control = registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(id)
        .and_then(Weak::upgrade);
    let Some(control) = control else {
        return false;
    };
    *control.paused.lock().unwrap_or_else(|e| e.into_inner()) = paused;
    if !paused {
        control.wake.notify_all();
    }
    true
}
pub(crate) fn checkpoint() -> Result<()> {
    if let Some(control) = current() {
        let paused = control.paused.lock().unwrap_or_else(|e| e.into_inner());
        drop(
            control
                .wake
                .wait_while(paused, |paused| *paused)
                .unwrap_or_else(|e| e.into_inner()),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    #[test]
    fn api_task_alias_does_not_bypass_output_ownership() {
        let _task = register("owner-api-task").unwrap();
        let output = register("shared-output-test").unwrap();
        assert!(set_paused("owner-api-task", true));
        assert!(*current().unwrap().paused.lock().unwrap());
        assert!(set_paused("shared-output-test", false));
        std::thread::spawn(|| {
            let _other = register("second-api-task").unwrap();
            assert!(register("shared-output-test").is_err());
        })
        .join()
        .unwrap();
        drop(output);
        assert!(!set_paused("shared-output-test", false));
        assert!(set_paused("owner-api-task", false));
    }

    #[test]
    fn workers_pause_resume_and_unregister() {
        let scope = register("pause-test").unwrap();
        assert!(set_paused("pause-test", true));
        let control = current();
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let _scope = enter(control);
            checkpoint().unwrap();
            tx.send(()).unwrap();
        });
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        assert!(set_paused("pause-test", false));
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        worker.join().unwrap();
        drop(scope);
        assert!(!set_paused("pause-test", true));
    }
}
