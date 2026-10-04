//! MurmurHash3 x64 128-bit — the hash Bilibili's web client uses to
//! derive the `buvid_fp` browser fingerprint from the User-Agent
//! string. Implemented from the public-domain reference algorithm
//! (Austin Appleby); the tests below pin fixed outputs.

const C1: u64 = 0x87c3_7b91_1142_53d5;
const C2: u64 = 0x4cf5_ad43_2745_937f;
const R1: u32 = 27;
const R2: u32 = 31;
const R3: u32 = 33;

/// Hashes `data` with MurmurHash3 x64 128-bit, returning the `(h1, h2)`
/// halves in the order the reference implementation reports them.
pub fn murmur3_x64_128(data: &[u8], seed: u32) -> (u64, u64) {
    let mut h1 = u64::from(seed);
    let mut h2 = u64::from(seed);

    let (chunks, tail) = data.as_chunks::<16>();
    for chunk in chunks {
        let mut k1 = u64::from_le_bytes(chunk[..8].try_into().unwrap());
        let mut k2 = u64::from_le_bytes(chunk[8..].try_into().unwrap());

        k1 = k1.wrapping_mul(C1).rotate_left(R2).wrapping_mul(C2);
        h1 ^= k1;
        h1 = h1
            .rotate_left(R1)
            .wrapping_add(h2)
            .wrapping_mul(5)
            .wrapping_add(0x52dc_e729);

        k2 = k2.wrapping_mul(C2).rotate_left(R3).wrapping_mul(C1);
        h2 ^= k2;
        h2 = h2
            .rotate_left(R2)
            .wrapping_add(h1)
            .wrapping_mul(5)
            .wrapping_add(0x3849_5ab5);
    }

    if tail.len() > 8 {
        let mut k2 = 0u64;
        for (index, byte) in tail[8..].iter().enumerate() {
            k2 |= u64::from(*byte) << (8 * index);
        }
        k2 = k2.wrapping_mul(C2).rotate_left(R3).wrapping_mul(C1);
        h2 ^= k2;
    }
    if !tail.is_empty() {
        let mut k1 = 0u64;
        for (index, byte) in tail[..tail.len().min(8)].iter().enumerate() {
            k1 |= u64::from(*byte) << (8 * index);
        }
        k1 = k1.wrapping_mul(C1).rotate_left(R2).wrapping_mul(C2);
        h1 ^= k1;
    }

    let length = data.len() as u64;
    h1 ^= length;
    h2 ^= length;

    h1 = h1.wrapping_add(h2);
    h2 = h2.wrapping_add(h1);
    h1 = fmix64(h1);
    h2 = fmix64(h2);
    h1 = h1.wrapping_add(h2);
    h2 = h2.wrapping_add(h1);

    (h1, h2)
}

/// The final avalanche mixer of the reference implementation.
fn fmix64(mut value: u64) -> u64 {
    value ^= value >> 33;
    value = value.wrapping_mul(0xff51_afd7_ed55_8ccd);
    value ^= value >> 33;
    value = value.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    value ^= value >> 33;
    value
}

#[cfg(test)]
mod tests {
    use super::murmur3_x64_128;

    /// The reference test suite (`PeterScott/murmur3` `test.c`, the
    /// implementation the `mmh3` package validates against) prints the
    /// 16 output bytes as four 32-bit words in memory order; on
    /// little-endian hosts that is `[h1 low][h1 high][h2 low][h2
    /// high]`, which is exactly how the expected pairs below were
    /// derived (`x64, 128` rows).
    #[test]
    fn matches_reference_vectors() {
        assert_eq!(
            murmur3_x64_128(b"", 123),
            (0x8167_9d1a_4cd9_5970, 0x4bac_e33d_bd92_f878)
        );
        assert_eq!(
            murmur3_x64_128(b"Hello, world!", 123),
            (0x421c_8c73_8743_acad, 0xf197_32fd_d373_c3f5)
        );
        assert_eq!(
            murmur3_x64_128(b"Hello, world!", 321),
            (0xca47_f42b_f86d_4004, 0x7920_0aee_b954_6c79)
        );
        assert_eq!(
            murmur3_x64_128(&[b'x'; 28], 123),
            (0xdbcf_7463_becf_7e04, 0xf66e_73e0_7751_664e)
        );
    }

    /// A second, independent vector source: `mmh3.hash64("foo")`,
    /// which the published test suite pins as `(h1, h2)` in signed
    /// 64-bit form, here written unsigned.
    #[test]
    fn matches_mmh3_hash64_of_foo() {
        assert_eq!(
            murmur3_x64_128(b"foo", 0),
            (16316970633193145697, 9128664383759220103)
        );
    }
}
