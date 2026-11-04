//! Deploy-time HD2FM file swaps.
//!
//! A file-swap mod ships a sealed `.dl_bin` inside an `HD2FM1` record and a
//! boot script that copies it when the game exits. Ordnance paints those
//! edits onto the stock table while deploying, so the exit script is not
//! what makes the swap stick.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context};
use serde::{Deserialize, Serialize};

use super::hd2edit::{correct, headers, murmur64, rd_u32, seal, seal_open};

const RECORD_NAME: &str = "ordnance-file-swaps.json";

#[derive(Clone)]
pub struct Payload {
    pub label: String,
    /// Manifest name of the mod this payload came from. The label is only
    /// the option folder, which is not what a person picks the mod by.
    pub mod_name: String,
    /// Patch file this payload was read from, so a failed swap can drop
    /// the rest of that mod.
    pub source: PathBuf,
    pub target: String,
    pub sealed: Vec<u8>,
    pub stock_fingerprints: Vec<String>,
}

/// One payload that could not be painted. The other payloads still are.
pub struct PaintSkip {
    pub mod_name: String,
    pub source: PathBuf,
    pub message: String,
}

pub struct PaintOutcome {
    pub painted: Painted,
    pub skipped: Vec<PaintSkip>,
}

#[derive(Serialize, Deserialize, Default)]
struct SwapRecord {
    files: Vec<String>,
}

pub struct Painted {
    pub dir: PathBuf,
    pub files: Vec<String>,
}

impl Drop for Painted {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// The first well-formed `HD2FM1` record in `blob`, or `None` when the
/// bytes are only the installer's mention of that magic.
pub fn parse_hd2fm(blob: &[u8]) -> Option<Payload> {
    let magic = b"HD2FM1";
    let mut from = 0;
    while let Some(rel) = blob[from..].windows(magic.len()).position(|w| w == magic) {
        let at = from + rel;
        let header_len = u32_at(blob, at + 6)? as usize;
        if !(8..8192).contains(&header_len) || at + 10 + header_len > blob.len() {
            from = at + magic.len();
            continue;
        }
        let head = std::str::from_utf8(&blob[at + 10..at + 10 + header_len]).ok()?;
        let mut target = None;
        let mut size = None;
        let mut stocks = Vec::new();
        for line in head.lines() {
            if let Some(value) = line.strip_prefix("target=") {
                target = Some(value.trim().to_string());
            } else if let Some(value) = line.strip_prefix("size=") {
                size = value.trim().parse::<usize>().ok();
            } else if let Some(value) = line.strip_prefix("stock=") {
                stocks.push(value.trim().to_string());
            }
        }
        let target = target?;
        let size = size?;
        let name = Path::new(&target).file_name()?.to_str()?.to_string();
        if !name.ends_with(".dl_bin") || size < 48 || at + 10 + header_len + size > blob.len() {
            from = at + magic.len();
            continue;
        }
        let start = at + 10 + header_len;
        return Some(Payload {
            label: String::new(),
            mod_name: String::new(),
            source: PathBuf::new(),
            target: name,
            sealed: blob[start..start + size].to_vec(),
            stock_fingerprints: stocks,
        });
    }
    None
}

fn u32_at(buf: &[u8], at: usize) -> Option<u32> {
    let bytes: [u8; 4] = buf.get(at..at + 4)?.try_into().ok()?;
    Some(u32::from_le_bytes(bytes))
}

pub fn fingerprint(blob: &[u8]) -> String {
    let mid = blob.len() / 2;
    let tail = blob.len().saturating_sub(32);
    let mut out = String::with_capacity(blob.len().to_string().len() + 1 + 192);
    out.push_str(&blob.len().to_string());
    out.push(':');
    for byte in blob.iter().take(32).chain(blob.iter().skip(mid).take(32)).chain(blob[tail..].iter()) {
        out.push_str(&format!("{byte:02X}"));
    }
    out
}

fn content_diffs(stock: &[u8], modified: &[u8]) -> Result<Vec<(usize, Vec<u8>)>, String> {
    if modified.len() < stock.len() {
        return Err("mod table is shorter than stock".into());
    }
    let extra = modified.len() - stock.len();
    let mut skip_size = None;
    if extra > 0 {
        let fields: Vec<usize> = headers(stock).into_iter().map(|(at, _, _)| at + 12).collect();
        let Some(last) = fields.last().copied() else {
            return Err("longer mod has no section header".into());
        };
        if last + 4 > stock.len() || last + 4 > modified.len() {
            return Err("section size runs past the table".into());
        }
        let claimed = rd_u32(stock, last) as usize;
        let grown = rd_u32(modified, last) as usize;
        if grown.saturating_sub(claimed) != extra {
            return Err("longer mod is not stock plus a hash tail".into());
        }
        skip_size = Some(last);
    }
    let spans: Vec<(usize, usize)> = headers(stock).into_iter().map(|(at, _, _)| (at + 17, at + 24)).collect();
    let in_span = |i: usize| spans.iter().any(|&(a, b)| a <= i && i < b);
    let mut edits = Vec::new();
    let mut i = 0;
    while i < stock.len() {
        let skipped = skip_size == Some(i) || in_span(i) || stock[i] == modified[i];
        if skipped {
            if skip_size == Some(i) {
                i += 4;
            } else {
                i += 1;
            }
            continue;
        }
        let start = i;
        i += 1;
        while i < stock.len() && skip_size != Some(i) && !in_span(i) && stock[i] != modified[i] {
            i += 1;
        }
        edits.push((start, modified[start..i].to_vec()));
    }
    Ok(edits)
}

struct Aligned {
    stock_at: usize,
    mod_at: usize,
    stock_len: usize,
    mod_len: usize,
}

fn match_run(a: &[u8], ia: usize, b: &[u8], ib: usize, cap: usize) -> usize {
    let mut n = 0;
    while n < cap && ia + n < a.len() && ib + n < b.len() && a[ia + n] == b[ib + n] {
        n += 1;
    }
    n
}

/// Line the two plaintexts up. A short insert on one side is a shift, not an edit.
fn align_tables(stock: &[u8], modified: &[u8]) -> Result<(Vec<Aligned>, usize), String> {
    let mut diffs = Vec::new();
    let mut skipped = 0usize;
    let mut i = 0usize;
    let mut j = 0usize;
    while i < stock.len() && j < modified.len() {
        if stock[i] == modified[j] {
            i += 1;
            j += 1;
            continue;
        }
        let mut shift = None;
        for (ds, dm) in [(8, 0), (0, 8), (4, 0), (0, 4), (16, 0), (0, 16)] {
            let run = match_run(stock, i + ds, modified, j + dm, 24);
            // Blank padding matches everywhere. A real shift is followed by
            // the same non-zero bytes, such as a name.
            let solid = run >= 16 && (0..run).any(|n| stock.get(i + ds + n).copied().unwrap_or(0) != 0);
            if solid && shift.map(|(best, _, _)| run > best).unwrap_or(true) {
                shift = Some((run, ds, dm));
            }
        }
        if let Some((_, ds, dm)) = shift {
            skipped += ds + dm;
            if skipped > 32 {
                return Err("tables diverged".into());
            }
            i += ds;
            j += dm;
            continue;
        }
        let start_i = i;
        let start_j = j;
        i += 1;
        j += 1;
        while i < stock.len() && j < modified.len() && stock[i] != modified[j] {
            if match_run(stock, i, modified, j, 8) >= 8 {
                break;
            }
            if match_run(stock, i + 8, modified, j, 16) >= 16 || match_run(stock, i, modified, j + 8, 16) >= 16 {
                break;
            }
            i += 1;
            j += 1;
            if i - start_i > 40 {
                break;
            }
        }
        diffs.push(Aligned {
            stock_at: start_i,
            mod_at: start_j,
            stock_len: i - start_i,
            mod_len: j - start_j,
        });
    }
    let tail = stock.len() - i + modified.len() - j;
    if tail > 16 {
        return Err("tables diverged".into());
    }
    Ok((diffs, skipped))
}

fn no_zero(buf: &[u8]) -> bool {
    !buf.is_empty() && buf.iter().all(|byte| *byte != 0)
}

/// A file-swap payload is a whole table sealed against one stock file. A
/// later game file of the same table still has the mod's field edits at the
/// same offsets, and also carries that older file's size words, offsets and
/// hashes. Those must not be copied: doing so shifts the strings. The edits
/// worth keeping are a small aligned integer whose neighbours did not move.
fn port_aligned_fields(stock: &[u8], modified: &[u8]) -> Result<Vec<u8>, String> {
    let (diffs, _) = align_tables(stock, modified)?;
    let size_fields: Vec<usize> = headers(stock).into_iter().map(|(at, _, _)| at + 12).collect();
    let in_size = |at: usize| size_fields.iter().any(|field| *field <= at && at < field + 4);
    let mut edits = Vec::new();
    let mut ignored = 0usize;
    for diff in &diffs {
        if let Some(value) = flag_edit(stock, modified, diff) {
            edits.push((diff.stock_at, value));
            continue;
        }
        if ignorable_shift(stock, modified, diff, in_size) {
            ignored += diff.stock_len.max(diff.mod_len);
            if ignored > 64 {
                return Err("tables diverged".into());
            }
            continue;
        }
        return Err(format!("unported edit at {}", diff.stock_at));
    }
    if edits.is_empty() {
        return Err("no field edits".into());
    }
    let mut out = stock.to_vec();
    for (at, value) in edits {
        out[at..at + 4].copy_from_slice(&value.to_le_bytes());
    }
    Ok(out)
}

/// The "settle on walkable ground" flag is a count of 2 or 3, stored after a
/// zero word. The mod drops it by 2. The following word is a separate count
/// and stays put.
fn flag_edit(stock: &[u8], modified: &[u8], diff: &Aligned) -> Option<u32> {
    if diff.stock_len != 1 || diff.mod_len != 1 || diff.stock_at % 4 != 0 || diff.mod_at % 4 != 0 {
        return None;
    }
    let stock_v = u32_at(stock, diff.stock_at)?;
    let mod_v = u32_at(modified, diff.mod_at)?;
    if stock_v > 3 || mod_v != stock_v.wrapping_sub(2) {
        return None;
    }
    if u32_at(stock, diff.stock_at.checked_sub(4)?)? != 0 || u32_at(modified, diff.mod_at.checked_sub(4)?)? != 0 {
        return None;
    }
    let next = u32_at(stock, diff.stock_at + 4)?;
    if next == 0 || next != u32_at(modified, diff.mod_at + 4)? {
        return None;
    }
    Some(mod_v)
}

fn ignorable_shift(stock: &[u8], modified: &[u8], diff: &Aligned, in_size: impl Fn(usize) -> bool) -> bool {
    if diff.stock_len == diff.mod_len && diff.stock_len >= 4 {
        let s = &stock[diff.stock_at..diff.stock_at + diff.stock_len];
        let m = &modified[diff.mod_at..diff.mod_at + diff.mod_len];
        if no_zero(s) && no_zero(m) {
            return true;
        }
    }
    if (0..diff.stock_len).any(|n| in_size(diff.stock_at + n)) {
        return true;
    }
    if diff.stock_len != 1 || diff.mod_len != 1 {
        return false;
    }
    let s_align = diff.stock_at & !3;
    let m_align = diff.mod_at & !3;
    let (Some(stock_v), Some(mod_v)) = (u32_at(stock, s_align), u32_at(modified, m_align)) else {
        return false;
    };
    let delta = stock_v.abs_diff(mod_v);
    if delta > 0 && delta % 8 == 0 && (16..200_000).contains(&stock_v) && (16..200_000).contains(&mod_v) {
        return true;
    }
    // A count sitting between zero words, off by 2 or 8, is an offset table
    // adjusting for the shift. The flag edit never has a zero word after it.
    diff.stock_at % 4 == 0
        && diff.mod_at % 4 == 0
        && stock_v <= 255
        && mod_v <= 255
        && (delta == 2 || delta == 8)
        && u32_at(stock, diff.stock_at + 4) == Some(0)
        && u32_at(modified, diff.mod_at + 4) == Some(0)
}

/// Paint `mods` (sealed, load order) onto `base_sealed`. Diffs are taken
/// against `stock_sealed`. The result's plaintext murmur is the stock murmur.
pub fn paint(stock_sealed: &[u8], base_sealed: &[u8], mods: &[&[u8]]) -> Result<Vec<u8>, String> {
    let stock = seal_open(stock_sealed);
    let mut base = seal_open(base_sealed);
    if base.len() != stock.len() {
        return Err("base table length does not match stock".into());
    }
    let target = murmur64(&stock);
    for sealed in mods {
        let plain = seal_open(sealed);
        for (at, data) in content_diffs(&stock, &plain)? {
            let end = at + data.len();
            if end > base.len() {
                return Err(format!("edit at {at} runs past the table"));
            }
            base[at..end].copy_from_slice(&data);
        }
    }
    for (at, _, _) in headers(&base) {
        if base.get(at + 16) != Some(&1) {
            return Err("bad header flag".into());
        }
        for k in 17..24 {
            if at + k >= base.len() {
                return Err("header salt runs past the table".into());
            }
            base[at + k] = 0;
        }
    }
    correct(&mut base, target, &[])?;
    let sealed = seal(&base);
    let check = seal_open(&sealed);
    if murmur64(&check) != target {
        return Err("reseal failed".into());
    }
    for (at, data) in {
        let stock_plain = seal_open(stock_sealed);
        let mut expected = stock_plain.clone();
        for sealed in mods {
            let plain = seal_open(sealed);
            for (at, data) in content_diffs(&stock_plain, &plain)? {
                expected[at..at + data.len()].copy_from_slice(&data);
            }
        }
        content_diffs(&stock, &expected)?
    } {
        if check.get(at..at + data.len()) != Some(data.as_slice()) {
            return Err(format!("edit lost at {at}"));
        }
    }
    Ok(sealed)
}

fn record_path(data_dir: &Path) -> PathBuf {
    data_dir.join(RECORD_NAME)
}

pub fn recorded_files(data_dir: &Path) -> Vec<String> {
    let Ok(bytes) = fs::read(record_path(data_dir)) else {
        return Vec::new();
    };
    serde_json::from_slice::<SwapRecord>(&bytes)
        .map(|record| record.files)
        .unwrap_or_default()
}

pub fn write_record(data_dir: &Path, files: &[String]) -> anyhow::Result<()> {
    let path = record_path(data_dir);
    if files.is_empty() {
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => return Err(err).with_context(|| format!("remove {}", path.display())),
        }
        return Ok(());
    }
    let data = serde_json::to_vec_pretty(&SwapRecord { files: files.to_vec() }).context("encode file-swap record")?;
    fs::write(&path, data).with_context(|| format!("write {}", path.display()))
}

fn stock_candidate(data_dir: &Path, name: &str) -> Vec<PathBuf> {
    let mut paths = vec![data_dir.join("ordnance-stock").join(name)];
    if let Some(root) = data_dir.parent() {
        paths.push(root.join(format!("HD2FileMods.{name}.original")));
    }
    paths
}

fn tried_stock(data_dir: &Path, name: &str) -> Vec<String> {
    stock_candidate(data_dir, name)
        .into_iter()
        .filter(|path| path.is_file())
        .map(|path| path.display().to_string())
        .collect()
}

fn stock_mismatch(payload: &Payload, tried: &[String]) -> anyhow::Error {
    let expected = if payload.stock_fingerprints.is_empty() {
        return anyhow::anyhow!("{} names {} but lists no stock fingerprint", payload.label, payload.target);
    } else {
        payload
            .stock_fingerprints
            .iter()
            .map(|fp| fp.split(':').next().unwrap_or(fp))
            .collect::<Vec<_>>()
            .join(" or ")
    };
    anyhow::anyhow!(
        "{} was built against a different {} (expected a {expected}-byte stock file), so it was not applied. Stock checked: {}",
        payload.label,
        payload.target,
        if tried.is_empty() { "none on disk".to_string() } else { tried.join(", ") }
    )
}

/// The stock backup the swap is painted onto. A fingerprint miss is not
/// fatal here: the caller ports field edits when the tables still line up.
fn stock_bytes(data_dir: &Path, payload: &Payload) -> anyhow::Result<Vec<u8>> {
    if payload.stock_fingerprints.is_empty() {
        bail!("{} names {} but lists no stock fingerprint", payload.label, payload.target);
    }
    for path in stock_candidate(data_dir, &payload.target) {
        if !path.is_file() {
            continue;
        }
        let bytes = fs::read(&path).with_context(|| format!("read {}", path.display()))?;
        let kept = data_dir.join("ordnance-stock").join(&payload.target);
        if !kept.is_file() {
            if let Some(parent) = kept.parent() {
                fs::create_dir_all(parent).ok();
            }
            fs::copy(&path, &kept).with_context(|| format!("keep stock {}", kept.display()))?;
        }
        return Ok(bytes);
    }
    Err(stock_mismatch(payload, &[]))
}

/// Paint every payload. A payload that does not fit the current table is
/// reported in [`PaintOutcome::skipped`] and left out. The others are
/// still painted. Only a failure while writing the result stops the call.
pub fn paint_all(data_dir: &Path, payloads: &[Payload], base_dir: Option<&Path>) -> anyhow::Result<PaintOutcome> {
    let dir = std::env::temp_dir().join(format!(
        "ordnance-swap-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let mut painted = Painted { dir, files: Vec::new() };
    let mut skipped = Vec::new();
    let mut by_target: Vec<(String, Vec<&Payload>)> = Vec::new();
    for payload in payloads {
        if let Some((_, group)) = by_target.iter_mut().find(|(name, _)| name == &payload.target) {
            group.push(payload);
        } else {
            by_target.push((payload.target.clone(), vec![payload]));
        }
    }
    for (target, group) in by_target {
        let stock = match stock_bytes(data_dir, group[0]) {
            Ok(bytes) => bytes,
            Err(err) => {
                let message = format!("{err:#}");
                log::info!("file swap {target}: leaving it alone ({message})");
                for payload in &group {
                    skipped.push(skip_payload(payload, message.clone()));
                }
                continue;
            }
        };
        let fp = fingerprint(&stock);
        let mut ported: Vec<Vec<u8>> = Vec::new();
        let mut kept: Vec<&Payload> = Vec::new();
        for payload in &group {
            if payload.stock_fingerprints.iter().any(|stock_fp| stock_fp == &fp) {
                ported.push(payload.sealed.clone());
                kept.push(payload);
                continue;
            }
            let stock_plain = seal_open(&stock);
            match port_aligned_fields(&stock_plain, &seal_open(&payload.sealed)) {
                Ok(edited) => {
                    let changed = edited.iter().zip(&stock_plain).filter(|(got, was)| got != was).count();
                    log::info!(
                        "file swap {target}: {} was built for a different stock file; ported {changed} bytes of field edits onto the current one",
                        payload.label
                    );
                    ported.push(seal(&edited));
                    kept.push(payload);
                }
                Err(err) => {
                    log::info!("file swap {}: leaving the current {} alone ({err})", payload.label, target);
                    let message = format!("{:#}", stock_mismatch(payload, &tried_stock(data_dir, &payload.target)));
                    skipped.push(skip_payload(payload, message));
                }
            }
        }
        if kept.is_empty() {
            continue;
        }
        let base_path = base_dir.map(|dir| dir.join(&target)).filter(|path| path.is_file());
        let base = match &base_path {
            Some(path) => fs::read(path).with_context(|| format!("read {}", path.display()))?,
            None => stock.clone(),
        };
        let mods: Vec<&[u8]> = ported.iter().map(|bytes| bytes.as_slice()).collect();
        let sealed = match paint(&stock, &base, &mods) {
            Ok(bytes) => bytes,
            Err(err) => {
                let message = format!("paint {target}: {err}");
                log::info!("{message}");
                for payload in &kept {
                    skipped.push(skip_payload(payload, message.clone()));
                }
                continue;
            }
        };
        fs::write(painted.dir.join(&target), &sealed).with_context(|| format!("write painted {target}"))?;
        log::info!(
            "file swap {target}: {}",
            kept.iter().map(|payload| payload.label.as_str()).collect::<Vec<_>>().join(", ")
        );
        painted.files.push(target);
    }
    Ok(PaintOutcome { painted, skipped })
}

fn skip_payload(payload: &Payload, message: String) -> PaintSkip {
    let mod_name = if payload.mod_name.is_empty() { payload.label.clone() } else { payload.mod_name.clone() };
    PaintSkip { mod_name, source: payload.source.clone(), message }
}

/// Copy `names` back from the vanilla stock. Missing stock is logged.
pub fn restore_files(data_dir: &Path, names: &[String]) -> anyhow::Result<()> {
    let game = data_dir.join("game");
    for name in names {
        let Some(stock) = stock_candidate(data_dir, name).into_iter().find(|path| path.is_file()) else {
            log::warn!("no stock backup for {name}; leaving the game file as it is");
            continue;
        };
        fs::copy(&stock, game.join(name)).with_context(|| format!("restore {name} from {}", stock.display()))?;
        log::info!("restored {name} from {}", stock.display());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn section(body: &[u8]) -> Vec<u8> {
        let mut raw = vec![0u8; 24 + body.len()];
        raw[..8].copy_from_slice(b"LDLD\x01\x00\x00\x00");
        raw[8..12].copy_from_slice(&1u32.to_le_bytes());
        raw[12..16].copy_from_slice(&(body.len() as u32).to_le_bytes());
        raw[16] = 1;
        raw[24..].copy_from_slice(body);
        raw
    }

    #[test]
    fn an_installer_mention_is_not_a_payload() {
        let blob = b"HD2FM1\"\n-- notes about a payload that is not this file";
        assert!(parse_hd2fm(blob).is_none());
    }

    #[test]
    fn a_record_exposes_its_target_and_sealed_bytes() {
        let sealed = b"sealed-bytes-padding-to-clear-the-minimum-length!!";
        assert!(sealed.len() >= 48);
        let head = format!("target=data/game/generated_demo.dl_bin\nsize={}\nstock=1:AA\n", sealed.len());
        let mut blob = b"HD2FM1".to_vec();
        blob.extend_from_slice(&(head.len() as u32).to_le_bytes());
        blob.extend_from_slice(head.as_bytes());
        blob.extend_from_slice(sealed);
        let parsed = parse_hd2fm(&blob).unwrap();
        assert_eq!(parsed.target, "generated_demo.dl_bin");
        assert_eq!(parsed.sealed, sealed);
        assert_eq!(parsed.stock_fingerprints, vec!["1:AA".to_string()]);
    }

    #[test]
    fn an_edit_reseals_when_the_nearest_salt_is_after_the_correction_header() {
        // The last aligned header is the correction word. The header after
        // it is closer than the one before it, which is the layout of
        // generated_stratagem_settings.dl_bin.
        let mut plain = section(&[0x11; 64]);
        plain.extend(section(&[0x22; 9]));
        plain.extend(section(&[0x33; 8]));
        let found = headers(&plain);
        assert_eq!(found.iter().map(|(at, _, _)| *at).collect::<Vec<_>>(), vec![0, 88, 121]);
        let mut edited = plain.clone();
        edited[24] = 0x5A;
        let stock = seal(&plain);
        let modified = seal(&edited);
        let out = paint(&stock, &stock, &[&modified]).expect("reseal");
        let got = seal_open(&out);
        assert_eq!(got[24], 0x5A);
        assert_eq!(murmur64(&got), murmur64(&plain));
    }

    #[test]
    fn a_byte_edit_survives_the_reseal() {
        let stock_plain = {
            let mut plain = section(&[0x11; 8]);
            plain.extend(section(&[0x22; 8]));
            plain
        };
        let mut mod_plain = stock_plain.clone();
        mod_plain[24] = 0x5A;
        let stock = seal(&stock_plain);
        let modified = seal(&mod_plain);
        let out = paint(&stock, &stock, &[&modified]).unwrap();
        let plain = seal_open(&out);
        assert_eq!(plain[24], 0x5A);
        assert_eq!(murmur64(&plain), murmur64(&stock_plain));
    }

    fn flag_body() -> Vec<u8> {
        let mut body = vec![0u8; 64];
        body[4] = 2;
        body[8..12].copy_from_slice(&12u32.to_le_bytes());
        body[16..20].copy_from_slice(&19224u32.to_le_bytes());
        body[24..28].copy_from_slice(&[0xAB, 0xCD, 0xEF, 0x11]);
        body
    }

    #[test]
    fn a_shifted_table_keeps_the_flag_and_drops_the_old_file_bytes() {
        let stock_plain = section(&flag_body());
        let mut mod_body = flag_body();
        mod_body[4] = 0;
        mod_body[16] = 0x10;
        mod_body[24..28].copy_from_slice(&[0x12, 0x34, 0x56, 0x78]);
        mod_body.extend_from_slice(&[0xFF; 8]);
        let mod_plain = section(&mod_body);
        let ported = port_aligned_fields(&stock_plain, &mod_plain).unwrap();
        assert_eq!(ported.len(), stock_plain.len());
        let mut expected = stock_plain.clone();
        expected[28] = 0;
        assert_eq!(ported, expected);
    }

    #[test]
    fn a_float_change_is_not_ported_onto_a_different_table() {
        let stock_plain = section(&flag_body());
        let mut mod_body = flag_body();
        mod_body[4] = 0;
        mod_body[32..36].copy_from_slice(&1.5f32.to_le_bytes());
        let mod_plain = section(&mod_body);
        assert!(port_aligned_fields(&stock_plain, &mod_plain).is_err());
    }

    #[test]
    fn one_swap_that_does_not_fit_is_left_out_and_the_other_is_painted() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        let stock_plain = {
            let mut plain = section(&[0x11; 8]);
            plain.extend(section(&[0x22; 8]));
            plain
        };
        let stock_sealed = seal(&stock_plain);
        let mut good_plain = stock_plain.clone();
        good_plain[24] = 0x5A;
        let mut bad_body = flag_body();
        bad_body[32..36].copy_from_slice(&1.5f32.to_le_bytes());
        let bad_plain = section(&bad_body);
        let name = "generated_test.dl_bin";
        std::fs::create_dir_all(data.join("ordnance-stock")).unwrap();
        std::fs::write(data.join("ordnance-stock").join(name), &stock_sealed).unwrap();
        let good = Payload {
            label: "Good".into(),
            mod_name: "Good Mod".into(),
            source: dir.path().join("good.patch_0"),
            target: name.into(),
            sealed: seal(&good_plain),
            stock_fingerprints: vec![fingerprint(&stock_sealed)],
        };
        let bad = Payload {
            label: "Bad".into(),
            mod_name: "Bad Mod".into(),
            source: dir.path().join("bad.patch_0"),
            target: name.into(),
            sealed: seal(&bad_plain),
            stock_fingerprints: vec!["999:00".into()],
        };
        let outcome = paint_all(&data, &[bad, good], None).unwrap();
        assert_eq!(outcome.skipped.len(), 1);
        assert_eq!(outcome.skipped[0].mod_name, "Bad Mod");
        assert!(outcome.skipped[0].message.contains("was not applied"));
        assert_eq!(outcome.painted.files, vec![name.to_string()]);
        let painted = seal_open(&std::fs::read(outcome.painted.dir.join(name)).unwrap());
        assert_eq!(painted[24], 0x5A);
    }

    #[test]
    fn the_installed_stratagem_mod_ports_onto_the_current_stock() {
        let Some(home) = std::env::var_os("HOME") else {
            return;
        };
        let root = PathBuf::from(home);
        let stock_path = root.join(".local/share/Steam/steamapps/common/Helldivers 2/data/ordnance-stock/generated_stratagem_settings.dl_bin");
        let patch_path = root.join(".local/share/com.cavadus.ordnance/mods/Stratagem Balls Stay Put 1.0.3/Install/b5b0c0ffee5b5b10.patch_0");
        if !stock_path.is_file() || !patch_path.is_file() {
            return;
        }
        let stock = std::fs::read(&stock_path).unwrap();
        let patch = std::fs::read(&patch_path).unwrap();
        let payload = parse_hd2fm(&patch).unwrap();
        // The port only runs when the mod's recorded stock is not the table
        // on disk. Once those match, deploy paints the payload directly and
        // this scenario no longer applies. Windows CI has no HOME.
        if payload.stock_fingerprints.iter().any(|fp| fp == &fingerprint(&stock)) {
            return;
        }
        let stock_plain = seal_open(&stock);
        let ported = port_aligned_fields(&stock_plain, &seal_open(&payload.sealed)).unwrap();
        let changed: Vec<usize> = ported
            .iter()
            .zip(&stock_plain)
            .enumerate()
            .filter(|(_, (got, was))| got != was)
            .map(|(at, _)| at)
            .collect();
        assert_eq!(changed.len(), 105, "the mod clears one flag byte on 105 stratagems");
        for at in &changed {
            assert_eq!(*at % 4, 0);
            assert_eq!(ported[*at + 1], 0);
            assert!(stock_plain[*at] == 2 || stock_plain[*at] == 3);
            assert_eq!(ported[*at], stock_plain[*at] - 2);
        }
        let out = paint(&stock, &stock, &[&seal(&ported)]).unwrap();
        let plain = seal_open(&out);
        for at in &changed {
            assert_eq!(plain[*at], stock_plain[*at] - 2);
        }
        assert_eq!(murmur64(&plain), murmur64(&stock_plain));
    }
}
