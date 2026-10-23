//! Deploy-time boot-script merge.
//!
//! Several enabled mods can each ship a text Lua patch named
//! `9ba626afa44a3aa3`. The game keeps one boot script. This runs
//! `compiler/bootmerge.py` (embedded) and returns the single patch Deploy
//! should copy. Asset patches that share that filename but are not Lua are
//! left for the caller to copy unchanged.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context};

pub const BOOT_NAME: &str = "9ba626afa44a3aa3";

const LUA_TYPE: [u8; 8] = [0xe2, 0x17, 0xd1, 0x2c, 0xfa, 0x8d, 0x4e, 0xa1];
const SCRIPT: &str = include_str!("../../../compiler/bootmerge.py");

/// Owns the temp directory the merged patch lives in. Dropping it deletes
/// that directory, so hold it until the patch has been copied.
pub struct Hold {
    dir: PathBuf,
}

impl Drop for Hold {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn u32_at(buf: &[u8], at: usize) -> Option<u32> {
    let bytes: [u8; 4] = buf.get(at..at + 4)?.try_into().ok()?;
    Some(u32::from_le_bytes(bytes))
}

/// A single-payload Lua patch whose source is text. Mesh, bank, and HD2FM
/// archive payloads are not boot scripts.
pub fn is_text_boot_script(path: &Path) -> bool {
    let Ok(data) = fs::read(path) else {
        return false;
    };
    let Some(magic) = u32_at(&data, 0) else {
        return false;
    };
    // Byte 4 is the container count. Byte 8 is how many resources are
    // packed in it. MDL ships two resources in one file named like the boot
    // script; that file stays whole and is not concatenated.
    if magic != 0xF000_0011 || u32_at(&data, 4) != Some(1) || u32_at(&data, 8) != Some(1) {
        return false;
    }
    if data.get(0x50..0x58) != Some(&LUA_TYPE) {
        return false;
    }
    let Some(size) = u32_at(&data, 0xC0) else {
        return false;
    };
    if u32_at(&data, 192) != Some(size) {
        return false;
    }
    let start = 200usize;
    let end = start + size as usize;
    let Some(source) = data.get(start..end) else {
        return false;
    };
    // LuaJIT bytecode (1B 4C 4A) is a loader stub, not boot-script source.
    if source.starts_with(b"\x1bLJ") || source.contains(&0) {
        return false;
    }
    std::str::from_utf8(source).is_ok()
}

/// Merge `patches` (name, path), in load order, into one boot-script patch.
pub fn merge(patches: &[(String, PathBuf)]) -> anyhow::Result<(Hold, PathBuf)> {
    if patches.len() < 2 {
        bail!("boot merge wants at least two scripts");
    }
    let dir = std::env::temp_dir().join(format!(
        "ordnance-boot-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let hold = Hold { dir: dir.clone() };
    let script = dir.join("bootmerge.py");
    let list = dir.join("boot.json");
    let out = dir.join("out");
    fs::write(&script, SCRIPT).context("write embedded bootmerge.py")?;
    let items: Vec<serde_json::Value> = patches
        .iter()
        .map(|(name, path)| {
            serde_json::json!({
                "name": name,
                "path": path,
            })
        })
        .collect();
    fs::write(&list, serde_json::to_vec(&items).context("encode boot list")?)
        .context("write boot list")?;
    let ran = Command::new("python3")
        .arg(&script)
        .arg("--list")
        .arg(&list)
        .arg("--out")
        .arg(&out)
        .output()
        .context("run python3 on the boot-script merger")?;
    if !ran.status.success() {
        bail!(
            "boot-script merge failed ({})\n{}",
            ran.status,
            String::from_utf8_lossy(&ran.stderr)
        );
    }
    let merged = out.join(format!("{BOOT_NAME}.patch_0"));
    if !merged.is_file() {
        bail!("boot-script merge wrote no {}", merged.display());
    }
    log::info!("{}", String::from_utf8_lossy(&ran.stdout).trim_end());
    Ok((hold, merged))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pack(dir: &Path, folder: &str, source: &str) -> PathBuf {
        let raw = source.as_bytes();
        let pad = (16 - ((200 + raw.len()) % 16)) % 16;
        let total = 200 + raw.len() + pad;
        let mut header = vec![0u8; 192];
        header[0..4].copy_from_slice(&0xF000_0011u32.to_le_bytes());
        header[4..8].copy_from_slice(&1u32.to_le_bytes());
        header[8..12].copy_from_slice(&1u32.to_le_bytes());
        header[0x20..0x28].copy_from_slice(&(total as u64).to_le_bytes());
        header[0x50..0x58].copy_from_slice(&LUA_TYPE);
        header[0x70..0x78].copy_from_slice(&LUA_TYPE);
        header[0xA0..0xA4].copy_from_slice(&((raw.len() + 8) as u32).to_le_bytes());
        let mut body = header;
        body.extend_from_slice(&(raw.len() as u32).to_le_bytes());
        body.extend_from_slice(&2u32.to_le_bytes());
        body.extend_from_slice(raw);
        body.extend(std::iter::repeat(0).take(pad));
        let folder = dir.join(folder);
        fs::create_dir_all(&folder).unwrap();
        let path = folder.join(format!("{BOOT_NAME}.patch_0"));
        fs::write(&path, body).unwrap();
        path
    }

    #[test]
    fn deploy_merge_keeps_both_scripts() {
        let dir = std::env::temp_dir().join(format!("ordnance-boot-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let early = pack(&dir, "early", "seen_early = true\n");
        let late = pack(&dir, "late", "seen_late = true\n");
        assert!(is_text_boot_script(&early));
        let (hold, merged) = merge(&[
            ("early".into(), early),
            ("late".into(), late),
        ])
        .unwrap();
        let data = fs::read(&merged).unwrap();
        let text = String::from_utf8_lossy(&data);
        assert!(text.contains("seen_early = true"));
        assert!(text.contains("seen_late = true"));
        assert!(text.find("seen_early").unwrap() < text.find("seen_late").unwrap());
        drop(hold);
        assert!(!merged.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_multi_resource_bundle_is_not_merged_as_a_boot_script() {
        let dir = std::env::temp_dir().join(format!("ordnance-boot-bundle-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = pack(&dir, "bundle", "marker = true\n");
        let mut data = fs::read(&path).unwrap();
        data[8..12].copy_from_slice(&2u32.to_le_bytes());
        fs::write(&path, &data).unwrap();
        assert!(!is_text_boot_script(&path));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn luajit_bytecode_is_not_a_boot_script() {
        let dir = std::env::temp_dir().join(format!("ordnance-boot-lj-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = pack(&dir, "lj", "\u{1b}LJnot-source\n");
        assert!(!is_text_boot_script(&path));
        let _ = fs::remove_dir_all(&dir);
    }
}
