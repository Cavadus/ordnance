use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase", tag = "For")]
pub enum Config {
    #[serde(rename_all = "PascalCase")]
    Legacy {
        guid: Uuid,
        enabled: bool,
        selected: usize,
    },
    #[serde(rename_all = "PascalCase")]
    V1 {
        guid: Uuid,
        enabled: bool,
        toggled: Vec<bool>,
        selected: Vec<usize>,
    },
    #[serde(rename_all = "PascalCase")]
    V2 {
        guid: Uuid,
        enabled: bool,
        toggled: Vec<bool>,
        selected: Vec<usize>,
    }
}

impl Config {
    pub fn uuid(&self) -> &Uuid {
        match self {
            Config::Legacy { guid, .. } => guid,
            Config::V1 { guid, .. } => guid,
            Config::V2 { guid, .. } => guid,
        }
    }

    pub fn set_uuid(&mut self, new: Uuid) {
        match self {
            Config::Legacy { guid, .. } | Config::V1 { guid, .. } | Config::V2 { guid, .. } => *guid = new,
        }
    }

    pub fn enabled(&self) -> bool {
        match self {
            Config::Legacy { enabled, .. } => *enabled,
            Config::V1 { enabled, .. } => *enabled,
            Config::V2 { enabled, .. } => *enabled,
        }
    }

    /// Per-option toggles, in manifest order. Legacy configs have none.
    pub fn toggles(&self) -> &[bool] {
        match self {
            Config::Legacy { .. } => &[],
            Config::V1 { toggled, .. } | Config::V2 { toggled, .. } => toggled,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase", tag = "Version")]
pub enum Profile {
    #[serde(rename_all = "PascalCase")]
    V1 {
        name: String,
        /// `#rrggbb`. Empty on files written before profile colors existed;
        /// the sidebar paints those from the same palette as categories.
        #[serde(default)]
        color: String,
        configs: Vec<Config>,
    }
}

impl Profile {
    pub fn new(name: &str) -> Self {
        Profile::V1 {
            name: name.to_string(),
            color: String::new(),
            configs: Vec::new()
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Profile::V1 { name, .. } => name,
        }
    }
    
    pub fn configs(&self) -> &[Config] {
        match self {
            Profile::V1 { configs, .. } => configs.as_slice(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ProfilesConfig {
    pub profiles: Vec<Profile>,
    pub active: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_profile_file_from_before_colors_still_loads() {
        let raw = r#"{"Profiles":[{"Version":"V1","Name":"Default","Configs":[]}],"Active":0}"#;
        let parsed: ProfilesConfig = serde_json::from_str(raw).unwrap();
        match &parsed.profiles[0] {
            Profile::V1 { name, color, .. } => {
                assert_eq!(name, "Default");
                assert_eq!(color, "");
            }
        }
    }
}