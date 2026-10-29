use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// One user-defined grouping. A mod can belong to at most one category
/// (see `Categories::assignments`); uncategorized mods simply have no entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Category {
    pub guid: Uuid,
    pub name: String,
}

/// Everything the category feature persists, versioned so future fields can
/// be added without breaking old files. Mirrors the settings/profile files:
/// a top-level `Version` tag plus a PascalCase body.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "Version", rename_all = "PascalCase")]
pub enum Categories {
    #[serde(rename_all = "PascalCase")]
    V1 {
        #[serde(default)]
        categories: Vec<Category>,
        /// Mod GUID -> category GUID. Keys are the mod's manifest GUID string.
        #[serde(default)]
        assignments: HashMap<String, Uuid>,
    },
}

impl Default for Categories {
    fn default() -> Self {
        Categories::V1 {
            categories: Vec::new(),
            assignments: HashMap::new(),
        }
    }
}

impl Categories {
    pub fn categories(&self) -> &[Category] {
        match self {
            Categories::V1 { categories, .. } => categories,
        }
    }

    pub fn assignments(&self) -> &HashMap<String, Uuid> {
        match self {
            Categories::V1 { assignments, .. } => assignments,
        }
    }

    fn categories_mut(&mut self) -> &mut Vec<Category> {
        match self {
            Categories::V1 { categories, .. } => categories,
        }
    }

    fn assignments_mut(&mut self) -> &mut HashMap<String, Uuid> {
        match self {
            Categories::V1 { assignments, .. } => assignments,
        }
    }

    /// Add a category and return it. Name is trimmed; an empty name is rejected
    /// by the caller.
    pub fn add(&mut self, name: String) -> Category {
        let category = Category {
            guid: Uuid::new_v4(),
            name,
        };
        self.categories_mut().push(category.clone());
        category
    }

    /// Rename a category by GUID. Returns `None` when no such category exists.
    pub fn rename(&mut self, guid: Uuid, name: String) -> Option<()> {
        let category = self.categories_mut().iter_mut().find(|c| c.guid == guid)?;
        category.name = name;
        Some(())
    }

    /// Delete a category and drop its assignments. Returns `None` when no
    /// such category exists.
    pub fn remove(&mut self, guid: Uuid) -> Option<()> {
        let categories = self.categories_mut();
        let index = categories.iter().position(|c| c.guid == guid)?;
        categories.remove(index);
        let assignments = self.assignments_mut();
        assignments.retain(|_, cat| *cat != guid);
        Some(())
    }

    /// Assign a mod (by manifest GUID string) to a category, or `None` to
    /// clear it. Silently ignores assignments to a category that does not
    /// exist (the caller validates first).
    pub fn assign(&mut self, mod_guid: &str, category: Option<Uuid>) {
        match category {
            Some(guid) => {
                self.assignments_mut().insert(mod_guid.to_string(), guid);
            }
            None => {
                self.assignments_mut().remove(mod_guid);
            }
        }
    }
}
