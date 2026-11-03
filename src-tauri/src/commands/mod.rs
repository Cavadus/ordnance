use std::{collections::{HashMap, HashSet}, path::{Path, PathBuf}, sync::{atomic::{AtomicU64, Ordering}, OnceLock}};

use anyhow_tauri::{IntoTAResult, TAResult};
use regex::Regex;
use tauri::State;

use crate::{AppState, commands::settings::do_load_settings, models::{manifest::Manifest, profile::Config, settings::Settings, Mod}, utils::is_patch_filename};

pub mod categories;
pub mod mods;
pub mod profiles;
pub mod settings;
pub mod handoff;
pub mod updates;
pub mod nexus;
pub mod bridge;
pub mod data_folder;
pub mod import;
pub mod dialogs;
pub mod bug_report;
mod boot_deploy;
mod file_swap;
mod hd2edit;
mod stat_deploy;

static INDEX_REGEX: OnceLock<Regex> = OnceLock::new();

struct PatchFileTriplet {
    patch: Option<PathBuf>,
    gpu_resources: Option<PathBuf>,
    stream: Option<PathBuf>,
    /// Profile order. File swaps of one table are painted in this order.
    seq: u64,
}

fn next_patch_seq() -> u64 {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    SEQ.fetch_add(1, Ordering::Relaxed)
}

/// `relative` (from a mod's manifest) resolved under the mod directory
/// `base`, tolerating Windows-style backslash separators and wrong casing --
/// see [`crate::utils::fix_path_casing`].
async fn resolve_mod_path(base: &Path, relative: &Path) -> PathBuf {
    match crate::utils::fix_path_casing(base, relative).await {
        Ok(fixed) => base.join(fixed),
        Err(_) => base.join(relative),
    }
}

async fn get_patch_files_from_dir(dir: &Path) -> anyhow::Result<Vec<PathBuf>> {
    use anyhow::Context;

    log::info!("Collecting patch files of directory {:?}...", dir);

    let mut entries = Vec::new();
    let mut dir_reader = tokio::fs::read_dir(dir)
        .await
        .with_context(|| format!("can't read folder {:?}", dir))?;
    while let Some(entry) = dir_reader.next_entry().await.with_context(|| format!("can't read folder {:?}", dir))? {
        if !entry.file_type()
            .await
            .map(|t| t.is_file())
            .unwrap_or(false) {
            continue;
        }
        let path = entry.path();
        if !path.file_name()
            .and_then(|n| n.to_str())
            .map(is_patch_filename)
            .unwrap_or(false) {
            continue;
        }
        entries.push(path);
    }

    log::info!("Found {} patch files.", entries.len());
    Ok(entries)
}

async fn add_files_from_dir(dir: &Path, groups: &mut HashMap<String, Vec<PatchFileTriplet>>) -> anyhow::Result<()> {
    let index_regex = INDEX_REGEX.get_or_init(|| Regex::new(r"\.patch_(\d+)").unwrap());

    let entries = get_patch_files_from_dir(dir).await?;

    let names: HashSet<String> = entries
        .iter()
        .filter_map(|p| p.file_name()?.to_str().map(|s| s[..16].to_string()))
        .collect();

    for name in names {
        let mut indices: Vec<u32> = entries
            .iter()
            .filter_map(|p| {
                let fname = p.file_name()?.to_str()?;
                if !fname.starts_with(&*name) {
                    return None;
                }
                let caps = index_regex.captures(fname)?;
                caps[1].parse().ok()
            })
            .collect::<HashSet<u32>>()
            .into_iter()
            .collect();
        // A mod's own patch files keep their relative order: its patch_0
        // is deployed before (below) its patch_1. A HashSet alone would
        // shuffle them.
        indices.sort_unstable();

        for index in indices {
            let patch = entries.iter().find(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n == format!("{}.patch_{}", name, index))
                    .unwrap_or(false)
            }).cloned();

            let gpu_resources = entries.iter().find(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n == format!("{}.patch_{}.gpu_resources", name, index))
                    .unwrap_or(false)
            }).cloned();

            let stream = entries.iter().find(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n == format!("{}.patch_{}.stream", name, index))
                    .unwrap_or(false)
            }).cloned();

            groups
                .entry(name.clone())
                .or_default()
                .push(PatchFileTriplet { patch, gpu_resources, stream, seq: next_patch_seq() });
        }
    }

    Ok(())
}

async fn copy_patch_file(src: &Path, dest: &Path) -> anyhow::Result<()> {
    use anyhow::Context;
    tokio::fs::copy(src, dest)
        .await
        .with_context(|| format!("failed to copy {:?} to {:?}", src, dest))?;
    Ok(())
}

async fn create_empty_patch_file(dest: &Path) -> anyhow::Result<()> {
    use anyhow::Context;
    tokio::fs::File::create(dest)
        .await
        .with_context(|| format!("failed to create {:?}", dest))?;
    Ok(())
}

/// The record of which patch files the last deploy wrote, kept next to
/// them in the game's `data` folder (so it always describes that folder,
/// whichever Ordnance data folder or game path is in use). Purge removes it.
const DEPLOY_RECORD: &str = ".ordnance-deployed.json";

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DeployRecord {
    files: Vec<RecordedFile>,
}

/// One file a deploy wrote, with its length and modification time
/// (nanoseconds since the Unix epoch) right after it was written. If either
/// has changed since, something else (a Steam "verify files", the user)
/// replaced it, and it is no longer Ordnance's.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RecordedFile {
    name: String,
    len: u64,
    modified: u64,
}

/// A file's length and modification time, as recorded in [`RecordedFile`].
async fn file_stamp(file: &Path) -> Option<(u64, u64)> {
    let meta = tokio::fs::symlink_metadata(file).await.ok()?;
    if !meta.is_file() {
        return None;
    }
    let modified = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?;
    Some((meta.len(), u64::try_from(modified.as_nanos()).ok()?))
}

/// The files the last deploy recorded writing, by name, or `None` when
/// there is no usable record (none yet -- including a game folder last
/// deployed by a version without records -- or an unreadable or damaged
/// one).
async fn read_deploy_record(data_dir: &Path) -> Option<HashMap<String, RecordedFile>> {
    let file = data_dir.join(DEPLOY_RECORD);
    let data = match tokio::fs::read(&file).await {
        Ok(data) => data,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            log::warn!("Couldn't read the deploy record {:?}: {}", file, e);
            return None;
        }
    };
    match serde_json::from_slice::<DeployRecord>(&data) {
        Ok(record) => Some(
            record
                .files
                .into_iter()
                .filter(|f| is_patch_filename(&f.name))
                .map(|f| (f.name.clone(), f))
                .collect(),
        ),
        Err(e) => {
            log::warn!("Ignoring the damaged deploy record {:?}: {}", file, e);
            None
        }
    }
}

/// Record which of `names` (in `data_dir`) are now there, as written by
/// this deploy. Never fails the deploy: without a record, purge just keeps
/// a skip-listed slot-0 file it can't prove is Ordnance's.
async fn record_deployed_files(data_dir: &Path, names: &[String]) {
    let mut files = Vec::with_capacity(names.len());
    for name in names {
        if let Some((len, modified)) = file_stamp(&data_dir.join(name)).await {
            files.push(RecordedFile { name: name.clone(), len, modified });
        }
    }
    let file = data_dir.join(DEPLOY_RECORD);
    let written = match serde_json::to_vec_pretty(&DeployRecord { files }) {
        Ok(data) => crate::fs_util::replace_file(&file, &data).await,
        Err(e) => Err(e.into()),
    };
    if let Err(e) = written {
        log::warn!("Couldn't write the deploy record {:?} (the deploy itself is fine): {:#}", file, e);
    }
}

/// Whether `file` (a patch file in the game's `data` folder) is slot 0 of a
/// patch name in the Skip List: the base game's or a DLC's own file, which
/// deploy numbers around (it starts that name at `.patch_1`) and purge
/// leaves alone -- unless the deploy record says Ordnance wrote it (deployed
/// before the name was added to the Skip List).
fn is_skip_listed_slot_zero(file: &Path, settings: &Settings) -> bool {
    let Some(name) = file.file_name().and_then(|n| n.to_str()) else { return false };
    let Some((prefix, rest)) = name.split_at_checked(16) else { return false };
    matches!(rest, ".patch_0" | ".patch_0.gpu_resources" | ".patch_0.stream") && settings.has_skip_entry(prefix)
}

async fn do_purge(data_dir: &Path, settings: &Settings) -> anyhow::Result<()> {
    use anyhow::Context;
    log::info!("Purging...");

    let swapped = file_swap::recorded_files(data_dir);
    if !swapped.is_empty() {
        file_swap::restore_files(data_dir, &swapped)?;
        file_swap::write_record(data_dir, &[])?;
    }

    let deployed = read_deploy_record(data_dir).await;
    let mut patch_files = Vec::new();
    for f in get_patch_files_from_dir(data_dir).await? {
        if is_skip_listed_slot_zero(&f, settings) {
            // Only delete it if we wrote it and it is still exactly what we
            // wrote; otherwise it is (again) the game's own file.
            let recorded = f
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| deployed.as_ref()?.get(n));
            let ours = match recorded {
                Some(r) => file_stamp(&f).await == Some((r.len, r.modified)),
                None => false,
            };
            if !ours {
                log::info!("Keeping {:?}: its patch name is in the Skip List and it isn't a file we deployed.", f);
                continue;
            }
        }
        // A previous deploy recorded what we wrote. Leave every other patch
        // (MDL's live resource copies, a hand-placed bank) in the folder.
        // No record at all means an older manager: purge the non-skip files
        // so the first Ordnance deploy still replaces that set.
        if let Some(record) = &deployed {
            let name = f.file_name().and_then(|n| n.to_str());
            if !name.is_some_and(|n| record.contains_key(n)) {
                log::info!("Keeping {:?}: not written by the last Ordnance deploy.", f);
                continue;
            }
        }
        patch_files.push(f);
    }

    log::info!("Deleting files...");
    futures::future::try_join_all(patch_files.iter().map(|f| async move {
        tokio::fs::remove_file(f)
            .await
            .with_context(|| format!("failed to delete {:?}", f))
    }))
    .await?;

    // Everything Ordnance deployed is gone, so the record is too.
    let record = data_dir.join(DEPLOY_RECORD);
    // A record that can't be removed only ever keeps files: its entries
    // no longer match any file once that file is rewritten.
    match tokio::fs::remove_file(&record).await {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => log::warn!("Couldn't delete the deploy record {:?}: {}", record, e),
    }

    log::info!("Purge complete.");
    Ok(())
}

/// Pair each config with the installed mod it refers to (by GUID),
/// dropping any config whose GUID doesn't match an installed mod. A
/// user-edited (or stale) `profiles.json` can easily reference a mod that
/// no longer exists; that's not an error, the entry is just skipped.
fn pair_mods_with_configs<'a>(mods: &'a [Mod], configs: &'a [Config]) -> Vec<(&'a Mod, &'a Config)> {
    let by_guid = mods.iter()
        .map(|m| (m.guid(), m))
        .collect::<HashMap<_, _>>();

    configs.iter()
        .filter_map(|c| {
            let r#mod = by_guid.get(c.uuid()).copied();
            if r#mod.is_none() {
                log::warn!("skipping config for unknown mod GUID {{{}}}", c.uuid());
            }
            r#mod.map(|m| (m, c))
        })
        .collect()
}

/// Collect the enabled option (and, for options with sub-options, the
/// selected sub-option's) include directories for one mod into `groups`.
/// Skips a disabled mod. Never panics: a version mismatch between the
/// manifest and its config (which should never happen from the app's own
/// UI, but can from a hand-edited `profiles.json`), an out-of-range
/// selected index, or an unknown GUID are all just logged and skipped.
///
/// Factored out of `deploy` so it's testable without going through
/// `State`/`AppState` at all -- just a `Mod` and a `Config`.
async fn collect_files_for_mod(
    r#mod: &Mod,
    config: &Config,
    groups: &mut HashMap<String, Vec<PatchFileTriplet>>,
) -> anyhow::Result<()> {
    if !config.enabled() {
        return Ok(());
    }

    match (&r#mod.manifest, config) {
        (Manifest::Legacy(manifest), Config::Legacy { selected, .. }) => {
            let base = &r#mod.directory;

            if let Some(options) = manifest.options.as_ref() {
                if let Some(opt) = options.get(*selected) {
                    let dir = resolve_mod_path(base, Path::new(opt)).await;
                    add_files_from_dir(&dir, groups).await?;
                } else {
                    log::warn!(
                        "mod {{{}}}: selected option index {} out of range",
                        r#mod.guid(), selected
                    );
                }
            } else {
                add_files_from_dir(base, groups).await?;
            }
        }
        (Manifest::V1(manifest), Config::V1 { selected, toggled, .. }) => {
            let base = &r#mod.directory;

            if let Some(options) = manifest.options.as_ref() {
                for (i, opt) in options.iter().enumerate() {
                    if !toggled.get(i).copied().unwrap_or(false) {
                        continue;
                    }

                    if let Some(includes) = opt.include.as_ref() {
                        for inc in includes {
                            let dir = resolve_mod_path(base, inc).await;
                            add_files_from_dir(&dir, groups).await?;
                        }
                    }

                    if let Some(sub_options) = opt.sub_options.as_ref() {
                        if let Some(idx) = selected.get(i).cloned() {
                            if let Some(sub) = sub_options.get(idx) {
                                for inc in &sub.include {
                                    let dir = resolve_mod_path(base, inc).await;
                                    add_files_from_dir(&dir, groups).await?;
                                }
                            } else {
                                log::warn!(
                                    "mod {{{}}}: selected sub-option index {} out of range for option {}",
                                    r#mod.guid(), idx, i
                                );
                            }
                        }
                    }
                }
            } else {
                add_files_from_dir(base, groups).await?;
            }
        }
        // V2's Option/SubOption shapes are structurally the same as V1's
        // (plus a Guid/CategoryRef that deploy doesn't need), and
        // Config::V2's Toggled/Selected are index-keyed exactly like
        // Config::V1's -- see ModConfigPopup / makeConfigForMod on the
        // frontend, which is what this is derived from (the upstream v2
        // draft doesn't specify config shape at all). So V2 deploys
        // identically to V1.
        (Manifest::V2(manifest), Config::V2 { selected, toggled, .. }) => {
            let base = &r#mod.directory;

            if let Some(options) = manifest.options.as_ref() {
                for (i, opt) in options.iter().enumerate() {
                    if !toggled.get(i).copied().unwrap_or(false) {
                        continue;
                    }

                    if let Some(includes) = opt.include.as_ref() {
                        for inc in includes {
                            let dir = resolve_mod_path(base, inc).await;
                            add_files_from_dir(&dir, groups).await?;
                        }
                    }

                    if let Some(sub_options) = opt.sub_options.as_ref() {
                        if let Some(idx) = selected.get(i).cloned() {
                            if let Some(sub) = sub_options.get(idx) {
                                for inc in &sub.include {
                                    let dir = resolve_mod_path(base, inc).await;
                                    add_files_from_dir(&dir, groups).await?;
                                }
                            } else {
                                log::warn!(
                                    "mod {{{}}}: selected sub-option index {} out of range for option {}",
                                    r#mod.guid(), idx, i
                                );
                            }
                        }
                    }
                }
            } else {
                add_files_from_dir(base, groups).await?;
            }
        }
        _ => {
            log::warn!(
                "mod {{{}}}: manifest version and config version don't match, skipping",
                r#mod.guid()
            );
        }
    }

    Ok(())
}

#[derive(serde::Serialize, Clone, Debug)]
#[serde(rename_all = "PascalCase")]
pub struct DeploySkip {
    pub name: String,
    pub message: String,
}

#[derive(serde::Serialize, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct DeployReport {
    pub skipped: Vec<DeploySkip>,
    /// False when every mod was left out. The previous deploy is still in
    /// the game. True once this deploy has replaced it.
    pub deployed: bool,
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "PascalCase")]
struct DeployProgress {
    detail: String,
}

fn report_progress(app: Option<&tauri::AppHandle>, detail: &str) {
    log::info!("{detail}");
    let Some(app) = app else { return };
    use tauri::Emitter;
    let _ = app.emit("deploy://progress", DeployProgress { detail: detail.to_string() });
}

#[tauri::command]
pub async fn deploy(app: tauri::AppHandle, state: State<'_, AppState>, configs: Vec<Config>) -> TAResult<DeployReport> {
    let _data_op = state.data_op().into_ta_result()?;
    let mods = state.inner().mods.lock().await;
    if mods.is_none() {
        return anyhow::anyhow!("mods not read").into_ta_result();
    }
    let mods = mods.as_ref().unwrap();

    let settings = do_load_settings(&state.base_path).await?;
    let game_root = match settings.validate().await {
        Ok(root) => root,
        Err(e) => return anyhow::anyhow!("invalid settings: {}", e).into_ta_result(),
    };

    let mods = pair_mods_with_configs(mods, &configs);

    let data_dir = game_root.join("data");
    crate::commands::settings::check_game_data_dir(&state.base_path, &data_dir).into_ta_result()?;

    deploy_with_progress(&data_dir, &settings, mods, Some(&app)).await.into_ta_result()
}

/// Deploy `mods` into the game's `data_dir`: collect every enabled mod's
/// patch files first, then purge, then copy. A mod that can't be deployed
/// is left out and named in the report. The others still deploy. If every
/// mod is left out, nothing is purged, so the previous deploy stays.
/// The game runs one `boot` resource, from the highest patch that carries
/// it. Ordnance deploys that boot itself when a mod declares an addon.
/// Installed copies of Chef, Rat, and Boot Mod Loader are not copied.
/// With no addon, two or more plain boots are joined into one so they do
/// not erase each other.
fn mod_root_of(path: &Path) -> Option<PathBuf> {
    let mut dir = path.parent();
    while let Some(current) = dir {
        if current.join("manifest.json").is_file() {
            return Some(current.to_path_buf());
        }
        dir = current.parent();
    }
    None
}

fn under_root(path: &Path, root: &Path) -> bool {
    path.starts_with(root)
}

/// Drop every file that belongs to an installed loader mod. The native
/// boot replaces it. A loader patch with no manifest beside it (a test
/// fixture) is left for [`fold_boot_scripts`] to skip on its own.
fn drop_installed_loaders(groups: &mut HashMap<String, Vec<PatchFileTriplet>>) {
    let mut roots = Vec::new();
    if let Some(boots) = groups.get(boot_deploy::BOOT_NAME) {
        for triplet in boots {
            let Some(path) = triplet.patch.as_ref() else { continue };
            if !boot_deploy::is_loader_boot(path) {
                continue;
            }
            if let Some(root) = mod_root_of(path) {
                if !roots.iter().any(|have: &PathBuf| have == &root) {
                    log::info!("Not deploying installed loader {}", root.display());
                    roots.push(root);
                }
            }
        }
    }
    if roots.is_empty() {
        return;
    }
    for triplets in groups.values_mut() {
        triplets.retain(|triplet| {
            let paths = [triplet.patch.as_ref(), triplet.gpu_resources.as_ref(), triplet.stream.as_ref()];
            !paths.into_iter().flatten().any(|path| roots.iter().any(|root| under_root(path, root)))
        });
    }
}

fn boot_source(path: &Path) -> Option<String> {
    let data = std::fs::read(path).ok()?;
    boot_deploy::lua_text(&data).map(str::to_string)
}

fn is_declared_addon(text: &str) -> bool {
    let line = text.lines().next().unwrap_or("").trim_end_matches('\r');
    line.starts_with("-- HD2-Addon:")
        || line.starts_with("-- HD2-Boot:")
        || line.starts_with("-- HD2-Guest-Boot:")
        || line.starts_with("-- HD2-Options:")
}

fn is_swap_installer(text: &str) -> bool {
    text.contains("HD2FM1") && text.contains("shutdown = finish")
}

fn plan_names_file(plan: &str, target: &str) -> bool {
    let Ok(edits) = serde_json::from_str::<Vec<serde_json::Value>>(plan) else {
        return false;
    };
    edits.iter().any(|edit| edit.get("file").and_then(|v| v.as_str()) == Some(target))
}

fn manifest_name(start: &Path) -> Option<String> {
    let mut dir = start.parent();
    for _ in 0..6 {
        let d = dir?;
        let manifest = d.join("manifest.json");
        if manifest.is_file() {
            if let Ok(text) = std::fs::read_to_string(&manifest) {
                if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
                    if let Some(name) = value.get("Name").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                        return Some(name.to_string());
                    }
                }
            }
        }
        dir = d.parent();
    }
    None
}

fn mod_root_guid(start: &Path) -> Option<uuid::Uuid> {
    let mut dir = start.parent();
    for _ in 0..6 {
        let d = dir?;
        let manifest = d.join("manifest.json");
        if manifest.is_file() {
            if let Ok(text) = std::fs::read_to_string(&manifest) {
                if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
                    if let Some(guid) = value.get("Guid").and_then(|v| v.as_str()) {
                        return uuid::Uuid::parse_str(guid).ok();
                    }
                }
            }
        }
        dir = d.parent();
    }
    None
}

/// True when this patch's mod edits `target` with a stat plan, either one
/// shipped in the mod folder or one Ordnance carries for that mod.
fn plan_covers_swap(patch: &Path, target: &str) -> bool {
    let mut dir = patch.parent();
    for _ in 0..6 {
        let Some(d) = dir else { break };
        let path = d.join("stat-plan.json");
        if path.is_file() {
            if let Ok(text) = std::fs::read_to_string(&path) {
                return plan_names_file(&text, target);
            }
        }
        dir = d.parent();
    }
    mod_root_guid(patch)
        .and_then(stat_deploy::bundled_plan)
        .is_some_and(|plan| plan_names_file(plan, target))
}

/// Pull HD2FM payloads out of the deploy set, in profile order. The
/// installer boot that would have copied them on exit is not deployed.
fn take_file_swaps(groups: &mut HashMap<String, Vec<PatchFileTriplet>>) -> Vec<file_swap::Payload> {
    let mut found: Vec<(u64, file_swap::Payload)> = Vec::new();
    for triplets in groups.values_mut() {
        let mut kept = Vec::new();
        for triplet in triplets.drain(..) {
            let Some(path) = triplet.patch.as_ref() else {
                kept.push(triplet);
                continue;
            };
            let bytes = std::fs::read(path).unwrap_or_default();
            if let Some(mut payload) = file_swap::parse_hd2fm(&bytes) {
                payload.source = path.clone();
                payload.label = path
                    .parent()
                    .and_then(|parent| parent.file_name())
                    .and_then(|name| name.to_str())
                    .unwrap_or("mod")
                    .to_string();
                payload.mod_name = manifest_name(path).unwrap_or_else(|| payload.label.clone());
                if plan_covers_swap(path, &payload.target) {
                    log::info!(
                        "Not deploying file swap {} -> {}: a stat plan edits that table",
                        payload.label,
                        payload.target
                    );
                    continue;
                }
                log::info!("file swap {} -> {}", payload.label, payload.target);
                found.push((triplet.seq, payload));
                continue;
            }
            if boot_deploy::is_text_boot_script(path)
                && boot_source(path).is_some_and(|text| is_swap_installer(&text))
            {
                log::info!("Not deploying file-swap installer {}", path.display());
                continue;
            }
            kept.push(triplet);
        }
        *triplets = kept;
    }
    found.sort_by_key(|(seq, _)| *seq);
    found.into_iter().map(|(_, payload)| payload).collect()
}

fn fold_boot_scripts(
    groups: &mut HashMap<String, Vec<PatchFileTriplet>>,
) -> anyhow::Result<Option<boot_deploy::Hold>> {
    let Some(triplets) = groups.get_mut(boot_deploy::BOOT_NAME) else {
        return Ok(None);
    };
    let mut rest = Vec::new();
    let mut plains = Vec::new();
    let mut addons = Vec::new();
    for triplet in triplets.drain(..) {
        let Some(path) = triplet.patch.clone() else {
            rest.push(triplet);
            continue;
        };
        // A loader that had no manifest still has to stay out of the boot
        // slot. Ordnance's own boot is the one the game runs.
        if boot_deploy::is_loader_boot(&path) {
            log::info!("Not deploying installed loader patch {}", path.display());
            continue;
        }
        // A declaration (`-- HD2-Options:` and the rest) is Lua the loader
        // reads off disk. It often does not carry the boot resource, so the
        // boot-script check misses it. Leaving it as the highest patch makes
        // the game run that snippet as the boot.
        let text = boot_source(&path).unwrap_or_default();
        let declaration = is_declared_addon(&text);
        if !declaration && !boot_deploy::is_text_boot_script(&path) {
            rest.push(triplet);
            continue;
        }
        if is_swap_installer(&text) {
            log::info!("Not deploying file-swap installer {}", path.display());
            continue;
        }
        if declaration {
            addons.push(triplet);
            continue;
        }
        plains.push((path, triplet));
    }
    if !addons.is_empty() {
        let named: Vec<(String, PathBuf)> = plains
            .iter()
            .map(|(path, _)| {
                let name = path
                    .parent()
                    .and_then(|parent| parent.file_name())
                    .and_then(|name| name.to_str())
                    .unwrap_or("mod")
                    .to_string();
                (name, path.clone())
            })
            .collect();
        log::info!(
            "Ordnance loader starts {} addon archive(s) and {} other boot script(s).",
            addons.len(),
            named.len()
        );
        let (hold, merged) = boot_deploy::assemble_loader(&named)?;
        rest.extend(addons);
        rest.push(PatchFileTriplet {
            patch: Some(merged),
            gpu_resources: None,
            stream: None,
            seq: next_patch_seq(),
        });
        *triplets = rest;
        return Ok(Some(hold));
    }
    if plains.len() < 2 {
        rest.extend(plains.into_iter().map(|(_, triplet)| triplet));
        *triplets = rest;
        return Ok(None);
    }
    let named: Vec<(String, PathBuf)> = plains
        .iter()
        .map(|(path, _)| {
            let name = path
                .parent()
                .and_then(|parent| parent.file_name())
                .and_then(|name| name.to_str())
                .unwrap_or("mod")
                .to_string();
            (name, path.clone())
        })
        .collect();
    log::info!(
        "No addon scripts. Merging {} boot scripts so the highest patch still runs all of them.",
        named.len()
    );
    let (hold, merged) = boot_deploy::merge(&named)?;
    rest.push(PatchFileTriplet {
        patch: Some(merged),
        gpu_resources: None,
        stream: None,
        seq: next_patch_seq(),
    });
    *triplets = rest;
    Ok(Some(hold))
}

const STAT_TABLE_FILES: [&str; 4] = [
    "generated_entities.dl_bin",
    "generated_projectile_settings.dl_bin",
    "generated_damage_settings.dl_bin",
    "generated_explosion_settings.dl_bin",
];

/// An edit with no `option` applies whenever the mod is enabled. An edit
/// that names an option applies only while that box is ticked.
fn stat_edit_selected(edit: &serde_json::Value, option_names: &[&str], toggled: &[bool]) -> anyhow::Result<bool> {
    let Some(name) = edit.get("option").and_then(|v| v.as_str()).map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(true);
    };
    let Some(index) = option_names.iter().position(|n| *n == name) else {
        anyhow::bail!("option \"{name}\" is not in this mod's manifest");
    };
    Ok(toggled.get(index).copied().unwrap_or(false))
}

/// Collects each enabled mod's "stat-plan.json" (a JSON array of offset-based
/// edits) in profile order. The plan applier applies them in order, so a later
/// edit wins when two hit the same field.
async fn collect_stat_plans(mods: &[(&Mod, &Config)]) -> anyhow::Result<Vec<serde_json::Value>> {
    use anyhow::Context;
    let mut plan_edits: Vec<serde_json::Value> = Vec::new();
    for (r#mod, config) in mods {
        if !config.enabled() {
            continue;
        }
        let plan_path = r#mod.directory.join("stat-plan.json");
        let text = if plan_path.is_file() {
            tokio::fs::read_to_string(&plan_path)
                .await
                .with_context(|| format!("read {:?}", plan_path))?
        } else if let Some(bundled) = stat_deploy::bundled_plan(r#mod.guid()) {
            bundled.to_string()
        } else {
            continue;
        };
        let edits: Vec<serde_json::Value> =
            serde_json::from_str(&text).with_context(|| format!("parse {:?}", plan_path))?;
        // Tag each edit with its mod so apply-time errors can name the mod.
        // An edit that names an option is skipped while that box is off.
        let attribution = format!("{} ({})", r#mod.name(), r#mod.guid());
        let names = r#mod.manifest.option_names();
        let toggled = config.toggles();
        for mut e in edits {
            if let Some(obj) = e.as_object_mut() {
                obj.insert("_mod".to_string(), serde_json::Value::String(attribution.clone()));
            }
            if stat_edit_selected(&e, &names, toggled)
                .with_context(|| format!("{attribution}: stat-plan.json"))?
            {
                plan_edits.push(e);
            }
        }
    }
    Ok(plan_edits)
}

/// Sealed tables written by the previous deploy, kept beside the vanilla stock
/// backup. The seal changes every write, so this copy is the only byte-for-byte
/// record of "the game file is our output."
const STOCK_OUTPUT_DIR: &str = "output";

/// `true` when `game` should replace the vanilla stock backup.
///
/// A missing stock file is seeded from the game. A game file that matches the
/// stock backup, or matches the previous deploy's sealed output, leaves the
/// backup alone. Anything else is a table Steam replaced.
/// `Some` when `src` would change the plaintext length of the table already
/// in the game. A missing game file is not a conflict.
async fn different_table_length(src: &Path, game_path: &Path) -> anyhow::Result<Option<String>> {
    use anyhow::Context;
    let next = tokio::fs::read(src).await.with_context(|| format!("read {}", src.display()))?;
    let existing = match tokio::fs::read(game_path).await {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e).with_context(|| format!("read {}", game_path.display())),
    };
    let have = hd2edit::seal_open(&existing).len();
    let want = hd2edit::seal_open(&next).len();
    if have == want {
        return Ok(None);
    }
    let name = game_path.file_name().and_then(|n| n.to_str()).unwrap_or("table");
    Ok(Some(format!(
        "{name} would replace a {have}-byte table with a {want}-byte one, so it was left alone"
    )))
}

fn game_file_replaces_stock(game: Option<&[u8]>, stock: Option<&[u8]>, output: Option<&[u8]>) -> bool {
    let Some(game) = game else {
        return false;
    };
    let Some(stock) = stock else {
        return true;
    };
    if game == stock {
        return false;
    }
    !output.is_some_and(|output| output == game)
}

async fn read_bytes_if_present(path: &Path) -> anyhow::Result<Option<Vec<u8>>> {
    use anyhow::Context;
    match tokio::fs::read(path).await {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("read {}", path.display())),
    }
}

/// Brings `ordnance-stock` in line with the live game tables before plans run.
///
/// Plans are always applied to the stock backup, then the result is copied
/// over the game. The backup is the first vanilla copy Ordnance saw, which
/// goes stale when Steam patches the game. Refresh it only when the live file
/// is neither that backup nor the sealed output of the last deploy. A matching
/// plaintext (Steam resealed the same vanilla) and a plaintext equal to
/// applying the current plans (an output from before this snapshot existed)
/// also keep the backup, so a deploy cannot seed the stock from its own edits.
async fn refresh_stat_stock(
    game_dir: &Path,
    stock_dir: &Path,
    plan_edits: &[serde_json::Value],
) -> anyhow::Result<()> {
    use anyhow::Context;
    let output_dir = stock_dir.join(STOCK_OUTPUT_DIR);
    let mut files: Vec<String> = STAT_TABLE_FILES.iter().map(|name| (*name).to_string()).collect();
    for edit in plan_edits {
        if let Some(name) = edit.get("file").and_then(|v| v.as_str()) {
            if !files.iter().any(|have| have == name) {
                files.push(name.to_string());
            }
        }
    }
    for fname in &files {
        let game_path = game_dir.join(fname);
        let stock_path = stock_dir.join(fname);
        let output_path = output_dir.join(fname);
        let game = read_bytes_if_present(&game_path).await?;
        let stock = read_bytes_if_present(&stock_path).await?;
        let output = read_bytes_if_present(&output_path).await?;
        if !game_file_replaces_stock(game.as_deref(), stock.as_deref(), output.as_deref()) {
            continue;
        }
        let game_bytes = game.as_ref().expect("replace is only set when the game file exists");
        if let Some(stock_bytes) = stock.as_ref() {
            let game_plain = hd2edit::seal_open(game_bytes);
            let stock_plain = hd2edit::seal_open(stock_bytes);
            if game_plain == stock_plain {
                log::info!("{fname}: game file is a reseal of the stock backup");
                continue;
            }
            // A different length is a different build of the table. The file
            // in the game is the one this build shipped. Keeping the other
            // backup and writing it back is how an 82432-byte stratagem table
            // replaced the 82424-byte one and the game died at startup.
            if game_plain.len() != stock_plain.len() {
                log::warn!(
                    "{fname}: stock backup is {} bytes of plaintext and the game file is {}; keeping the game file",
                    stock_plain.len(),
                    game_plain.len()
                );
            } else {
                let edits: Vec<&serde_json::Value> = plan_edits
                    .iter()
                    .filter(|e| e.get("file").and_then(|v| v.as_str()) == Some(fname.as_str()))
                    .collect();
                if !edits.is_empty() {
                    match stat_deploy::plaintext_after_edits(&edits, stock_bytes) {
                        Ok(applied) if applied == game_plain => {
                            log::info!(
                                "{fname}: game file matches the plans applied to the stock backup"
                            );
                            continue;
                        }
                        Ok(_) => {}
                        Err(err) => {
                            log::warn!(
                                "{fname}: leaving the stock backup in place; the game file is neither it nor a clean apply of the current plans ({err:#})"
                            );
                            continue;
                        }
                    }
                }
                log::info!(
                    "{fname}: game file matches neither the stock backup nor the last output; replacing the backup"
                );
            }
        }
        tokio::fs::copy(&game_path, &stock_path)
            .await
            .with_context(|| format!("refresh stock {fname}"))?;
    }
    Ok(())
}

/// Applies the merged stat plans against a stock backup, returning a handle
/// that keeps the resealed output alive until it is copied into data/game/.
async fn apply_stat_plans(
    data_dir: &Path,
    plan_edits: &[serde_json::Value],
) -> anyhow::Result<Option<stat_deploy::OutHold>> {
    use anyhow::Context;
    if plan_edits.is_empty() {
        return Ok(None);
    }
    let plan_json = serde_json::to_string(plan_edits).context("serialize merged stat plan")?;
    let game_dir = data_dir.join("game");
    let stock_dir = data_dir.join("ordnance-stock");
    tokio::fs::create_dir_all(&stock_dir).await.context("create stock dir")?;
    refresh_stat_stock(&game_dir, &stock_dir, plan_edits).await?;
    let out = stat_deploy::apply_plan(&plan_json, &stock_dir)?;
    Ok(Some(out))
}

fn drop_mod_files(groups: &mut HashMap<String, Vec<PatchFileTriplet>>, root: &Path) {
    for triplets in groups.values_mut() {
        triplets.retain(|triplet| {
            let paths = [triplet.patch.as_ref(), triplet.gpu_resources.as_ref(), triplet.stream.as_ref()];
            !paths.into_iter().flatten().any(|path| under_root(path, root))
        });
    }
    groups.retain(|_, triplets| !triplets.is_empty());
}

fn mod_dir_for<'a>(mods: &'a [(&Mod, &Config)], source: &Path) -> Option<&'a Path> {
    mods.iter()
        .find(|(r#mod, _)| source.starts_with(&r#mod.directory))
        .map(|(r#mod, _)| r#mod.directory.as_path())
}

struct PlanChunk<'a> {
    name: &'a str,
    guid: String,
    dir: &'a Path,
    edits: Vec<serde_json::Value>,
}

fn plan_chunks<'a>(mods: &'a [(&Mod, &Config)], edits: &[serde_json::Value]) -> Vec<PlanChunk<'a>> {
    let mut chunks = Vec::new();
    for (r#mod, _) in mods {
        let key = format!("{} ({})", r#mod.name(), r#mod.guid());
        let mine: Vec<_> = edits
            .iter()
            .filter(|edit| edit.get("_mod").and_then(|v| v.as_str()) == Some(key.as_str()))
            .cloned()
            .collect();
        if mine.is_empty() {
            continue;
        }
        chunks.push(PlanChunk {
            name: r#mod.name(),
            guid: r#mod.guid().to_string(),
            dir: &r#mod.directory,
            edits: mine,
        });
    }
    chunks
}

#[cfg(test)]
async fn do_deploy(data_dir: &Path, settings: &Settings, mods: Vec<(&Mod, &Config)>) -> anyhow::Result<DeployReport> {
    deploy_with_progress(data_dir, settings, mods, None).await
}

async fn deploy_with_progress(
    data_dir: &Path,
    settings: &Settings,
    mods: Vec<(&Mod, &Config)>,
    progress: Option<&tauri::AppHandle>,
) -> anyhow::Result<DeployReport> {
    log::info!("Grouping files...");
    let mut skipped: Vec<DeploySkip> = Vec::new();
    let enabled: Vec<(&Mod, &Config)> = mods.iter().copied().filter(|(_, config)| config.enabled()).collect();
    let total = enabled.len();
    let mut plan_edits = Vec::new();
    let mut groups: HashMap<String, Vec<PatchFileTriplet>> = HashMap::new();
    for (index, (r#mod, config)) in enabled.iter().copied().enumerate() {
        report_progress(progress, &format!("Reading {} ({} of {})", r#mod.name(), index + 1, total));
        let mut local = HashMap::new();
        if let Err(err) = collect_files_for_mod(r#mod, config, &mut local).await {
            skipped.push(DeploySkip { name: r#mod.name().to_string(), message: format!("{err:#}") });
            continue;
        }
        match collect_stat_plans(&[(r#mod, config)]).await {
            Ok(edits) => plan_edits.extend(edits),
            Err(err) => {
                skipped.push(DeploySkip { name: r#mod.name().to_string(), message: format!("{err:#}") });
                continue;
            }
        }
        for (name, mut triplets) in local {
            groups.entry(name).or_default().append(&mut triplets);
        }
    }

    log::info!("Collected files into {} groups.", groups.len());
    if log::log_enabled!(log::Level::Debug) {
        for (k, v) in &groups {
            log::debug!(" - k: \"{}\"; v: [{}]", k, v.len());
        }
    }

    // Payloads and the loader are resolved before purge. A mod that fails
    // here is dropped. Anything that is not one mod's problem (a boot merge
    // that cannot be built, a table that cannot be written) still stops
    // the deploy before the game folder is touched.
    let mut swaps = take_file_swaps(&mut groups);
    drop_installed_loaders(&mut groups);
    let _boot_hold = fold_boot_scripts(&mut groups)?;
    let mut accepted: Vec<serde_json::Value> = Vec::new();
    let mut stat_out = None;
    for chunk in plan_chunks(&mods, &plan_edits) {
        report_progress(progress, &format!("Resealing tables for {}", chunk.name));
        let mut trial = accepted.clone();
        trial.extend(chunk.edits.iter().cloned());
        match apply_stat_plans(data_dir, &trial).await {
            Ok(out) => {
                accepted = trial;
                stat_out = out;
            }
            Err(err) => {
                let message = format!("{err:#}");
                if !message.contains(&chunk.guid) && !message.contains(chunk.name) {
                    return Err(err);
                }
                log::info!("Leaving {} out of this deploy: {message}", chunk.name);
                skipped.push(DeploySkip { name: chunk.name.to_string(), message });
                drop_mod_files(&mut groups, chunk.dir);
                swaps.retain(|payload| mod_dir_for(&mods, &payload.source) != Some(chunk.dir));
            }
        }
    }
    let painted = if swaps.is_empty() {
        None
    } else {
        report_progress(progress, "Applying file changes");
        let outcome = file_swap::paint_all(
            data_dir,
            &swaps,
            stat_out.as_ref().map(|out| out.dir.as_path()),
        )?;
        for skip in outcome.skipped {
            log::info!("Leaving {} out of this deploy: {}", skip.mod_name, skip.message);
            if let Some(dir) = mod_dir_for(&mods, &skip.source).map(Path::to_path_buf).or_else(|| mod_root_of(&skip.source)) {
                drop_mod_files(&mut groups, &dir);
            }
            skipped.push(DeploySkip { name: skip.mod_name, message: skip.message });
        }
        if outcome.painted.files.is_empty() { None } else { Some(outcome.painted) }
    };

    let has_files = groups.values().any(|triplets| !triplets.is_empty());
    let has_tables = stat_out.is_some() || painted.as_ref().is_some_and(|painted| !painted.files.is_empty());
    if !has_files && !has_tables && !skipped.is_empty() {
        log::info!("Every mod was left out; the previous deploy stays in place");
        return Ok(DeployReport { skipped, deployed: false });
    }

    report_progress(progress, "Removing the previous deploy");
    do_purge(data_dir, settings).await?;

    log::info!("Deploying...");

    let mut restore_on_purge: Vec<String> = Vec::new();
    if let Some(out) = &stat_out {
        report_progress(progress, "Writing game tables");
        use anyhow::Context;
        let game_dir = data_dir.join("game");
        let output_dir = data_dir.join("ordnance-stock").join(STOCK_OUTPUT_DIR);
        tokio::fs::create_dir_all(&output_dir)
            .await
            .context("create stock output dir")?;
        let mut names = std::fs::read_dir(&out.dir)
            .map(|rd| {
                rd.filter_map(|entry| entry.ok())
                    .map(|entry| entry.file_name().to_string_lossy().into_owned())
                    .filter(|name| name.ends_with(".dl_bin"))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        names.sort();
        for fname in names {
            report_progress(progress, &format!("Writing {fname}"));
            let src = out.dir.join(&fname);
            let recorded = output_dir.join(&fname);
            let game_path = game_dir.join(&fname);
            if let Some(message) = different_table_length(&src, &game_path).await? {
                log::warn!("{message}");
                skipped.push(DeploySkip { name: fname.clone(), message });
                continue;
            }
            tokio::fs::copy(&src, &recorded)
                .await
                .with_context(|| format!("record resealed {fname}"))?;
            if let Err(err) = tokio::fs::copy(&src, game_dir.join(&fname)).await {
                let _ = tokio::fs::remove_file(&recorded).await;
                return Err(err).with_context(|| format!("copy resealed {fname}"));
            }
            // The four gameplay tables are reapplied from stock on the next
            // deploy. A plan that edits any other table has to be put back
            // on purge, the same way a file swap is.
            if !STAT_TABLE_FILES.contains(&fname.as_str()) {
                restore_on_purge.push(fname);
            }
        }
    }

    if let Some(painted) = &painted {
        use anyhow::Context;
        let game_dir = data_dir.join("game");
        let output_dir = data_dir.join("ordnance-stock").join(STOCK_OUTPUT_DIR);
        tokio::fs::create_dir_all(&game_dir).await.context("create game dir")?;
        tokio::fs::create_dir_all(&output_dir).await.context("create stock output dir")?;
        for fname in &painted.files {
            report_progress(progress, &format!("Writing {fname}"));
            let src = painted.dir.join(fname);
            let recorded = output_dir.join(fname);
            let game_path = game_dir.join(fname);
            if let Some(message) = different_table_length(&src, &game_path).await? {
                log::warn!("{message}");
                skipped.push(DeploySkip { name: fname.clone(), message });
                continue;
            }
            tokio::fs::copy(&src, &recorded)
                .await
                .with_context(|| format!("record swapped {fname}"))?;
            if let Err(err) = tokio::fs::copy(&src, game_dir.join(fname)).await {
                let _ = tokio::fs::remove_file(&recorded).await;
                return Err(err).with_context(|| format!("copy swapped {fname}"));
            }
            if !restore_on_purge.iter().any(|name| name == fname) {
                restore_on_purge.push(fname.clone());
            }
        }
    }
    if !restore_on_purge.is_empty() {
        file_swap::write_record(data_dir, &restore_on_purge)?;
    }

    if groups.is_empty() {
        log::info!("Nothing to deploy.");
        return Ok(DeployReport { skipped, deployed: true });
    }
    
    // Load order: `configs` is the profile's mod list, top to bottom, and
    // each group's triplets were collected in that order. The first gets
    // `<name>.patch_0` (after an optional skip-list offset), the next
    // `.patch_1`, and so on. Helldivers 2 applies higher patch numbers over
    // lower ones, so the mod LOWEST in the list wins a conflict. Text Lua
    // patches of `9ba626afa44a3aa3` are the exception: those were reduced
    // to one file by `fold_boot_scripts`.
    let mut written = Vec::new();
    for (name, triplets) in &groups {
        let offset = if settings.has_skip_entry(name) { 1 } else { 0 };
        for index in offset..triplets.len() + offset {
            for suffix in ["", ".gpu_resources", ".stream"] {
                written.push(format!("{}.patch_{}{}", name, index, suffix));
            }
        }
    }
    written.sort();

    report_progress(progress, "Copying mods into the game");
    let copied = copy_groups(data_dir, settings, &groups, progress).await;
    // Recorded even when copying stopped partway, so the files that did
    // land are known to be Ordnance's.
    record_deployed_files(data_dir, &written).await;
    copied?;

    log::info!("Deployment complete.");
    Ok(DeployReport { skipped, deployed: true })
}

async fn copy_groups(
    data_dir: &Path,
    settings: &Settings,
    groups: &HashMap<String, Vec<PatchFileTriplet>>,
    progress: Option<&tauri::AppHandle>,
) -> anyhow::Result<()> {
    let total: usize = groups.values().map(|triplets| triplets.len()).sum();
    let mut done = 0usize;
    for (name, triplets) in groups {
        let offset = if settings.has_skip_entry(name) { 1 } else { 0 };

        for (i, triplet) in triplets.iter().enumerate() {
            let index = i + offset;
            done += 1;
            let label = [triplet.patch.as_ref(), triplet.stream.as_ref(), triplet.gpu_resources.as_ref()]
                .into_iter()
                .flatten()
                .find_map(|path| {
                    path.parent()
                        .and_then(|parent| parent.file_name())
                        .map(|folder| folder.to_string_lossy().into_owned())
                })
                .unwrap_or_else(|| format!("{name}.patch_{index}"));
            report_progress(progress, &format!("Copying {label} ({done} of {total})"));

            let patch_dest = data_dir.join(format!("{}.patch_{}", name, index));
            match &triplet.patch {
                Some(src) => { copy_patch_file(src, &patch_dest).await?; }
                None => { create_empty_patch_file(&patch_dest).await?; }
            }
            
            let gpu_dest = data_dir.join(format!("{}.patch_{}.gpu_resources", name, index));
            match &triplet.gpu_resources {
                Some(src) => { copy_patch_file(src, &gpu_dest).await?; }
                None => { create_empty_patch_file(&gpu_dest).await?; }
            }
            
            let stream_dest = data_dir.join(format!("{}.patch_{}.stream", name, index));
            match &triplet.stream {
                Some(src) => { copy_patch_file(src, &stream_dest).await?; }
                None => { create_empty_patch_file(&stream_dest).await?; }
            }
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn purge(state: State<'_, AppState>) -> TAResult<()> {
    let _data_op = state.data_op().into_ta_result()?;
    let settings = do_load_settings(&state.base_path).await.into_ta_result()?;
    let game_root = match settings.validate().await {
        Ok(root) => root,
        Err(e) => return anyhow::anyhow!("invalid settings: {}", e).into_ta_result(),
    };

    let data_dir = game_root.join("data");
    crate::commands::settings::check_game_data_dir(&state.base_path, &data_dir).into_ta_result()?;
    do_purge(&data_dir, &settings).await.into_ta_result()
}

/// Last-resort way to close the app from the frontend.
///
/// Normally the window closes itself via the `window|destroy` IPC call
/// that `@tauri-apps/api`'s `onCloseRequested` wrapper makes once our close
/// handler resolves. This command exists for the case where that call
/// fails for some other reason (the permission is granted as of this
/// release, but a future regression there, a webview IPC hiccup, etc.
/// shouldn't be able to strand a user with an unclosable window again) --
/// the frontend falls back to this after logging the `destroy` error.
///
/// This intentionally does not go through `AppState` or try to save
/// anything: by the time the frontend reaches for this fallback it has
/// already given the user a chance to save/confirm, and the whole point is
/// to guarantee the process actually exits.
#[tauri::command]
pub fn force_exit(app: tauri::AppHandle) {
    log::warn!("force_exit invoked; exiting immediately.");
    app.exit(0);
}

/// Called by the frontend's close handler as the very first thing it does,
/// proving to the Rust-side close watchdog (see `lib.rs`) that the
/// frontend is alive and actually handling the close request.
#[tauri::command]
pub fn ack_close_requested(state: State<'_, AppState>) {
    state.close_ack.store(true, std::sync::atomic::Ordering::SeqCst);
}

/// Open the folder with Ordnance's log files in the file manager (the Mods
/// page offers this when it couldn't load, so the log is one click away for
/// a bug report). Opened from here rather than with the opener plugin from
/// the page, so it works wherever the data folder is.
#[tauri::command]
pub fn open_log_folder(app: tauri::AppHandle, state: State<'_, AppState>) -> TAResult<()> {
    use tauri_plugin_opener::OpenerExt;
    let dir = crate::data_dir::log_dir(&state.data_dir);
    log::info!("Opening the log folder {:?}.", dir);
    app.opener()
        .open_path(dir.to_string_lossy(), None::<&str>)
        .map_err(|e| anyhow::anyhow!("couldn't open the log folder {}: {e}", dir.display()))
        .into_ta_result()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::manifest::legacy;
    use uuid::Uuid;

    const V2_FIXTURE: &str = include_str!("../../tests/fixtures/v2_manifest_fixture.json");

    fn v2_fixture_manifest() -> Manifest {
        serde_json::from_str(V2_FIXTURE).expect("fixture should parse as a manifest")
    }

    #[test]
    fn a_named_stat_edit_follows_that_options_toggle() {
        let names = ["One-Two", "Arbitrator"];
        let on = serde_json::json!({"option": "One-Two", "file": "generated_entities.dl_bin"});
        let off = serde_json::json!({"option": "Arbitrator"});
        let plain = serde_json::json!({"file": "generated_entities.dl_bin"});
        let toggled = [true, false];
        assert!(stat_edit_selected(&on, &names, &toggled).unwrap());
        assert!(!stat_edit_selected(&off, &names, &toggled).unwrap());
        assert!(stat_edit_selected(&plain, &names, &toggled).unwrap());
        let err = stat_edit_selected(&serde_json::json!({"option": "Nope"}), &names, &toggled).unwrap_err();
        assert!(err.to_string().contains("Nope"), "{err}");
    }

    fn patch_file_name(index: u32) -> String {
        format!("0123456789abcdef.patch_{}", index)
    }

    async fn write_patch_file(dir: &std::path::Path, index: u32) {
        tokio::fs::create_dir_all(dir).await.unwrap();
        tokio::fs::write(dir.join(patch_file_name(index)), b"data").await.unwrap();
    }

    /// Lays out the fixture's expected directories (Base, Variants/Red,
    /// Variants/Blue), each with one distinguishable patch file, under a
    /// fresh temp dir, and returns a Mod pointing at it with the fixture
    /// manifest.
    async fn v2_fixture_mod() -> (tempfile::TempDir, Mod) {
        let dir = tempfile::tempdir().unwrap();
        write_patch_file(&dir.path().join("Base"), 0).await;
        write_patch_file(&dir.path().join("Variants/Red"), 1).await;
        write_patch_file(&dir.path().join("Variants/Blue"), 2).await;

        let r#mod = Mod {
            manifest: v2_fixture_manifest(),
            directory: dir.path().to_path_buf(),
            sources: Vec::new(),
            display_name: None,
        };
        (dir, r#mod)
    }

    fn v2_guid() -> Uuid {
        Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap()
    }

    #[tokio::test]
    async fn windows_style_include_paths_resolve_on_case_sensitive_filesystems() {
        // A Windows-authored manifest: backslash separators and casing
        // that doesn't match the folders on disk.
        let dir = tempfile::tempdir().unwrap();
        write_patch_file(&dir.path().join("Variants/Red"), 0).await;
        let r#mod = Mod {
            manifest: Manifest::Legacy(legacy::Manifest {
                guid: Uuid::nil(),
                name: "win".into(),
                description: String::new(),
                icon_path: None,
                options: Some(vec!["variants\\red".into()]),
            }),
            directory: dir.path().to_path_buf(),
            sources: Vec::new(),
            display_name: None,
        };
        let config = Config::Legacy { guid: Uuid::nil(), enabled: true, selected: 0 };

        let mut groups = HashMap::new();
        collect_files_for_mod(&r#mod, &config, &mut groups).await.unwrap();
        assert!(groups.contains_key("0123456789abcdef"));
    }

    #[tokio::test]
    async fn missing_include_folder_error_names_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let r#mod = Mod {
            manifest: Manifest::Legacy(legacy::Manifest {
                guid: Uuid::nil(),
                name: "m".into(),
                description: String::new(),
                icon_path: None,
                options: Some(vec!["NotThere".into()]),
            }),
            directory: dir.path().to_path_buf(),
            sources: Vec::new(),
            display_name: None,
        };
        let config = Config::Legacy { guid: Uuid::nil(), enabled: true, selected: 0 };

        let err = collect_files_for_mod(&r#mod, &config, &mut HashMap::new()).await.unwrap_err();
        assert!(format!("{:#}", err).contains("NotThere"), "{err:#}");
    }

    #[tokio::test]
    async fn v2_deploy_collects_enabled_option_files() {
        let (_dir, r#mod) = v2_fixture_mod().await;
        let config = Config::V2 {
            guid: v2_guid(),
            enabled: true,
            toggled: vec![true, false], // Base Option on, Color Variant off
            selected: vec![0, 0],
        };

        let mut groups = HashMap::new();
        collect_files_for_mod(&r#mod, &config, &mut groups).await.unwrap();

        assert_eq!(groups.len(), 1, "only the Base option's patch file should be grouped");
        assert!(groups.contains_key("0123456789abcdef"));
    }

    #[tokio::test]
    async fn v2_deploy_collects_selected_sub_option_files() {
        let (_dir, r#mod) = v2_fixture_mod().await;
        // Both options on; Color Variant's selected sub-option is index 1 (Blue).
        let config = Config::V2 {
            guid: v2_guid(),
            enabled: true,
            toggled: vec![true, true],
            selected: vec![0, 1],
        };

        let mut groups = HashMap::new();
        collect_files_for_mod(&r#mod, &config, &mut groups).await.unwrap();

        // Base + Blue both write into the same 16-hex-char group name here
        // (fixture reuses the name for simplicity), so assert via patch count instead.
        let total_patches: usize = groups.values().map(|v| v.len()).sum();
        assert_eq!(total_patches, 2, "Base + Blue, but not Red");
    }

    /// #55: the sub-option picked in the popup (stored as `Selected` in
    /// the profile) decides which folder is deployed, for every option.
    #[tokio::test]
    async fn v1_deploy_uses_the_selected_sub_option_of_each_option() {
        let dir = tempfile::tempdir().unwrap();
        for (i, folder) in ["Core", "Core/None", "Core/Half", "Primaries/None", "Primaries/Half", "Extra"]
            .iter()
            .enumerate()
        {
            write_patch_file(&dir.path().join(folder), i as u32).await;
        }
        let manifest = Manifest::parse(
            include_bytes!("../../tests/fixtures/manifests/sub_options_v1.json"),
            "sub_options_v1.json",
        )
        .unwrap();
        let r#mod = Mod { manifest, directory: dir.path().to_path_buf(), sources: Vec::new() , display_name: None};
        let guid = r#mod.guid();

        // A profile saved by the popup: Half sway for core, no sway for primaries.
        let config: Config = serde_json::from_value(serde_json::json!({
            "For": "V1", "Guid": guid, "Enabled": true,
            "Toggled": [true, true, true], "Selected": [1, 0, 0],
        }))
        .unwrap();
        assert_eq!(serde_json::to_value(&config).unwrap()["Selected"], serde_json::json!([1, 0, 0]));

        let mut groups = HashMap::new();
        collect_files_for_mod(&r#mod, &config, &mut groups).await.unwrap();
        let mut deployed: Vec<PathBuf> = groups
            .values()
            .flatten()
            .map(|t| t.patch.clone().unwrap().strip_prefix(dir.path()).unwrap().parent().unwrap().to_path_buf())
            .collect();
        deployed.sort();
        let expected: Vec<PathBuf> = ["Core", "Core/Half", "Extra", "Primaries/None"].iter().map(PathBuf::from).collect();
        assert_eq!(deployed, expected);

        // The default entry (first sub-option everywhere) deploys the first choices.
        let config = Config::V1 { guid, enabled: true, toggled: vec![true, true, false], selected: vec![0, 0, 0] };
        let mut groups = HashMap::new();
        collect_files_for_mod(&r#mod, &config, &mut groups).await.unwrap();
        let mut deployed: Vec<PathBuf> = groups
            .values()
            .flatten()
            .map(|t| t.patch.clone().unwrap().strip_prefix(dir.path()).unwrap().parent().unwrap().to_path_buf())
            .collect();
        deployed.sort();
        let expected: Vec<PathBuf> = ["Core", "Core/None", "Primaries/None"].iter().map(PathBuf::from).collect();
        assert_eq!(deployed, expected);
    }

    #[tokio::test]
    async fn v2_deploy_skips_disabled_mod() {
        let (_dir, r#mod) = v2_fixture_mod().await;
        let config = Config::V2 {
            guid: v2_guid(),
            enabled: false,
            toggled: vec![true, true],
            selected: vec![0, 0],
        };

        let mut groups = HashMap::new();
        collect_files_for_mod(&r#mod, &config, &mut groups).await.unwrap();

        assert!(groups.is_empty());
    }

    #[test]
    fn unknown_guid_in_config_is_skipped_not_panicked() {
        let (guid, manifest) = (v2_guid(), v2_fixture_manifest());
        let r#mod = Mod {
            manifest,
            directory: PathBuf::from("/nonexistent"),
            sources: Vec::new(),
            display_name: None,
        };
        let mods = vec![r#mod];

        let unrelated_guid = Uuid::parse_str("99999999-9999-9999-9999-999999999999").unwrap();
        assert_ne!(unrelated_guid, guid);

        let configs = vec![Config::V2 {
            guid: unrelated_guid,
            enabled: true,
            toggled: vec![true],
            selected: vec![0],
        }];

        let paired = pair_mods_with_configs(&mods, &configs);
        assert!(paired.is_empty(), "a config for an unknown GUID must be dropped, not matched");
    }

    #[tokio::test]
    async fn mismatched_manifest_and_config_versions_do_not_panic() {
        let (_dir, r#mod) = v2_fixture_mod().await; // Manifest::V2
        let config = Config::V1 {
            guid: v2_guid(),
            enabled: true,
            toggled: vec![true],
            selected: vec![0],
        };

        let mut groups = HashMap::new();
        // Must not panic (no todo!/unreachable!) and must not collect anything.
        let result = collect_files_for_mod(&r#mod, &config, &mut groups).await;

        assert!(result.is_ok());
        assert!(groups.is_empty());
    }

    #[tokio::test]
    async fn legacy_manifest_config_mismatch_also_does_not_panic() {
        let guid = Uuid::parse_str("77777777-7777-7777-7777-777777777777").unwrap();
        let r#mod = Mod {
            manifest: Manifest::Legacy(legacy::Manifest {
                guid,
                name: "Legacy Mod".to_string(),
                description: String::new(),
                icon_path: None,
                options: None,
            }),
            directory: PathBuf::from("/nonexistent"),
            sources: Vec::new(),
            display_name: None,
        };
        let config = Config::V2 {
            guid,
            enabled: true,
            toggled: vec![],
            selected: vec![],
        };

        let mut groups = HashMap::new();
        let result = collect_files_for_mod(&r#mod, &config, &mut groups).await;

        assert!(result.is_ok());
        assert!(groups.is_empty());
    }

    /// The Skip List marks patch names whose `.patch_0` is the game's own
    /// file (deploy starts those names at `.patch_1`). Purge, and so the
    /// purge every deploy starts with, must leave that slot 0 alone; every
    /// other patch file, including the skip-listed name's higher slots, goes.
    #[tokio::test]
    async fn purge_keeps_skip_listed_slot_zero_files() {
        let settings: Settings = serde_json::from_str(
            r#"{"Version":"V1","GamePath":"","SkipList":["0123456789abcdef"]}"#,
        )
        .unwrap();
        let data = tempfile::tempdir().unwrap();
        let kept = [
            "0123456789abcdef.patch_0",
            "0123456789abcdef.patch_0.gpu_resources",
            "0123456789abcdef.patch_0.stream",
            "game.bin",
        ];
        let purged = [
            "0123456789abcdef.patch_1",
            "0123456789abcdef.patch_1.stream",
            "0123456789abcdef.patch_10",
            "fedcba9876543210.patch_0",
            "fedcba9876543210.patch_0.gpu_resources",
        ];
        for name in kept.iter().chain(purged.iter()) {
            tokio::fs::write(data.path().join(name), b"x").await.unwrap();
        }

        do_purge(data.path(), &settings).await.unwrap();

        for name in kept {
            assert!(data.path().join(name).exists(), "{name} must be kept");
        }
        for name in purged {
            assert!(!data.path().join(name).exists(), "{name} must be purged");
        }
    }

    fn write_text_boot_script(dir: &std::path::Path, source: &str) {
        let raw = source.as_bytes();
        let pad = (16 - ((200 + raw.len()) % 16)) % 16;
        let total = 200 + raw.len() + pad;
        let mut header = vec![0u8; 192];
        header[0..4].copy_from_slice(&0xF000_0011u32.to_le_bytes());
        header[4..8].copy_from_slice(&1u32.to_le_bytes());
        header[8..12].copy_from_slice(&1u32.to_le_bytes());
        header[0x20..0x28].copy_from_slice(&(total as u64).to_le_bytes());
        let lua = [0xe2, 0x17, 0xd1, 0x2c, 0xfa, 0x8d, 0x4e, 0xa1];
        header[0x50..0x58].copy_from_slice(&lua);
        header[0x68..0x70].copy_from_slice(&boot_deploy::BOOT_RESOURCE);
        header[0x70..0x78].copy_from_slice(&lua);
        header[0xA0..0xA4].copy_from_slice(&((raw.len() + 8) as u32).to_le_bytes());
        let mut body = header;
        body.extend_from_slice(&(raw.len() as u32).to_le_bytes());
        body.extend_from_slice(&2u32.to_le_bytes());
        body.extend_from_slice(raw);
        body.extend(std::iter::repeat(0u8).take(pad));
        std::fs::write(dir.join("9ba626afa44a3aa3.patch_0"), body).unwrap();
    }

    /// Two enabled mods that each replace the boot script deploy as one
    /// file that still contains both sources. A non-Lua patch that shares
    /// the filename is copied beside it.
    #[tokio::test]
    async fn two_boot_scripts_deploy_as_one_file() {
        let data = tempfile::tempdir().unwrap();
        let alpha = tempfile::tempdir().unwrap();
        let beta = tempfile::tempdir().unwrap();
        let mesh = tempfile::tempdir().unwrap();
        write_text_boot_script(alpha.path(), "marker_alpha = true\n");
        write_text_boot_script(beta.path(), "marker_beta = true\n");
        // Same filename, not a Lua boot script.
        std::fs::write(mesh.path().join("9ba626afa44a3aa3.patch_0"), b"MESH-NOT-A-BOOT-SCRIPT").unwrap();

        let (alpha_mod, alpha_cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", alpha.path());
        let (beta_mod, beta_cfg) = legacy_mod("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", beta.path());
        let (mesh_mod, mesh_cfg) = legacy_mod("cccccccc-cccc-4ccc-8ccc-cccccccccccc", mesh.path());
        let mods = vec![alpha_mod, beta_mod, mesh_mod];
        let configs = vec![alpha_cfg, beta_cfg, mesh_cfg];

        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs))
            .await
            .unwrap();

        let mut boot = Vec::new();
        let mut mesh_kept = false;
        for entry in std::fs::read_dir(data.path()).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if name.ends_with("gpu_resources") || name.ends_with(".stream") || name.starts_with('.') {
                continue;
            }
            let bytes = std::fs::read(&path).unwrap();
            let is_boot = bytes.windows(b"marker_alpha".len()).any(|w| w == b"marker_alpha")
                || bytes.windows(b"marker_beta".len()).any(|w| w == b"marker_beta");
            if bytes.windows(b"MESH-NOT-A-BOOT-SCRIPT".len()).any(|w| w == b"MESH-NOT-A-BOOT-SCRIPT") {
                mesh_kept = true;
            }
            if is_boot {
                boot.push(bytes);
            }
        }
        assert_eq!(boot.len(), 1, "deploy wrote more than one boot script");
        let text = String::from_utf8_lossy(&boot[0]);
        assert!(text.contains("marker_alpha = true"));
        assert!(text.contains("marker_beta = true"));
        assert!(mesh_kept, "non-lua patch was dropped");
    }

    /// A loader owns `boot`. It deploys after every other boot script, and
    /// those scripts are not pasted into it.
    #[tokio::test]
    async fn a_loader_deploys_after_other_boot_scripts() {
        let data = tempfile::tempdir().unwrap();
        let file_mod = tempfile::tempdir().unwrap();
        let loader = tempfile::tempdir().unwrap();
        write_text_boot_script(file_mod.path(), "stratagem_swap = true\n");
        write_text_boot_script(loader.path(), "--@@LOADER@@\nChef Shared Loader\n");
        let (file_mod, file_cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", file_mod.path());
        let (loader_mod, loader_cfg) = legacy_mod("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", loader.path());
        // The loader is first in the profile. Deploy must still put it last.
        let mods = vec![loader_mod, file_mod];
        let configs = vec![loader_cfg, file_cfg];
        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs))
            .await
            .unwrap();

        let mut patches = Vec::new();
        for entry in std::fs::read_dir(data.path()).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if name.ends_with("gpu_resources") || name.ends_with(".stream") || !name.contains(".patch_") {
                continue;
            }
            let index: u32 = name.split(".patch_").nth(1).unwrap().parse().unwrap();
            patches.push((index, std::fs::read(path).unwrap()));
        }
        patches.sort_by_key(|(index, _)| *index);
        assert!(
            patches.iter().all(|(_, bytes)| !bytes.windows(b"Chef Shared Loader".len()).any(|w| w == b"Chef Shared Loader")),
            "an installed loader is not deployed"
        );
        assert!(
            patches.iter().any(|(_, bytes)| bytes.windows(b"stratagem_swap".len()).any(|w| w == b"stratagem_swap")),
            "the other boot script still deploys"
        );
    }

    /// Chef's real patch carries the boot stub plus its core, so it is not a
    /// single-payload text boot. It still has to deploy above other boots.
    #[tokio::test]
    async fn a_multi_resource_loader_deploys_after_other_boot_scripts() {
        let data = tempfile::tempdir().unwrap();
        let file_mod = tempfile::tempdir().unwrap();
        let loader = tempfile::tempdir().unwrap();
        write_text_boot_script(file_mod.path(), "stratagem_swap = true\n");
        let mut chef = vec![0u8; 512];
        chef[0..4].copy_from_slice(&0xF000_0011u32.to_le_bytes());
        chef[4..8].copy_from_slice(&2u32.to_le_bytes());
        chef[8..12].copy_from_slice(&3u32.to_le_bytes());
        chef[0x68..0x70].copy_from_slice(&boot_deploy::BOOT_RESOURCE);
        chef.extend(b"--@@LOADER@@\nChef Shared Loader\n");
        std::fs::write(loader.path().join("9ba626afa44a3aa3.patch_0"), chef).unwrap();
        let (file_mod, file_cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", file_mod.path());
        let (loader_mod, loader_cfg) = legacy_mod("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", loader.path());
        let mods = vec![loader_mod, file_mod];
        let configs = vec![loader_cfg, file_cfg];
        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs))
            .await
            .unwrap();

        let mut patches = Vec::new();
        for entry in std::fs::read_dir(data.path()).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if name.ends_with("gpu_resources") || name.ends_with(".stream") || !name.contains(".patch_") {
                continue;
            }
            let index: u32 = name.split(".patch_").nth(1).unwrap().parse().unwrap();
            patches.push((index, std::fs::read(path).unwrap()));
        }
        patches.sort_by_key(|(index, _)| *index);
        assert!(
            patches.iter().all(|(_, bytes)| !bytes.windows(b"Chef Shared Loader".len()).any(|w| w == b"Chef Shared Loader")),
            "Chef is not deployed"
        );
        assert!(
            patches.iter().any(|(_, bytes)| bytes.windows(b"stratagem_swap".len()).any(|w| w == b"stratagem_swap")),
            "the other boot script still deploys"
        );
    }

    /// An `-- HD2-Addon:` script stays in its own archive, under the boot
    /// Ordnance deploys. The installed loader is not copied.
    #[tokio::test]
    async fn an_addon_stays_under_the_ordnance_loader() {
        let data = tempfile::tempdir().unwrap();
        let addon = tempfile::tempdir().unwrap();
        let loader = tempfile::tempdir().unwrap();
        write_text_boot_script(addon.path(), "-- HD2-Addon: mods/test/lamp\nmarker_lamp = true\n");
        write_text_boot_script(loader.path(), "--@@LOADER@@\nChef Shared Loader\n");
        let (addon_mod, addon_cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", addon.path());
        let (loader_mod, loader_cfg) = legacy_mod("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", loader.path());
        let mods = vec![loader_mod, addon_mod];
        let configs = vec![loader_cfg, addon_cfg];
        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs))
            .await
            .unwrap();

        let mut patches = Vec::new();
        for entry in std::fs::read_dir(data.path()).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if name.ends_with("gpu_resources") || name.ends_with(".stream") || !name.contains(".patch_") {
                continue;
            }
            let index: u32 = name.split(".patch_").nth(1).unwrap().parse().unwrap();
            patches.push((index, std::fs::read(path).unwrap()));
        }
        patches.sort_by_key(|(index, _)| *index);
        assert!(patches.len() >= 2, "the addon and the loader should both deploy");
        let mark = boot_deploy::LOADER_MARK.as_bytes();
        let loader_at = patches.iter().position(|(_, bytes)| bytes.windows(mark.len()).any(|w| w == mark)).unwrap();
        let addon_at = patches.iter().position(|(_, bytes)| bytes.windows(b"marker_lamp".len()).any(|w| w == b"marker_lamp")).unwrap();
        assert!(addon_at < loader_at, "the addon archive stays below the Ordnance boot");
        assert!(
            patches.iter().all(|(_, bytes)| {
                let mentions_chef = bytes.windows(b"Chef Shared Loader".len()).any(|w| w == b"Chef Shared Loader");
                let ours = bytes.windows(mark.len()).any(|w| w == mark);
                !mentions_chef || ours
            }),
            "Chef's patch is not deployed"
        );
        assert!(!patches[loader_at].1.windows(b"marker_lamp".len()).any(|w| w == b"marker_lamp"));
    }

    /// Treasure Radar's option files are named like a boot patch but carry a
    /// different resource. They must stay below the Ordnance boot, or the
    /// game runs `return { kinds = ... }` and dies on startup.
    #[tokio::test]
    async fn an_option_declaration_without_the_boot_resource_stays_under_the_loader() {
        let data = tempfile::tempdir().unwrap();
        let option = tempfile::tempdir().unwrap();
        let raw = b"-- HD2-Options: mods/chef/treasure_radar\nreturn { kinds = { weapon = true } }\n";
        let pad = (16 - ((200 + raw.len()) % 16)) % 16;
        let total = 200 + raw.len() + pad;
        let mut header = vec![0u8; 192];
        header[0..4].copy_from_slice(&0xF000_0011u32.to_le_bytes());
        header[4..8].copy_from_slice(&1u32.to_le_bytes());
        header[8..12].copy_from_slice(&1u32.to_le_bytes());
        header[0x20..0x28].copy_from_slice(&(total as u64).to_le_bytes());
        let lua = [0xe2, 0x17, 0xd1, 0x2c, 0xfa, 0x8d, 0x4e, 0xa1];
        header[0x50..0x58].copy_from_slice(&lua);
        header[0x68..0x70].copy_from_slice(&[0xfb, 0xde, 0x5e, 0xba, 0x64, 0x4a, 0x76, 0x86]);
        header[0x70..0x78].copy_from_slice(&lua);
        header[0xA0..0xA4].copy_from_slice(&((raw.len() + 8) as u32).to_le_bytes());
        let mut body = header;
        body.extend_from_slice(&(raw.len() as u32).to_le_bytes());
        body.extend_from_slice(&2u32.to_le_bytes());
        body.extend_from_slice(raw);
        body.extend(std::iter::repeat(0u8).take(pad));
        std::fs::write(option.path().join("9ba626afa44a3aa3.patch_0"), body).unwrap();

        let (option_mod, option_cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", option.path());
        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&[option_mod], &[option_cfg]))
            .await
            .unwrap();

        let mut patches = Vec::new();
        for entry in std::fs::read_dir(data.path()).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if name.ends_with("gpu_resources") || name.ends_with(".stream") || !name.contains(".patch_") {
                continue;
            }
            let index: u32 = name.split(".patch_").nth(1).unwrap().parse().unwrap();
            patches.push((index, std::fs::read(path).unwrap()));
        }
        patches.sort_by_key(|(index, _)| *index);
        assert!(patches.len() >= 2, "the declaration and the loader should both deploy");
        let mark = boot_deploy::LOADER_MARK.as_bytes();
        let loader_at = patches.iter().position(|(_, bytes)| bytes.windows(mark.len()).any(|w| w == mark)).unwrap();
        let option_at = patches
            .iter()
            .position(|(_, bytes)| bytes.windows(b"HD2-Options:".len()).any(|w| w == b"HD2-Options:"))
            .unwrap();
        assert!(option_at < loader_at, "the options snippet must not be the boot the game runs");
        assert_eq!(loader_at, patches.len() - 1, "the Ordnance boot has to be the highest patch");
        assert!(!patches[loader_at].1.windows(b"kinds = { weapon = true }".len()).any(|w| w == b"kinds = { weapon = true }"));
    }

    /// A loader mod's other archives (Rat's intro, Chef's core) stay out of
    /// the game. The manifest is what ties them to the loader patch.
    #[tokio::test]
    async fn an_installed_loader_mod_deploys_nothing_of_its_own() {
        let data = tempfile::tempdir().unwrap();
        let loader = tempfile::tempdir().unwrap();
        std::fs::write(loader.path().join("manifest.json"), b"{}").unwrap();
        write_text_boot_script(loader.path(), "--@@LOADER@@\nChef Shared Loader\n");
        std::fs::write(loader.path().join("007e093ca718ca1a.patch_0"), b"RAT-NATIVE").unwrap();
        let (loader_mod, loader_cfg) = legacy_mod("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", loader.path());
        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&[loader_mod], &[loader_cfg]))
            .await
            .unwrap();
        for entry in std::fs::read_dir(data.path()).unwrap() {
            let path = entry.unwrap().path();
            if path.is_file() {
                let bytes = std::fs::read(&path).unwrap_or_default();
                assert!(!bytes.windows(b"RAT-NATIVE".len()).any(|w| w == b"RAT-NATIVE"), "{}", path.display());
                assert!(!bytes.windows(b"Chef Shared Loader".len()).any(|w| w == b"Chef Shared Loader"), "{}", path.display());
            }
        }
    }

    fn legacy_mod(guid: &str, dir: &std::path::Path) -> (Mod, Config) {
        let guid = Uuid::parse_str(guid).unwrap();
        let r#mod = Mod {
            manifest: Manifest::Legacy(legacy::Manifest {
                guid,
                name: guid.to_string(),
                description: String::new(),
                icon_path: None,
                options: None,
            }),
            directory: dir.to_path_buf(),
            sources: Vec::new(),
            display_name: None,
        };
        (r#mod, Config::Legacy { guid, enabled: true, selected: 0 })
    }

    fn skip_list(name: &str) -> Settings {
        serde_json::from_str(&format!(r#"{{"Version":"V1","GamePath":"","SkipList":["{name}"]}}"#)).unwrap()
    }

    /// A mod deployed into slot 0 of a name that was added to the Skip List
    /// only afterwards is Ordnance's file, not the game's: the next purge must
    /// still remove it.
    #[tokio::test]
    async fn purge_removes_ordnance_slot_zero_files_of_a_name_skip_listed_later() {
        let data = tempfile::tempdir().unwrap();
        let m = tempfile::tempdir().unwrap();
        write_patch_file(m.path(), 0).await;
        let (r#mod, cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", m.path());
        let mods = vec![r#mod];
        let configs = vec![cfg];

        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs)).await.unwrap();
        let slot0 = data.path().join(patch_file_name(0));
        assert!(slot0.exists());

        do_purge(data.path(), &skip_list("0123456789abcdef")).await.unwrap();
        assert!(!slot0.exists(), "Ordnance's own slot-0 file must be purged");
        assert!(!data.path().join(format!("{}.stream", patch_file_name(0))).exists());
        assert!(!data.path().join(DEPLOY_RECORD).exists(), "purge removes the record");

        // A deploy with the name skip-listed starts at slot 1 and leaves a
        // game file in slot 0 alone, through the purge of the next deploy.
        tokio::fs::write(&slot0, b"game").await.unwrap();
        do_deploy(data.path(), &skip_list("0123456789abcdef"), pair_mods_with_configs(&mods, &configs)).await.unwrap();
        do_deploy(data.path(), &skip_list("0123456789abcdef"), pair_mods_with_configs(&mods, &configs)).await.unwrap();
        assert_eq!(tokio::fs::read(&slot0).await.unwrap(), b"game");
        assert_eq!(tokio::fs::read(data.path().join(patch_file_name(1))).await.unwrap(), b"data");
    }

    /// Ordnance deployed into slot 0, the name was skip-listed afterwards, and
    /// then something else (a Steam "verify files") put the game's own
    /// file back. The record no longer matches it, so purge keeps it --
    /// whether its length or only its modification time changed.
    #[tokio::test]
    async fn purge_keeps_a_recorded_slot_zero_file_that_was_replaced_since() {
        for same_length in [false, true] {
            let data = tempfile::tempdir().unwrap();
            let m = tempfile::tempdir().unwrap();
            write_patch_file(m.path(), 0).await;
            let (r#mod, cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", m.path());
            let mods = vec![r#mod];
            let configs = vec![cfg];
            do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs)).await.unwrap();

            let slot0 = data.path().join(patch_file_name(0));
            let restored: &[u8] = if same_length { b"game" } else { b"the game's own file" };
            tokio::fs::write(&slot0, restored).await.unwrap();
            let file = std::fs::OpenOptions::new().write(true).open(&slot0).unwrap();
            file.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000)).unwrap();
            drop(file);

            do_purge(data.path(), &skip_list("0123456789abcdef")).await.unwrap();
            assert_eq!(tokio::fs::read(&slot0).await.unwrap(), restored, "same length: {same_length}");
            // The untouched companions Ordnance wrote still match: purged.
            assert!(!data.path().join(format!("{}.stream", patch_file_name(0))).exists());
        }
    }

    /// The record can't be written (here a folder is in its way): the
    /// deploy still goes through, and purge still works without it.
    #[tokio::test]
    async fn a_deploy_record_that_cant_be_written_doesnt_fail_the_deploy() {
        let data = tempfile::tempdir().unwrap();
        tokio::fs::create_dir(data.path().join(DEPLOY_RECORD)).await.unwrap();
        let m = tempfile::tempdir().unwrap();
        write_patch_file(m.path(), 0).await;
        let (r#mod, cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", m.path());
        let mods = vec![r#mod];
        let configs = vec![cfg];

        do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs)).await.unwrap();
        let slot0 = data.path().join(patch_file_name(0));
        assert_eq!(tokio::fs::read(&slot0).await.unwrap(), b"data");

        // No usable record: a skip-listed slot 0 is kept, the rest purged.
        tokio::fs::write(data.path().join(patch_file_name(1)), b"x").await.unwrap();
        do_purge(data.path(), &skip_list("0123456789abcdef")).await.unwrap();
        assert!(slot0.exists());
        assert!(!data.path().join(patch_file_name(1)).exists());
    }

    /// No record (a game folder last deployed by an older version) or a
    /// damaged one: a skip-listed slot-0 file can't be shown to be Ordnance's,
    /// so it is kept. Everything else is still purged.
    #[tokio::test]
    async fn without_a_usable_record_skip_listed_slot_zero_is_kept() {
        for record in [None, Some(&b"{not json"[..]), Some(&b"{\"Files\": 7}"[..])] {
            let data = tempfile::tempdir().unwrap();
            let slot0 = data.path().join(patch_file_name(0));
            let slot1 = data.path().join(patch_file_name(1));
            tokio::fs::write(&slot0, b"x").await.unwrap();
            tokio::fs::write(&slot1, b"x").await.unwrap();
            if let Some(record) = record {
                tokio::fs::write(data.path().join(DEPLOY_RECORD), record).await.unwrap();
            }

            do_purge(data.path(), &skip_list("0123456789abcdef")).await.unwrap();
            assert!(slot0.exists(), "record {record:?}: slot 0 must be kept");
            assert!(!slot1.exists(), "record {record:?}: slot 1 must be purged");
            assert!(!data.path().join(DEPLOY_RECORD).exists());
        }
    }

    fn no_skip_list() -> Settings {
        serde_json::from_str(r#"{"Version":"V1","GamePath":"","SkipList":[]}"#).unwrap()
    }

    fn broken_mod(dir: &Path) -> (Mod, Config) {
        let guid = Uuid::parse_str("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb").unwrap();
        let r#mod = Mod {
            manifest: Manifest::Legacy(legacy::Manifest {
                guid,
                name: "broken".into(),
                description: String::new(),
                icon_path: None,
                options: Some(vec!["NotThere".into()]),
            }),
            directory: dir.to_path_buf(),
            sources: Vec::new(),
            display_name: None,
        };
        let config = Config::Legacy { guid, enabled: true, selected: 0 };
        (r#mod, config)
    }

    /// One mod whose option folder is missing is left out. The other mod
    /// still deploys, which replaces the previous deploy.
    #[tokio::test]
    async fn one_mod_failing_does_not_stop_the_others() {
        let data = tempfile::tempdir().unwrap();
        let previous = data.path().join("fedcba9876543210.patch_0");
        tokio::fs::write(&previous, b"deployed last time").await.unwrap();

        let good = tempfile::tempdir().unwrap();
        write_patch_file(good.path(), 0).await;
        let (good_mod, good_cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", good.path());
        let broken = tempfile::tempdir().unwrap();
        let (broken_mod, broken_cfg) = broken_mod(broken.path());

        let mods = vec![good_mod, broken_mod];
        let configs = vec![good_cfg, broken_cfg];
        let report = do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs))
            .await
            .unwrap();
        assert!(report.deployed);
        assert!(report.skipped.iter().any(|skip| skip.name == "broken" && skip.message.contains("NotThere")), "{:?}", report.skipped);
        assert!(!previous.exists(), "a deploy that lands the good mod replaces the previous one");
        assert_eq!(tokio::fs::read(data.path().join(patch_file_name(0))).await.unwrap(), b"data");
        assert!(data.path().join(format!("{}.gpu_resources", patch_file_name(0))).exists());
        assert!(data.path().join(format!("{}.stream", patch_file_name(0))).exists());
    }

    /// When every mod is left out, the previous deploy stays where it is.
    #[tokio::test]
    async fn a_deploy_that_skips_every_mod_leaves_the_previous_deploy_in_place() {
        let data = tempfile::tempdir().unwrap();
        let previous = data.path().join("fedcba9876543210.patch_0");
        tokio::fs::write(&previous, b"deployed last time").await.unwrap();

        let broken = tempfile::tempdir().unwrap();
        let (broken_mod, broken_cfg) = broken_mod(broken.path());
        let mods = vec![broken_mod];
        let configs = vec![broken_cfg];
        let report = do_deploy(data.path(), &no_skip_list(), pair_mods_with_configs(&mods, &configs))
            .await
            .unwrap();
        assert!(!report.deployed);
        assert!(report.skipped.iter().any(|skip| skip.message.contains("NotThere")));
        assert!(previous.exists(), "skipping every mod must not purge");
        assert!(!data.path().join(patch_file_name(0)).exists());
    }

    /// The deploy index of a file is its position in its group, so this pins
    /// down the load order: list order top to bottom, and a mod's own
    /// patch files in ascending order.
    #[tokio::test]
    async fn load_order_follows_list_order_then_each_mods_own_patch_order() {
        let top = tempfile::tempdir().unwrap();
        let bottom = tempfile::tempdir().unwrap();
        for i in [3, 0, 2, 1] {
            write_patch_file(top.path(), i).await;
        }
        write_patch_file(bottom.path(), 0).await;
        let (top_mod, top_cfg) = legacy_mod("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", top.path());
        let (bottom_mod, bottom_cfg) = legacy_mod("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", bottom.path());

        let mods = vec![bottom_mod, top_mod];
        // The profile list order, top first (not the installed-mods order).
        let configs = vec![top_cfg, bottom_cfg];
        let mut groups = HashMap::new();
        for (r#mod, config) in pair_mods_with_configs(&mods, &configs) {
            collect_files_for_mod(r#mod, config, &mut groups).await.unwrap();
        }

        let order: Vec<PathBuf> = groups["0123456789abcdef"]
            .iter()
            .map(|t| t.patch.clone().unwrap())
            .collect();
        let expected: Vec<PathBuf> = (0..4)
            .map(|i| top.path().join(patch_file_name(i)))
            .chain(std::iter::once(bottom.path().join(patch_file_name(0))))
            .collect();
        assert_eq!(order, expected, "bottom mod must get the highest patch index");
    }

    #[test]
    fn stock_backup_follows_the_game_file_only_when_it_is_new_vanilla() {
        let vanilla = b"vanilla-table".as_slice();
        let patched = b"patched-table".as_slice();
        let updated = b"updated-vanilla".as_slice();
        assert!(game_file_replaces_stock(Some(vanilla), None, None), "first seed");
        assert!(!game_file_replaces_stock(None, None, None), "nothing to seed from");
        assert!(!game_file_replaces_stock(Some(vanilla), Some(vanilla), None));
        assert!(
            !game_file_replaces_stock(Some(patched), Some(vanilla), Some(patched)),
            "the previous deploy's output must not become the stock backup"
        );
        assert!(
            game_file_replaces_stock(Some(updated), Some(vanilla), Some(patched)),
            "a steam update matches neither backup"
        );
    }

    #[tokio::test]
    async fn a_reseal_of_the_same_vanilla_does_not_replace_the_stock_backup() {
        let data = tempfile::tempdir().unwrap();
        let game = data.path().join("game");
        let stock = data.path().join("ordnance-stock");
        tokio::fs::create_dir_all(&game).await.unwrap();
        tokio::fs::create_dir_all(&stock).await.unwrap();
        let plain = b"same vanilla plaintext";
        let stock_seal = hd2edit::seal(plain);
        let game_seal = hd2edit::seal(plain);
        assert_ne!(stock_seal, game_seal, "two seals of one plaintext differ");
        let name = "generated_entities.dl_bin";
        tokio::fs::write(stock.join(name), &stock_seal).await.unwrap();
        tokio::fs::write(game.join(name), &game_seal).await.unwrap();

        refresh_stat_stock(&game, &stock, &[]).await.unwrap();

        assert_eq!(tokio::fs::read(stock.join(name)).await.unwrap(), stock_seal);
    }

    #[tokio::test]
    async fn a_changed_table_the_plans_do_not_edit_replaces_the_stock_backup() {
        let data = tempfile::tempdir().unwrap();
        let game = data.path().join("game");
        let stock = data.path().join("ordnance-stock");
        tokio::fs::create_dir_all(&game).await.unwrap();
        tokio::fs::create_dir_all(&stock).await.unwrap();
        let name = "generated_damage_settings.dl_bin";
        let stock_seal = hd2edit::seal(b"october vanilla");
        let game_seal = hd2edit::seal(b"november vanilla");
        tokio::fs::write(stock.join(name), &stock_seal).await.unwrap();
        tokio::fs::write(game.join(name), &game_seal).await.unwrap();

        refresh_stat_stock(&game, &stock, &[]).await.unwrap();

        assert_eq!(tokio::fs::read(stock.join(name)).await.unwrap(), game_seal);
    }

    #[tokio::test]
    async fn a_different_length_stock_backup_is_replaced_by_the_game_file() {
        let data = tempfile::tempdir().unwrap();
        let game = data.path().join("game");
        let stock = data.path().join("ordnance-stock");
        tokio::fs::create_dir_all(&game).await.unwrap();
        tokio::fs::create_dir_all(&stock).await.unwrap();
        let name = "generated_stratagem_settings.dl_bin";
        let game_seal = hd2edit::seal(b"official-82424");
        let stock_seal = hd2edit::seal(b"official-82424-and-more");
        assert_ne!(b"official-82424".len(), b"official-82424-and-more".len());
        tokio::fs::write(stock.join(name), &stock_seal).await.unwrap();
        tokio::fs::write(game.join(name), &game_seal).await.unwrap();
        // A plan that cannot be applied used to leave the longer backup in
        // place. The next deploy then wrote that backup over the game.
        let edit = serde_json::json!({
            "file": name, "type": "0x30EB6399", "section": 0, "stride": 400,
            "record": 1, "offset": 368, "kind": "u32", "value": 0, "op": "set"
        });

        refresh_stat_stock(&game, &stock, &[edit]).await.unwrap();

        assert_eq!(tokio::fs::read(stock.join(name)).await.unwrap(), game_seal);
    }
}
