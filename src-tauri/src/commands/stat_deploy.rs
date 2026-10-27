//! Stat-mod plan applier.
//!
//! A stat mod ships a declarative edit list ("stat-plan.json", a JSON array of
//! offset-based edits in "compiler/plan.py" format) instead of a finished
//! ".dl_bin". This embeds "plan.py" + "hd2edit.py" and runs them against the
//! stock ".dl_bin" tables, writing one resealed file per table.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context};

const PLAN_PY: &str = include_str!("../../../compiler/plan.py");
const HD2EDIT_PY: &str = include_str!("../../../compiler/hd2edit.py");

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

/// Applies a merged plan (a JSON array of edits) to the stock ".dl_bin"
/// files in stock_dir, writing resealed files into a fresh temp dir that the
/// returned OutHold keeps alive.
pub fn apply_plan(plan_json: &str, stock_dir: &Path) -> anyhow::Result<OutHold> {
    let dir = std::env::temp_dir().join(format!(
        "ordnance-stat-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    fs::write(dir.join("plan.py"), PLAN_PY).context("write plan.py")?;
    fs::write(dir.join("hd2edit.py"), HD2EDIT_PY).context("write hd2edit.py")?;
    fs::write(dir.join("plan.json"), plan_json).context("write plan.json")?;

    let ran = Command::new("python3")
        .arg(dir.join("plan.py"))
        .arg(dir.join("plan.json"))
        .arg("--stock")
        .arg(stock_dir)
        .arg("--out")
        .arg(&dir)
        .output()
        .context("run python3 on the stat-plan applier")?;

    if !ran.status.success() {
        bail!(
            "stat-plan applier failed: {}",
            String::from_utf8_lossy(&ran.stderr).trim()
        );
    }
    Ok(OutHold { dir })
}
