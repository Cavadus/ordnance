use std::path::Path;

use anyhow_tauri::{IntoTAResult, TAResult};
use tauri::State;
use uuid::Uuid;

use crate::{AppState, models::categories::Categories};

const CATEGORIES_FILE: &str = "categories.json";

/// Serializes every read-modify-write of categories.json so two writers can't
/// interleave (the data folder move already excludes the app, but two category
/// commands can race each other).
static CATEGORIES_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn lock_categories() -> tokio::sync::MutexGuard<'static, ()> {
    CATEGORIES_LOCK.lock().await
}

async fn do_load_categories(base_path: &Path) -> anyhow::Result<Categories> {
    let file = base_path.join(CATEGORIES_FILE);
    if tokio::fs::try_exists(&file).await? {
        let data = tokio::fs::read(&file).await?;
        serde_json::from_slice(&data)
            .map_err(|e| anyhow::anyhow!("{:?} isn't a valid categories file: {e}", file))
    } else {
        Ok(Categories::default())
    }
}

async fn write_categories(base_path: &Path, categories: &Categories) -> anyhow::Result<()> {
    let data = serde_json::to_vec_pretty(categories)?;
    crate::fs_util::replace_file(&base_path.join(CATEGORIES_FILE), &data).await
}

async fn update_categories(
    base_path: &Path,
    change: impl FnOnce(&mut Categories) -> anyhow::Result<()>,
) -> anyhow::Result<Categories> {
    let _lock = lock_categories().await;
    let mut categories = do_load_categories(base_path).await?;
    change(&mut categories)?;
    write_categories(base_path, &categories).await?;
    Ok(categories)
}

/// All user-defined categories and their mod assignments.
#[tauri::command]
pub async fn get_categories(state: State<'_, AppState>) -> TAResult<Categories> {
    let _data_op = state.data_op().into_ta_result()?;
    do_load_categories(&state.base_path).await.into_ta_result()
}

/// Create a category with the given name and return it. Fails on an empty or
/// whitespace-only name.
#[tauri::command]
pub async fn create_category(state: State<'_, AppState>, name: String) -> TAResult<Categories> {
    let _data_op = state.data_op().into_ta_result()?;
    update_categories(&state.base_path, move |categories| {
        let name = name.trim().to_string();
        anyhow::ensure!(!name.is_empty(), "A category name can't be empty.");
        categories.add(name);
        Ok(())
    })
    .await
    .into_ta_result()
}

/// Rename a category. Returns the updated categories on success.
#[tauri::command]
pub async fn rename_category(state: State<'_, AppState>, guid: String, name: String) -> TAResult<Categories> {
    let _data_op = state.data_op().into_ta_result()?;
    let guid = Uuid::parse_str(&guid)
        .map_err(|_| anyhow::anyhow!("{guid:?} isn't a valid category GUID"))?;
    update_categories(&state.base_path, move |categories| {
        let name = name.trim().to_string();
        anyhow::ensure!(!name.is_empty(), "A category name can't be empty.");
        anyhow::ensure!(
            categories.rename(guid, name).is_some(),
            "No category with that GUID exists."
        );
        Ok(())
    })
    .await
    .into_ta_result()
}

/// Delete a category and unassign every mod in it.
#[tauri::command]
pub async fn delete_category(state: State<'_, AppState>, guid: String) -> TAResult<Categories> {
    let _data_op = state.data_op().into_ta_result()?;
    let guid = Uuid::parse_str(&guid)
        .map_err(|_| anyhow::anyhow!("{guid:?} isn't a valid category GUID"))?;
    update_categories(&state.base_path, |categories| {
        anyhow::ensure!(
            categories.remove(guid).is_some(),
            "No category with that GUID exists."
        );
        Ok(())
    })
    .await
    .into_ta_result()
}

/// Assign a mod to a category (`category_guid = None` clears it).
/// `mod_guid` is the mod's manifest GUID string.
#[tauri::command]
pub async fn set_mod_category(
    state: State<'_, AppState>,
    mod_guid: String,
    category_guid: Option<String>,
) -> TAResult<Categories> {
    let _data_op = state.data_op().into_ta_result()?;
    let category = match category_guid {
        Some(s) => Some(
            Uuid::parse_str(&s).map_err(|_| anyhow::anyhow!("{s:?} isn't a valid category GUID"))?,
        ),
        None => None,
    };
    update_categories(&state.base_path, |categories| {
        if let Some(guid) = category {
            anyhow::ensure!(
                categories.categories().iter().any(|c| c.guid == guid),
                "No category with that GUID exists."
            );
        }
        categories.assign(&mod_guid, category);
        Ok(())
    })
    .await
    .into_ta_result()
}
