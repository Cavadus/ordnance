//! Pure-Rust Helldivers 2 offline-edit primitives — replaces \`compiler/hd2edit.py\`.

use blake2::digest::{consts::U24, Digest, Update};
use blake2::Blake2b;
use crypto_box::aead::{Aead, OsRng};
use crypto_box::{Nonce, PublicKey, SalsaBox, SecretKey};

// ===== sealed box (libsodium crypto_box_seal) =====
// The game's sealed-box keypair, as a hex constant. Arrowhead ships these in
// the game itself; they're the same values the whole HD2 modding ecosystem
// uses to seal/unseal .dl_bin files.

fn hex32(s: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).expect("hex key");
    }
    out
}

fn game_pk() -> PublicKey {
    PublicKey::from(hex32("2dc9aa7c30e6eed5f7fd0e0e95c7287299b126f79520cc41de750982ee7ff50c"))
}
fn game_sk() -> SecretKey {
    SecretKey::from(hex32("a0296b81310b58f013d8a9b343a1c292008003dfd9ab15fcf351543048b49b64"))
}

/// libsodium sealed-box nonce: BLAKE2b-24(epk || recipient_pk).
fn seal_nonce(epk: &[u8], pk: &PublicKey) -> [u8; 24] {
    let mut h = Blake2b::<U24>::new();
    Update::update(&mut h, epk);
    Update::update(&mut h, pk.as_bytes());
    let out = h.finalize();
    let mut nonce = [0u8; 24];
    nonce.copy_from_slice(&out);
    nonce
}

pub fn seal_open(sealed: &[u8]) -> Vec<u8> {
    let epk = PublicKey::from(<[u8; 32]>::try_from(&sealed[..32]).expect("epk len"));
    let boxed = SalsaBox::new(&epk, &game_sk());
    let nonce = Nonce::from(seal_nonce(&sealed[..32], &game_pk()));
    boxed.decrypt(&nonce, &sealed[32..]).expect("seal open")
}

pub fn seal(plaintext: &[u8]) -> Vec<u8> {
    let esk = SecretKey::generate(&mut OsRng);
    let epk = esk.public_key();
    let boxed = SalsaBox::new(&game_pk(), &esk);
    let nonce = Nonce::from(seal_nonce(epk.as_bytes(), &game_pk()));
    let ct = boxed.encrypt(&nonce, plaintext).expect("seal");
    let mut out = Vec::with_capacity(32 + ct.len());
    out.extend_from_slice(epk.as_bytes());
    out.extend_from_slice(&ct);
    out
}

// ===== murmur64 =====

const MUL: u64 = 0xC6A4A7935BD1E995;
const INV: u64 = 0x5F7A0EA7E59B19BD;
const SEED: u64 = 16045690983977655786;

fn mix(v: u64) -> u64 {
    let v = v.wrapping_mul(MUL);
    let v = v ^ (v >> 47);
    v.wrapping_mul(MUL)
}
fn unmix(v: u64) -> u64 {
    let v = v.wrapping_mul(INV);
    let v = v ^ (v >> 47);
    v.wrapping_mul(INV)
}

pub fn rd64(p: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(p[o..o + 8].try_into().unwrap())
}
pub fn wr64(p: &mut [u8], o: usize, v: u64) {
    p[o..o + 8].copy_from_slice(&v.to_le_bytes());
}
pub fn rd_u32(p: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(p[o..o + 4].try_into().unwrap())
}
pub fn rd_f32(p: &[u8], o: usize) -> f32 {
    f32::from_le_bytes(p[o..o + 4].try_into().unwrap())
}
pub fn put_u32(p: &mut [u8], o: usize, v: u32) {
    p[o..o + 4].copy_from_slice(&v.to_le_bytes());
}
pub fn put_f32(p: &mut [u8], o: usize, v: f32) {
    p[o..o + 4].copy_from_slice(&v.to_le_bytes());
}

fn forward(mut h: u64, p: &[u8], a: usize, b: usize) -> u64 {
    let mut i = a;
    while i < b {
        h = (h ^ mix(rd64(p, i))).wrapping_mul(MUL);
        i += 8;
    }
    h
}
fn backward(mut h: u64, p: &[u8], a: usize, b: usize) -> u64 {
    let mut i = b;
    while i > a {
        i -= 8;
        h = h.wrapping_mul(INV) ^ mix(rd64(p, i));
    }
    h
}

fn tail_word(p: &[u8], n: usize) -> (u64, usize) {
    let whole = n - n % 8;
    let mut t = 0u64;
    for i in (whole..n).rev() {
        t = (t << 8) | p[i] as u64;
    }
    (t, whole)
}

pub fn murmur64(p: &[u8]) -> u64 {
    let n = p.len();
    let mut h = SEED ^ (n as u64).wrapping_mul(MUL);
    let (t, whole) = tail_word(p, n);
    h = forward(h, p, 0, whole);
    if whole < n {
        h = (h ^ t).wrapping_mul(MUL);
    }
    h ^= h >> 47;
    h = h.wrapping_mul(MUL);
    h ^= h >> 47;
    h
}

fn before_final(target: u64, p: &[u8], n: usize) -> (u64, usize) {
    let mut h = target;
    h ^= h >> 47;
    h = h.wrapping_mul(INV);
    h ^= h >> 47;
    let (t, whole) = tail_word(p, n);
    if whole < n {
        h = h.wrapping_mul(INV) ^ t;
    }
    (h, whole)
}

// ===== headers =====

const NEEDLE: [u8; 8] = [b'L', b'D', b'L', b'D', 0x01, 0x00, 0x00, 0x00];

pub fn headers(p: &[u8]) -> Vec<(usize, u32, u32)> {
    let n = p.len();
    let mut out = Vec::new();
    let mut at = p[..64.min(n)].windows(8).position(|w| w == NEEDLE);
    while let Some(a) = at {
        if a + 24 > n {
            break;
        }
        let typ = rd_u32(p, a + 8);
        let size = rd_u32(p, a + 12);
        out.push((a, typ, size));
        let nxt = a + 24 + size as usize;
        if nxt >= n {
            break;
        }
        let end = (nxt + 64).min(n);
        at = p[nxt..end]
            .windows(8)
            .position(|w| w == NEEDLE)
            .map(|i| nxt + i);
    }
    out
}

// ===== hash correction =====

pub fn correct(p: &mut [u8], target: u64, edited_floats: &[usize]) -> Result<(), String> {
    let n = p.len();
    let hs = headers(p);
    for &(at, _t, _s) in &hs {
        if p[at + 16] != 1 {
            return Err("bad header flag".into());
        }
        for k in 17..24 {
            if p[at + k] != 0 {
                return Err("bad header flag".into());
            }
        }
    }
    if murmur64(p) == target {
        return Ok(());
    }

    let mut x = None;
    let mut aligned = false;
    for &(at, _t, _s) in hs.iter().rev() {
        if at % 8 == 0 && at > 0 {
            x = Some(at);
            aligned = true;
            break;
        }
    }
    let x = x.unwrap_or(hs.last().unwrap().0);
    let words_end = if aligned { x + 24 } else { x + 28 };
    let first = if aligned { x + 16 } else { x + 12 };

    let (final_h, whole) = before_final(target, p, n);
    let start = SEED ^ (n as u64).wrapping_mul(MUL);

    let mut slots: Vec<(bool, usize, usize)> = hs
        .iter()
        .filter(|(at, _t, _s)| *at != x)
        .map(|(at, _t, _s)| (false, at + 17, at + 18))
        .collect();
    for &o in edited_floats {
        slots.push((true, o, 0));
    }
    slots.sort_by_key(|&(_, s1, _)| (s1 as isize - x as isize).unsigned_abs());

    let (fixed12, hi20) = if !aligned {
        (rd64(p, x + 12) & 0xFFFF_FFFF_FF, rd64(p, x + 20) >> 32)
    } else {
        (0, 0)
    };

    for &(is_float, s1, s2) in &slots {
        let (lo, hi, before_slot, after_slot, orig_fp, orig_b0, orig_b1, tries) = if !is_float {
            let lo = s1 - s1 % 8;
            let hi = (s2 - s2 % 8) + 8;
            let bs = forward(start, p, 0, lo);
            let as_ = backward(final_h, p, words_end, whole);
            (lo, hi, bs, as_, 0u32, p[s1], p[s2], 65535u32)
        } else {
            let fo = s1;
            let lo = fo - fo % 8;
            let hi = lo + 8;
            let bs = forward(start, p, 0, first);
            let as_ = backward(final_h, p, hi, whole);
            (lo, hi, bs, as_, rd_u32(p, fo), 0u8, 0u8, 4095u32)
        };

        let hi_after_first = hi > first;

        for salt in 1..=tries {
            if is_float {
                put_u32(p, s1, orig_fp ^ salt);
            } else {
                p[s1] = (salt & 0xFF) as u8;
                p[s2] = ((salt >> 8) & 0xFF) as u8;
            }

            let (h_before, after) = if hi_after_first {
                let after = backward(after_slot, p, words_end, hi);
                (before_slot, after)
            } else {
                let h_before = forward(before_slot, p, lo, first);
                (h_before, after_slot)
            };

            if aligned {
                let m = after.wrapping_mul(INV) ^ h_before;
                let w = unmix(m);
                if (w & 0xFF) == 1 {
                    wr64(p, x + 16, w);
                    return Ok(());
                }
            } else {
                let need = after.wrapping_mul(INV);
                let mut found = None;
                for t in 0u64..(1u64 << 24) {
                    let w12 = fixed12 | (t << 40);
                    let varr = mix(w12);
                    let m20 = (h_before ^ varr).wrapping_mul(MUL) ^ need;
                    let u = unmix(m20);
                    if (u >> 32) == hi20 {
                        found = Some((t, u));
                        break;
                    }
                }
                if let Some((t, u)) = found {
                    wr64(p, x + 12, fixed12 | (t << 40));
                    wr64(p, x + 20, u);
                    return Ok(());
                }
            }
        }

        if is_float {
            put_u32(p, s1, orig_fp);
        } else {
            p[s1] = orig_b0;
            p[s2] = orig_b1;
        }
    }

    Err("no hash correction found".into())
}

#[cfg(test)]
mod tests {
    use super::{murmur64, seal, seal_open};

    #[test]
    fn seal_round_trip() {
        let msg = b"Helldivers 2 offline edit round-trip test payload";
        let sealed = seal(msg);
        assert_eq!(sealed.len(), msg.len() + 48, "sealed = epk(32) + mac(16) + ciphertext");
        assert_eq!(seal_open(&sealed), msg);
    }

    #[test]
    fn murmur64_matches_known_vector() {
        // Cross-checked against compiler/hd2edit.py.
        assert_eq!(murmur64(b"hello world"), 0x607dd06b9bf2d630);
    }
}
