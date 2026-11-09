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
    /// `#rrggbb`. Empty on files written before colors existed; the UI
    /// paints those from a fixed palette until the user picks one.
    #[serde(default)]
    pub color: String,
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
    /// by the caller. The color is the next palette entry not already used.
    pub fn add(&mut self, name: String) -> Category {
        let category = Category {
            guid: Uuid::new_v4(),
            name,
            color: self.next_color(),
        };
        self.categories_mut().push(category.clone());
        category
    }

    /// `#rrggbb`. The caller checks the shape.
    pub fn set_color(&mut self, guid: Uuid, color: String) -> Option<()> {
        let category = self.categories_mut().iter_mut().find(|c| c.guid == guid)?;
        category.color = color;
        Some(())
    }

    fn next_color(&self) -> String {
        // Keep this in step with `CATEGORY_PALETTE` in
        // `src/lib/utils/categoryGroups.ts`.
        const PALETTE: [&str; 8] = [
            "#eab308", "#60a5fa", "#4ade80", "#f87171", "#c084fc", "#fb923c", "#22d3ee", "#f472b6",
        ];
        // An old file has no color. The UI paints that category with the
        // palette entry for its position, so a new category must not take
        // that same entry.
        let mut used = Vec::new();
        for (index, category) in self.categories().iter().enumerate() {
            if category.color.is_empty() {
                used.push(PALETTE[index % PALETTE.len()]);
            } else {
                used.push(category.color.as_str());
            }
        }
        PALETTE
            .iter()
            .copied()
            .find(|color| !used.contains(color))
            .unwrap_or(PALETTE[self.categories().len() % PALETTE.len()])
            .to_string()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_category_file_from_before_colors_still_loads() {
        let raw = r#"{
            "Version": "V1",
            "Categories": [{ "Guid": "6b0e0c1a-1b2c-4d5e-8f90-123456789abc", "Name": "Audio" }],
            "Assignments": { "mod-1": "6b0e0c1a-1b2c-4d5e-8f90-123456789abc" }
        }"#;
        let parsed: Categories = serde_json::from_str(raw).unwrap();
        assert_eq!(parsed.categories()[0].name, "Audio");
        assert_eq!(parsed.categories()[0].color, "");
        assert_eq!(parsed.assignments().len(), 1);
    }

    #[test]
    fn new_categories_get_distinct_colors() {
        let mut categories = Categories::default();
        let audio = categories.add("Audio".into());
        let visual = categories.add("Visual".into());
        assert_eq!(audio.color, "#eab308");
        assert_eq!(visual.color, "#60a5fa");
        categories.set_color(audio.guid, "#112233".into()).unwrap();
        assert_eq!(categories.categories()[0].color, "#112233");
    }

    #[test]
    fn a_new_category_skips_the_color_an_old_one_is_already_showing() {
        let mut categories: Categories = serde_json::from_str(
            r#"{
                "Version": "V1",
                "Categories": [{ "Guid": "6b0e0c1a-1b2c-4d5e-8f90-123456789abc", "Name": "Audio" }],
                "Assignments": {}
            }"#,
        )
        .unwrap();
        let visual = categories.add("Visual".into());
        assert_eq!(visual.color, "#60a5fa");
    }
}
