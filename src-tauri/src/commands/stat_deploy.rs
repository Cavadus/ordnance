//! Stat-mod plan applier — pure Rust (no Python runtime).
//!
//! Plans are self-describing: every edit names its "file", section "type"
//! and geometry ("buckets" + "stride" for keyed tables, "stride" for row
//! tables). Ordnance carries no knowledge of game tables; a missing or wrong
//! layout is the plan author's bug, not ours.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context};
use serde_json::Value;

use super::hd2edit::{correct, headers, murmur64, put_f32, put_u32, rd64, rd_f32, rd_u32, seal, seal_open};

/// Holds the temp directory the resealed ".dl_bin" files were written into,
/// deleting it on drop. Hold it until the files are copied into data/game/.
pub struct OutHold {
    pub dir: PathBuf,
}

impl Drop for OutHold {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Python plan.py's hx helper: an int, or a "0x.."/decimal string.
fn hx(v: &Value) -> u64 {
    match v {
        Value::Number(n) => n.as_u64().unwrap_or(0),
        Value::String(s) => {
            let s = s.trim();
            if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
                u64::from_str_radix(hex, 16).unwrap_or(0)
            } else {
                s.parse::<u64>().unwrap_or(0)
            }
        }
        _ => 0,
    }
}

fn fval(v: &Value) -> f32 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(0.0) as f32,
        Value::String(s) => s.trim().parse::<f32>().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// Table geometry the plan's author must supply. Ordnance carries no table
/// layouts, so a missing or wrong value is the mod author's bug.
fn req(e: &Value, key: &str) -> anyhow::Result<usize> {
    match e.get(key) {
        Some(v) if !v.is_null() => Ok(hx(v) as usize),
        _ => bail!("stat-plan edit is missing \"{key}\" (plans must carry their own table layout)"),
    }
}

fn find_record(blob: &[u8], base: usize, stride: usize, rid: u32) -> anyhow::Result<usize> {
    let count = rd_u32(blob, base + 8) as usize;
    for i in 0..count {
        let o = base + 16 + i * stride;
        if rd_u32(blob, o) == rid {
            return Ok(o);
        }
    }
    bail!("record {rid} not found")
}

fn find_keyed(
    blob: &[u8],
    tid: u32,
    lo: u32,
    hi: u32,
    buckets: usize,
    stride: usize,
) -> anyhow::Result<usize> {
    for (at, t, _s) in headers(blob) {
        if t == tid {
            let base = at + 24;
            for k in 0..buckets {
                let e = base + k * 16;
                if rd_u32(blob, e) == lo && rd_u32(blob, e + 4) == hi {
                    return Ok(base + buckets * 16 + rd_u32(blob, e + 8) as usize * stride);
                }
            }
            bail!("entity not found in {tid:x}");
        }
    }
    bail!("table {tid:x} not found")
}

fn do_op(
    blob: &mut [u8],
    off: usize,
    op: &str,
    kind: &str,
    value: &Value,
    floats: &mut Vec<usize>,
) -> anyhow::Result<()> {
    match op {
        "set" => {
            if kind == "f32" {
                put_f32(blob, off, fval(value));
                floats.push(off);
            } else {
                put_u32(blob, off, hx(value) as u32);
            }
        }
        "mul" => {
            if kind == "u32" {
                let v = (rd_u32(blob, off) as f64 * fval(value) as f64).round();
                put_u32(blob, off, v.clamp(0.0, u32::MAX as f64) as u32);
            } else {
                put_f32(blob, off, rd_f32(blob, off) * fval(value));
                floats.push(off);
            }
        }
        "add" => {
            if kind == "u32" {
                let d = (fval(value) as f64).round() as i64;
                put_u32(blob, off, (rd_u32(blob, off) as i64 + d).clamp(0, u32::MAX as i64) as u32);
            } else {
                put_f32(blob, off, rd_f32(blob, off) + fval(value));
                floats.push(off);
            }
        }
        _ => bail!("bad op {op}"),
    }
    Ok(())
}

fn apply_edit(blob: &mut [u8], e: &Value, floats: &mut Vec<usize>) -> anyhow::Result<()> {
    let table = e.get("file").and_then(|v| v.as_str()).unwrap_or("");
    let op = e.get("op").and_then(|v| v.as_str()).unwrap_or("");

    if e.get("lo").is_some() {
        let tid = hx(&e["type"]) as u32;
        let lo = hx(&e["lo"]) as u32;
        let hi = hx(&e["hi"]) as u32;
        let rec = find_keyed(blob, tid, lo, hi, req(e, "buckets")?, req(e, "stride")?)?;
        let off = rec + e["offset"].as_u64().unwrap_or(0) as usize;
        do_op(blob, off, op, e["kind"].as_str().unwrap_or(""), &e["value"], floats)
    } else if op == "clone" {
        let (tid, stride) = (req(e, "type")? as u32, req(e, "stride")?);
        let base = headers(blob)
            .iter()
            .find(|(_, t, _)| *t == tid)
            .map(|(at, _, _)| at + 24)
            .with_context(|| format!("clone header for {table}"))?;
        let src = find_record(blob, base, stride, hx(&e["src"]) as u32)?;
        let dst = find_record(blob, base, stride, hx(&e["dst"]) as u32)?;
        let src_ptr = rd64(blob, src + 40);
        let dst_ptr = rd64(blob, dst + 40);
        let mut clone = blob[src..src + stride].to_vec();
        put_u32(&mut clone, 0, hx(&e["dst"]) as u32);
        if let Some(fields) = e["fields"].as_object() {
            for (k, v) in fields {
                let off = k.parse::<usize>().unwrap_or(0);
                put_f32(&mut clone, off, fval(v));
                floats.push(dst + off);
            }
        }
        clone[40..48].copy_from_slice(&blob[dst + 40..dst + 48]);
        blob[dst..dst + stride].copy_from_slice(&clone);
        let ptr_src = blob[base + src_ptr as usize..base + src_ptr as usize + 8].to_vec();
        blob[base + dst_ptr as usize..base + dst_ptr as usize + 8].copy_from_slice(&ptr_src);
        Ok(())
    } else {
        let (tid, stride) = (req(e, "type")? as u32, req(e, "stride")?);
        let base = headers(blob)
            .iter()
            .find(|(_, t, _)| *t == tid)
            .map(|(at, _, _)| at + 24)
            .with_context(|| format!("table header for {table}"))?;
        let rec = find_record(blob, base, stride, hx(&e["record"]) as u32)?;
        let off = rec + e["offset"].as_u64().unwrap_or(0) as usize;
        do_op(blob, off, op, e["kind"].as_str().unwrap_or(""), &e["value"], floats)
    }
}

fn apply_plan_inner(plan: &[Value], stock_dir: &Path, out_dir: &Path) -> anyhow::Result<()> {
    let mut groups: HashMap<String, Vec<&Value>> = HashMap::new();
    for e in plan {
        let key = e
            .get("file")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if key.is_empty() && e.get("table").is_some() {
            bail!("legacy stat-plan edit (\"table\" without \"file\"): the mod's author must update it to the self-describing format");
        }
        if key.is_empty()
            || key.contains('/')
            || key.contains('\\')
            || key.contains("..")
            || !key.ends_with(".dl_bin")
        {
            bail!("stat-plan edit has a missing or invalid \"file\": {key:?} (expected a bare generated_*.dl_bin name)");
        }
        groups.entry(key).or_default().push(e);
    }

    for (filename, edits) in &groups {
        if filename.is_empty() {
            bail!("unknown table in plan (no file mapping)");
        }
        let sealed_bytes =
            fs::read(stock_dir.join(filename)).with_context(|| format!("read {filename}"))?;
        let mut blob = seal_open(&sealed_bytes);
        let target = murmur64(&blob);
        let mut floats: Vec<usize> = Vec::new();
        let header_ats: Vec<usize> = headers(&blob).iter().map(|(a, _, _)| *a).collect();
        for e in edits {
            apply_edit(&mut blob, e, &mut floats).with_context(|| format!("edit in {filename}"))?;
        }
        for at in header_ats {
            if blob[at + 16] != 1 {
                bail!("bad header flag in {filename}");
            }
            for k in 17..24 {
                blob[at + k] = 0;
            }
        }
        correct(&mut blob, target, &floats).map_err(|e| anyhow::anyhow!("{e} in {filename}"))?;
        if murmur64(&blob) != target {
            bail!("hash correction failed: {filename}");
        }
        let sealed = seal(&blob);
        if murmur64(&seal_open(&sealed)) != target {
            bail!("round trip failed: {filename}");
        }
        fs::write(out_dir.join(filename), &sealed).with_context(|| format!("write {filename}"))?;
        log::info!("wrote {filename}");
    }
    Ok(())
}

pub fn apply_plan(plan_json: &str, stock_dir: &Path) -> anyhow::Result<OutHold> {
    let plan: Vec<Value> = serde_json::from_str(plan_json).context("parse plan")?;
    let dir = std::env::temp_dir().join(format!(
        "ordnance-stat-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    apply_plan_inner(&plan, stock_dir, &dir)?;
    Ok(OutHold { dir })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// One LDLD section: 24-byte header (magic, version, type, size, flag, 0) + body.
    fn section(typ: u32, body: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        for w in [0x444C_444Cu32, 1, typ, body.len() as u32, 1, 0] {
            v.extend_from_slice(&w.to_le_bytes());
        }
        v.extend_from_slice(body);
        v
    }

    fn keyed_body(buckets: usize, stride: usize, entries: &[(usize, u32, u32, u32)], nrec: usize) -> Vec<u8> {
        let mut b = vec![0u8; buckets * 16 + nrec * stride];
        for &(k, lo, hi, idx) in entries {
            b[k * 16..k * 16 + 4].copy_from_slice(&lo.to_le_bytes());
            b[k * 16 + 4..k * 16 + 8].copy_from_slice(&hi.to_le_bytes());
            b[k * 16 + 8..k * 16 + 12].copy_from_slice(&idx.to_le_bytes());
        }
        b
    }

    fn row_body(stride: usize, ids: &[u32]) -> Vec<u8> {
        let mut b = vec![0u8; 16 + ids.len() * stride];
        b[8..12].copy_from_slice(&(ids.len() as u32).to_le_bytes());
        for (i, id) in ids.iter().enumerate() {
            let o = 16 + i * stride;
            b[o..o + 4].copy_from_slice(&id.to_le_bytes());
        }
        b
    }

    #[test]
    fn keyed_edit_uses_plan_geometry() {
        let mut blob = section(0xAAAA_0001, &keyed_body(4, 8, &[(2, 0x11, 0x22, 1)], 2));
        let e = json!({"file": "generated_entities.dl_bin", "type": "0xaaaa0001", "lo": "0x11", "hi": "0x22",
                       "buckets": 4, "stride": 8, "offset": 4, "kind": "u32", "value": 7, "op": "set"});
        apply_edit(&mut blob, &e, &mut Vec::new()).unwrap();
        assert_eq!(rd_u32(&blob, 24 + 4 * 16 + 8 + 4), 7);
    }

    #[test]
    fn missing_geometry_is_an_author_error() {
        let mut blob = section(0xAAAA_0001, &keyed_body(4, 8, &[(2, 0x11, 0x22, 1)], 2));
        let e = json!({"file": "generated_entities.dl_bin", "type": "0xaaaa0001", "lo": "0x11", "hi": "0x22",
                       "offset": 4, "kind": "u32", "value": 7, "op": "set"});
        let err = apply_edit(&mut blob, &e, &mut Vec::new()).unwrap_err().to_string();
        assert!(err.contains("buckets"), "{err}");
    }

    #[test]
    fn row_edit_with_integer_add_and_mul() {
        let mut blob = section(0xBBBB_0002, &row_body(12, &[5, 9]));
        let rec = 24 + 16 + 12;
        put_u32(&mut blob, rec + 4, 10);
        let mut floats = Vec::new();
        let add = json!({"file": "generated_damage_settings.dl_bin", "type": "0xbbbb0002", "stride": 12, "record": 9,
                         "offset": 4, "kind": "u32", "value": 3, "op": "add"});
        apply_edit(&mut blob, &add, &mut floats).unwrap();
        assert_eq!(rd_u32(&blob, rec + 4), 13);
        let mul = json!({"file": "generated_damage_settings.dl_bin", "type": "0xbbbb0002", "stride": 12, "record": 9,
                         "offset": 4, "kind": "u32", "value": 2, "op": "mul"});
        apply_edit(&mut blob, &mul, &mut floats).unwrap();
        assert_eq!(rd_u32(&blob, rec + 4), 26);
        assert!(floats.is_empty(), "integer ops must not be recorded as float edits");
    }

    #[test]
    fn plan_file_must_be_a_bare_dl_bin_name() {
        let tmp = std::env::temp_dir().join(format!("ordnance-sd-test-{}", std::process::id()));
        for bad in ["../evil.dl_bin", "sub/x.dl_bin", "", "x.txt"] {
            let plan = vec![json!({"file": bad, "type": "0x1", "stride": 4, "record": 1, "offset": 0,
                                   "kind": "u32", "value": 1, "op": "set"})];
            let err = apply_plan_inner(&plan, &tmp, &tmp).unwrap_err().to_string();
            assert!(err.contains("file"), "{bad}: {err}");
        }
    }

    #[test]
    fn legacy_table_plans_are_rejected_with_an_author_message() {
        let tmp = std::env::temp_dir();
        let plan = vec![json!({"table": "entities", "type": "0x1", "lo": 1, "hi": 2, "offset": 0,
                               "kind": "u32", "value": 1, "op": "set"})];
        let err = apply_plan_inner(&plan, &tmp, &tmp).unwrap_err().to_string();
        assert!(err.contains("legacy"), "{err}");
    }
}
