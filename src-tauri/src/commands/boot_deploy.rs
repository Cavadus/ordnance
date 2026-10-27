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

/// `murmur64("boot")`. The engine runs this resource from the highest
/// `9ba626afa44a3aa3.patch_N` that carries it. The archive name is not the id.
pub const BOOT_RESOURCE: [u8; 8] = [0xfa, 0x95, 0x18, 0x69, 0x93, 0xdf, 0x76, 0xf4];

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

/// Lua source inside a single-payload patch.
///
/// The payload length at `0xA0` counts the 8-byte `u32 length, u32 2`
/// prefix. That pair is not at a fixed offset: Boot Mod Loader's sits at
/// 184, the test packs sit at 192.
fn lua_text(data: &[u8]) -> Option<&str> {
    let payload = u32_at(data, 0xA0)? as usize;
    if payload < 8 || payload > data.len() {
        return None;
    }
    let source_len = payload - 8;
    let needle = (source_len as u32).to_le_bytes();
    let two = 2u32.to_le_bytes();
    let last = data.len().saturating_sub(8 + source_len);
    for at in 0..=last {
        if data.get(at..at + 4) != Some(needle.as_slice()) {
            continue;
        }
        if data.get(at + 4..at + 8) != Some(two.as_slice()) {
            continue;
        }
        let source = data.get(at + 8..at + 8 + source_len)?;
        if source.starts_with(b"\x1bLJ") || source.contains(&0) {
            return None;
        }
        return std::str::from_utf8(source).ok();
    }
    None
}

/// A single-payload Lua patch whose source is text and whose header carries
/// the boot resource. Mesh, bank, and HD2FM archive payloads are not boot
/// scripts.
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
    let header = data.len().min(512);
    if !data[..header].windows(8).any(|word| word == BOOT_RESOURCE) {
        return false;
    }
    lua_text(&data).is_some()
}

fn loader_kind(text: &str) -> bool {
    text.contains("--@@LOADER@@")
        || text.contains("Chef Shared Loader")
        || text.contains("Boot Mod Loader")
        || (text.contains("HD2-Addon") && text.contains(BOOT_NAME))
}

/// A boot that is itself a mod loader. It has to deploy last: a higher boot
/// replaces it and then no addon runs.
pub fn is_loader_boot(path: &Path) -> bool {
    let Ok(data) = fs::read(path) else {
        return false;
    };
    lua_text(&data).is_some_and(loader_kind)
}

/// Plain-Lua loaders cannot run a mod that calls LuaJIT `ffi`.
fn needs_ffi(text: &str) -> bool {
    text.contains("ffi.cdef")
        || text.contains("require(\"ffi\")")
        || text.contains("require('ffi')")
}

fn plain_lua_loader(text: &str) -> bool {
    text.contains("Boot Mod Loader") || text.contains("no ffi") || text.contains("no LuaJIT")
}

#[derive(serde::Serialize)]
pub struct ModConflict {
    pub guid: String,
    pub message: String,
}

/// Conflicts the mod list should show. `mods` is the enabled set, in load order.
pub fn conflicts_for(mods: &[(String, PathBuf)]) -> Vec<ModConflict> {
    let mut loaders: Vec<String> = Vec::new();
    let mut ffi_mods: Vec<(String, bool)> = Vec::new();
    let mut plain_loader = false;
    for (guid, dir) in mods {
        let mut saw_loader = false;
        let mut saw_ffi = false;
        let mut walk = Vec::new();
        if let Ok(top) = fs::read_dir(dir) {
            for entry in top.flatten() {
                walk.push(entry.path());
            }
        } else {
            continue;
        }
        while let Some(path) = walk.pop() {
            if path.is_dir() {
                if let Ok(children) = fs::read_dir(&path) {
                    walk.extend(children.flatten().map(|child| child.path()));
                }
                continue;
            }
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !name.contains(".patch_") || name.ends_with(".stream") || name.ends_with("gpu_resources") {
                continue;
            }
            let Ok(data) = fs::read(&path) else {
                continue;
            };
            let Some(text) = lua_text(&data) else {
                continue;
            };
            if is_text_boot_script(&path) && loader_kind(text) {
                saw_loader = true;
                if plain_lua_loader(text) {
                    plain_loader = true;
                }
            }
            if needs_ffi(text) {
                saw_ffi = true;
            }
        }
        if saw_loader {
            loaders.push(guid.clone());
        }
        if saw_ffi {
            ffi_mods.push((guid.clone(), saw_loader));
        }
    }
    let mut out = Vec::new();
    if loaders.len() > 1 {
        let last = loaders.len() - 1;
        for (nth, guid) in loaders.iter().enumerate() {
            if nth == last {
                continue;
            }
            out.push(ModConflict {
                guid: guid.clone(),
                message: "Another boot loader is enabled below this one and will be deployed after it. The game runs only the highest loader.".into(),
            });
        }
    }
    if plain_loader {
        for (guid, _) in ffi_mods {
            out.push(ModConflict {
                guid,
                message: "This mod calls LuaJIT ffi. The boot loader that is enabled runs plain Lua 5.1 and will not start it.".into(),
            });
        }
    }
    out
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
        header[0x68..0x70].copy_from_slice(&BOOT_RESOURCE);
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

    #[test]
    fn a_patch_that_is_not_the_boot_resource_is_left_alone() {
        let dir = std::env::temp_dir().join(format!("ordnance-boot-id-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = pack(&dir, "other", "marker = true\n");
        let mut data = fs::read(&path).unwrap();
        data[0x68..0x70].fill(0);
        fs::write(&path, &data).unwrap();
        assert!(!is_text_boot_script(&path));
        let _ = fs::remove_dir_all(&dir);
    }

    /// Boot Mod Loader's length prefix is not at byte 192. It is still a
    /// loader, and it has to be recognized as one.
    #[test]
    fn boot_mod_loader_with_a_shifted_header_is_a_loader() {
        let source = b"-- Boot Mod Loader (local)\n";
        let payload = (source.len() + 8) as u32;
        let mut data = vec![0u8; 184];
        data[0..4].copy_from_slice(&0xF000_0011u32.to_le_bytes());
        data[4..8].copy_from_slice(&1u32.to_le_bytes());
        data[8..12].copy_from_slice(&1u32.to_le_bytes());
        data[0x50..0x58].copy_from_slice(&LUA_TYPE);
        data[0x68..0x70].copy_from_slice(&BOOT_RESOURCE);
        data[0xA0..0xA4].copy_from_slice(&payload.to_le_bytes());
        data.extend_from_slice(&(source.len() as u32).to_le_bytes());
        data.extend_from_slice(&2u32.to_le_bytes());
        data.extend_from_slice(source);
        let dir = std::env::temp_dir().join(format!("ordnance-boot-shift-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{BOOT_NAME}.patch_0"));
        fs::write(&path, &data).unwrap();
        assert!(is_text_boot_script(&path));
        assert!(is_loader_boot(&path));
        let _ = fs::remove_dir_all(&dir);
    }
}
