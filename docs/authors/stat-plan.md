# The stat-plan format

A **stat-plan** is a declarative list of field-level edits to Helldivers 2's
sealed .dl_bin data tables. It is not a file replacement: the mod ships the
*intent* ("set this field to this value"), and a mod manager applies that
intent to the game's own files at deploy time.

This document is the open spec. Ordnance is the reference implementation, but
the format is deliberately manager-neutral and the apply pipeline is small
enough to port. Reference code is linked at the bottom.

## Why it exists

Three problems every traditional stat mod has:

1. **Conflicts.** A file-swap mod replaces a whole generated_*.dl_bin.
   Two mods that touch the same table can't coexist.
2. **Update rot.** A file-swap mod bakes in the bytes of one game version, so
   a patch breaks it until the author re-publishes.
3. **Size.** A file-swap mod is tens of megabytes for a handful of changed
   fields.

A stat-plan is a few hundred bytes. Because edits are applied onto the game's
*current* files at deploy time, stat-plans survive updates. Because edits are
field-level, multiple mods can edit the same table — a manager merges them,
and a later edit wins on the same field.

## The file

A mod that ships stat edits contains stat-plan.json at the archive root. It
is a JSON array of edit objects:

~~~json
[
  {
    "file": "generated_entities.dl_bin",
    "type": "0x88E4DBB1",
    "lo": "0x6f6d4203",
    "hi": "0xa955c4ea",
    "buckets": 746,
    "stride": 1240,
    "offset": 356,
    "kind": "f32",
    "op": "set",
    "value": 45.0
  }
]
~~~

## Edit object fields

| Field | Required | Meaning |
|-------|----------|---------|
| file | always | Bare generated_*.dl_bin filename. No paths, no "..". |
| type | always | The section type id, as a 0x-prefixed hex string. |
| op | always | set, mul, add, or clone. |
| lo / hi | keyed tables only | The two 32-bit words of the record's key hash. |
| buckets | keyed tables only | Hash bucket count. |
| stride | always | Record size in bytes. |
| record | row tables only | The record's id, 0x hex or integer. |
| section | no | Which copy of `type` to edit, starting at 0. Row tables only. Omit it for the first copy. |
| offset | set/mul/add only | Byte offset within the record. |
| kind | set/mul/add only | u32 or f32. |
| value | set/mul/add only | The operand. A number, or for u32 set, a 0x hex string. |
| src / dst | clone only | Source and destination record ids. |
| option | no | The manifest option name this edit belongs to. When present, the edit applies only while that option is ticked. An edit with no option applies whenever the mod is enabled. |

### Addressing modes

There are three mutually exclusive shapes, distinguished by which fields are
present:

1. **Keyed (hashmap) table** — has lo and hi. The record is found by
   scanning buckets hash entries for the matching key pair, then indexing
   by stride.
2. **Row table** — has record but no lo. The record is found by id.
   A file can contain the same section type more than once. `section` picks
   which copy; the applier does not search the others.
3. **Clone** — has src and dst. Copies an entire record.

Every edit carries its own geometry. **The applier must not know any game
table.** A missing or wrong layout is a plan-author bug, and the applier
reports it as such rather than guessing.

## Operations

Reads are little-endian. Integer math clamps to 0..=u32::MAX; float math is
IEEE-754 single precision.

| Op | u32 | f32 |
|----|-----|-----|
| set | write value | write value |
| mul | round(read x value) | read x value |
| add | round(read + value) | read + value |

clone copies the source record (stride bytes) over the destination, then
preserves the destination's own pointer field so it stays a valid node.

Float edits are special: they are recorded so the hash-correction step knows
which bytes changed.

## The apply pipeline

This is the part a port needs. Four steps, in order:

1. **Unseal** each generated_*.dl_bin named by the plan.
2. **Apply** every edit to the plaintext, grouped by file.
3. **Fix the hash**, then **reseal**.
4. **Verify** by unsealing the output and re-checking the hash.

### Sealed box

The tables are sealed with libsodium crypto_box_seal. The keypair is
shipped inside the game itself and is the same value the entire HD2 modding
ecosystem uses — it is not a secret of any one manager:

- Recipient public key: 2dc9aa7c30e6eed5f7fd0e0e95c7287299b126f79520cc41de750982ee7ff50c
- Recipient secret key: a0296b81310b58f013d8a9b343a1c292008003dfd9ab15fcf351543048b49b64

The sealed format is the standard libsodium layout: a 32-byte ephemeral
public key followed by ciphertext. The nonce is
BLAKE2b-24(ephemeral_pk || recipient_pk).

### The hash

The game integrity-checks a MurmurHash64A-style hash over the plaintext.
Edits change it — float edits especially — so the applier must repair it
before resealing, or the game rejects the file. This is the subtle step; the
reference correct() function finds spare bytes in a section header and
tweaks them until the hash matches the original. Port this from the reference
implementation rather than re-deriving it.

### Merge model

A manager that supports multiple enabled stat-plans must:

1. Seed a **stock backup** from the game's current files on first deploy.
2. Merge all enabled plans in profile order; a later edit to the same
   (file, record, offset) wins.
3. Apply the merged plan to stock, not to already-modified files.

This is what makes re-deploys idempotent and makes stat-plans survive game
updates.

## Author-side table geometry

The mapping from a friendly table name to file/geometry lives with the mod
author, not the applier. See hd2-mods/tools/statplan_layout.py in the
companion repo, which converts legacy table plans into the self-describing
form. The known geometry (verified against the 2026-10-22 game build):

- Keyed (entity) tables by section type: 0x88E4DBB1 -> (746, 1240),
  0xFB8D88A3 -> (560, 160), 0x4F2CF417 -> (386, 32),
  0x66081072 -> (50, 136), 0x45171B68 -> (556, 616),
  0xB3915DE3 -> (1012, 22096).
- Row tables: projectile -> generated_projectile_settings.dl_bin
  (type 0xBD4042C2, stride 272), explosion ->
  generated_explosion_settings.dl_bin (type 0x2AEA2592, stride 152),
  damage -> generated_damage_settings.dl_bin (type 0xE0A72CF0,
  stride 76).

## Reference implementations

Both are complete and MIT-licensed; port whichever matches your stack:

- **Rust** (Ordnance's runtime): src-tauri/src/commands/hd2edit.rs
  (seal + murmur) and src-tauri/src/commands/stat_deploy.rs
  (the apply logic).
- **Python**: compiler/hd2edit.py and compiler/plan.py
  (author-side, applies a plan to a stock dir and reseals).

The Python plan.py is a useful oracle: python3 plan.py plan.json
--stock <dir> --out <dir> applies a plan against a stock directory and
round-trips the hash, which is a fast way to validate an implementation
against known-good output.
