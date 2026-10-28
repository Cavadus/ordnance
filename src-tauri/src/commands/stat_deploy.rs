//! Stat-mod plan applier — pure Rust (no Python runtime).

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

const TABLES: [(&str, &str, u32, usize); 3] = [
    ("projectile", "generated_projectile_settings.dl_bin", 0xBD4042C2, 272),
    ("explosion", "generated_explosion_settings.dl_bin", 0x2AEA2592, 152),
    ("damage", "generated_damage_settings.dl_bin", 0xE0A72CF0, 76),
];

const KEYED: [(u32, (usize, usize)); 3] = [
    (0x88E4DBB1, (746, 496)),
    (0xFB8D88A3, (560, 160)),
    (0x4F2CF417, (386, 32)),
];

fn keyed(tid: u32) -> Option<(usize, usize)> {
    KEYED.iter().find(|(t, _)| *t == tid).map(|(_, v)| *v)
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

fn find_keyed(blob: &[u8], tid: u32, lo: u32, hi: u32) -> anyhow::Result<usize> {
    let (buckets, stride) = keyed(tid).with_context(|| format!("unknown keyed table {tid:x}"))?;
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
            put_f32(blob, off, rd_f32(blob, off) * fval(value));
            floats.push(off);
        }
        "add" => {
            put_f32(blob, off, rd_f32(blob, off) + fval(value));
            floats.push(off);
        }
        _ => bail!("bad op {op}"),
    }
    Ok(())
}

fn apply_edit(blob: &mut [u8], e: &Value, floats: &mut Vec<usize>) -> anyhow::Result<()> {
    let table = e.get("table").and_then(|v| v.as_str()).unwrap_or("");
    let op = e.get("op").and_then(|v| v.as_str()).unwrap_or("");

    if table == "entities" {
        let tid = hx(&e["type"]) as u32;
        let lo = hx(&e["lo"]) as u32;
        let hi = hx(&e["hi"]) as u32;
        let rec = find_keyed(blob, tid, lo, hi)?;
        let off = rec + e["offset"].as_u64().unwrap_or(0) as usize;
        do_op(blob, off, op, e["kind"].as_str().unwrap_or(""), &e["value"], floats)
    } else if op == "clone" {
        let (_, _, tid, stride) = *TABLES
            .iter()
            .find(|(t, _, _, _)| *t == table)
            .with_context(|| format!("clone table {table}"))?;
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
        let (_, _, tid, stride) = *TABLES
            .iter()
            .find(|(t, _, _, _)| *t == table)
            .with_context(|| format!("table {table}"))?;
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
        let table = e.get("table").and_then(|v| v.as_str()).unwrap_or("");
        let key = if table == "entities" {
            "generated_entities.dl_bin".to_string()
        } else {
            TABLES
                .iter()
                .find(|(t, _, _, _)| *t == table)
                .map(|(_, f, _, _)| f.to_string())
                .unwrap_or_default()
        };
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
