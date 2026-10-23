//! Stat-mod compiler.
//!
//! Democracy Defender deploys `<hex>.patch_N` files into `data/` and does not
//! open `data/game/*.dl_bin`. Ordnance keeps that path for sounds and other
//! resource patches. A stat mod ships an edit list instead of a finished
//! `.dl_bin`. [`compile`] applies every enabled mod, in profile order, onto
//! one swap per table. Later mods win when two edits hit the same field.
//!
//! Unsealing, applying the bytes, hash-correcting, and resealing are the next
//! step. This module is the plan those steps will execute.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One sealed game table. The compiler writes one file per table, not one
/// blob for the whole game.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Table {
    Entities,
    Projectile,
    Damage,
    Explosion,
}

impl Table {
    pub fn file_name(self) -> &'static str {
        match self {
            Self::Entities => "generated_entities.dl_bin",
            Self::Projectile => "generated_projectile_settings.dl_bin",
            Self::Damage => "generated_damage_settings.dl_bin",
            Self::Explosion => "generated_explosion_settings.dl_bin",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum EditValue {
    Int(i64),
    Float(f64),
    Text(String),
}

/// One field write. `field` is the name the mod author uses (`speed`,
/// `impact_explosion`, `spare_magazines`), not a raw offset. Offset lookup
/// belongs to the apply step.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StatEdit {
    pub table: Table,
    pub record: u32,
    pub field: String,
    pub value: EditValue,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModEdits {
    pub name: String,
    pub edits: Vec<StatEdit>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Conflict {
    pub table: Table,
    pub record: u32,
    pub field: String,
    pub winner: String,
    pub loser: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CompiledSwap {
    /// Keyed by table, record, field. The value is the winning mod and the
    /// value it wrote.
    pub edits: BTreeMap<(Table, u32, String), (String, EditValue)>,
    pub conflicts: Vec<Conflict>,
}

impl CompiledSwap {
    pub fn tables(&self) -> Vec<Table> {
        let mut out = Vec::new();
        for (table, _, _) in self.edits.keys() {
            if !out.contains(table) {
                out.push(*table);
            }
        }
        out
    }
}

/// Apply mods in the order given. The last edit of a field wins.
pub fn compile(mods: &[ModEdits]) -> CompiledSwap {
    let mut edits: BTreeMap<(Table, u32, String), (String, EditValue)> = BTreeMap::new();
    let mut conflicts = Vec::new();
    for m in mods {
        for edit in &m.edits {
            let key = (edit.table, edit.record, edit.field.clone());
            if let Some((previous, _)) = edits.get(&key) {
                conflicts.push(Conflict {
                    table: edit.table,
                    record: edit.record,
                    field: edit.field.clone(),
                    winner: m.name.clone(),
                    loser: previous.clone(),
                });
            }
            edits.insert(key, (m.name.clone(), edit.value.clone()));
        }
    }
    CompiledSwap { edits, conflicts }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(table: Table, record: u32, field: &str, value: EditValue) -> StatEdit {
        StatEdit {
            table,
            record,
            field: field.to_string(),
            value,
        }
    }

    #[test]
    fn later_mod_wins_and_the_clash_is_reported() {
        let mods = [
            ModEdits {
                name: "dominator".into(),
                edits: vec![edit(
                    Table::Projectile,
                    0xb4,
                    "speed",
                    EditValue::Float(380.0),
                )],
            },
            ModEdits {
                name: "hotter".into(),
                edits: vec![edit(
                    Table::Projectile,
                    0xb4,
                    "speed",
                    EditValue::Float(450.0),
                )],
            },
        ];
        let swap = compile(&mods);
        let (_, value) = &swap.edits[&(Table::Projectile, 0xb4, "speed".into())];
        assert_eq!(value, &EditValue::Float(450.0));
        assert_eq!(swap.conflicts.len(), 1);
        assert_eq!(swap.conflicts[0].winner, "hotter");
        assert_eq!(swap.conflicts[0].loser, "dominator");
    }

    #[test]
    fn disjoint_edits_share_one_swap_per_table() {
        let mods = [ModEdits {
            name: "dominator".into(),
            edits: vec![
                edit(Table::Projectile, 0xb4, "speed", EditValue::Float(450.0)),
                edit(Table::Explosion, 216, "outer_radius", EditValue::Float(2.0)),
            ],
        }];
        let swap = compile(&mods);
        assert!(swap.conflicts.is_empty());
        assert_eq!(
            swap.tables(),
            vec![Table::Projectile, Table::Explosion]
        );
        assert_eq!(
            Table::Explosion.file_name(),
            "generated_explosion_settings.dl_bin"
        );
    }
}
