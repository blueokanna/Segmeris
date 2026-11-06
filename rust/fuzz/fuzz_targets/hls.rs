#![no_main]
#[allow(dead_code)]
#[path = "../../src/hls.rs"]
mod hls;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = hls::parse_playlist(data);
});
