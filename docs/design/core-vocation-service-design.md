# Core Vocation Service — Design Document

Status: proposed, not implemented. No `av_core_*` table, no C++ service class, and no
core patch described here exists yet. This document is the "deliver before
implementation" gate from the project brief. Both workstreams (Core Vocation Service,
`mod-azeroth-vocations`) must agree on it before any code is written.

## 1. Why this is harder than a normal module

Verified directly against the live AzerothCore schema (`data/sql/base/db_characters/`),
not assumed:

| Table | Key | Consequence |
|---|---|---|
| `characters` | `guid` | `class`, `level`, `xp` are single columns. There is exactly one class per character, forever, by construction. |
| `character_spell` | `(guid, spell)` | Flat per-character. `specMask` exists for *dual spec*, not per-class. |
| `character_talent` | `(guid, spell)` | Same shape as `character_spell`. |
| `character_glyphs` | `(guid, talentGroup)` | `talentGroup` is the dual-spec slot (0/1), not a class. |
| `character_action` | `(guid, spec, button)` | `spec` is the dual-spec slot, not a class. |
| `character_inventory` | `item` (PK) → `(guid, bag, slot)` | Maps an `item_instance.guid` to a position. Deleting this row does **not** delete the item; it just un-places it. |
| `item_instance` | `guid` (PK) | Full instance data (enchants, gems-in-`enchantments`, durability, `randomPropertyId`, flags, text). Nothing here references class or "class". |

None of these tables have a concept of "the character's other class's spellbook." Stock
AzerothCore never needs one. That is the entire problem Class Profile persistence exists
to solve: every switch must *archive* the outgoing class's rows out of these live tables
and *restore* the incoming class's previously-archived rows back in, atomically, or the
character ends up with (for example) a Warrior's `characters.class` but a Mage's
leftover `character_spell` rows.

This is also why the brief is strict about "no live in-world class hot-swapping yet" and
"clean return to character select/relog": `Player` is a live, heavily-cached, replicated
object once a character is in the world (aura state, combat state, group state, cached
stat totals derived from equipped items and talents). Swapping the underlying class
identity of a *loaded* `Player` object is a much larger, much riskier problem than
swapping DB rows for an *offline* character and reloading normally. Restricting v1 to
"switch happens while logged out or at character select, then the client reloads the
character fresh" means `Player::LoadFromDB()` — code that already knows how to build a
consistent Player from `characters` + the child tables — does the "apply" side of the
switch for free. No `Player` internals need to change at all.

## 2. Ownership boundary (restated for the record)

- **Core Vocation Service** owns: `av_core_*` tables, the C++ service class, and the
  *minimal* core changes listed in §6. It never runs trainer gossip, unlock rules, or
  gameplay logic.
- **`mod-azeroth-vocations`** owns: `av_*` gameplay tables (trainer allowlist, cost,
  cooldown, unlock state, Hero/Dual-Discipline design placeholders), gossip/commands,
  config. It never writes to `characters`, `character_spell`, `character_talent`,
  `character_glyphs`, `character_action`, `character_inventory`, or `item_instance`
  directly, and never writes to `av_core_*`. It calls the service.
- Neither workstream touches the other's tables. The only crossing point is the C++
  API in §5.

## 2a. Backward compatibility with unmodified vanilla classes (explicit invariant)

This is not a side effect of the design, it is a requirement the schema and sequence
are built around: **a character that never calls `SwitchClass` must be indistinguishable
from a character on a server with no Vocations module installed at all.**

Concretely:

- Every `av_core_*` table is additive-only. None of them add a column to `characters`,
  `character_spell`, `character_talent`, `character_glyphs`, `character_action`,
  `character_inventory`, or `item_instance`. A character with zero `av_core_*` rows
  (i.e. one who has never visited a Class Master) has literally nothing for the service to
  have touched.
- `GetClassProfiles(characterGuid)` returns an empty vector for such a character.
  `HasClassProfile` returns false for every class, including their own current one — a
  character's *original* class is not implicitly "class profile #1"; it only becomes a
  tracked profile the first time `SwitchClass` archives it, which only happens on that
  character's first-ever switch. Until then, there is no `av_core_class_profile` row at
  all for them, matching a genuinely unmodified vanilla character exactly.
- No hook this service adds may run unconditional logic against every login/save for
  every player. Per §6, the honest current answer is that zero core hooks are needed;
  *if* prototyping surfaces a genuine need for one (the "TBD" row in §6's table), it
  must open with an immediate no-op check (`if (!HasClassProfile-equivalent) return;`)
  before doing anything else, and that check itself must be a single indexed lookup
  keyed on `characterGuid` against an empty result set for non-adopters — not a
  cross-table join, not something whose cost scales with anything except "does this
  specific character have any Vocations history."
- `characters.class` is written by `SwitchClass` and by nothing else this project adds.
  A character who never switches never has this column touched by anything outside
  normal AzerothCore character creation. There is no migration, backfill, or "default
  profile" write-on-login that touches an existing character's row.
- Disabling the service (the brief's required config kill switch) or uninstalling the
  module entirely leaves every character exactly as described in §9 (Rollback plan):
  whichever class was active continues to function as an ordinary single-class
  character, because that class's data already *is* the live core data, not a copy of
  it.

This is what makes "of course it doesn't screw with current vanilla classes" true by
construction rather than by discipline: there is no code path in this design that a
non-adopting character's data can be reached by at all.

## 3. `av_core_*` schema proposal

All in the **characters** database (class state is per-character).

```sql
-- One row per (character, class) the character has ever had a profile for.
-- The row for the character's CURRENT class always mirrors `characters` at the
-- moment of last save; it is not a live cache, it is the last-known-good snapshot
-- for that class, refreshed every time that class becomes inactive again.
CREATE TABLE `av_core_class_profile` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `level` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  `xp` INT UNSIGNED NOT NULL DEFAULT 0,
  `isActive` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `createdAt` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updatedAt` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`characterGuid`, `class`),
  KEY `idx_active` (`characterGuid`, `isActive`)
) ENGINE=InnoDB;
-- Invariant: at most one row per characterGuid has isActive = 1, and it always
-- matches characters.class/level/xp for that guid. Enforced in the service layer
-- (see 4.5), not by a DB constraint MySQL can't express across two tables.

-- Archived spellbook for an inactive class. Same shape as character_spell.
CREATE TABLE `av_core_class_spell` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `spell` INT UNSIGNED NOT NULL,
  `specMask` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (`characterGuid`, `class`, `spell`)
) ENGINE=InnoDB;

-- Archived talents for an inactive class. Same shape as character_talent.
CREATE TABLE `av_core_class_talent` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `spell` INT UNSIGNED NOT NULL,
  `specMask` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`characterGuid`, `class`, `spell`)
) ENGINE=InnoDB;

-- Archived glyphs for an inactive class. Same shape as character_glyphs.
CREATE TABLE `av_core_class_glyph` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `talentGroup` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `glyph1` SMALLINT UNSIGNED DEFAULT 0,
  `glyph2` SMALLINT UNSIGNED DEFAULT 0,
  `glyph3` SMALLINT UNSIGNED DEFAULT 0,
  `glyph4` SMALLINT UNSIGNED DEFAULT 0,
  `glyph5` SMALLINT UNSIGNED DEFAULT 0,
  `glyph6` SMALLINT UNSIGNED DEFAULT 0,
  PRIMARY KEY (`characterGuid`, `class`, `talentGroup`)
) ENGINE=InnoDB;

-- Archived action bars for an inactive class. Same shape as character_action.
CREATE TABLE `av_core_class_action` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `spec` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `button` TINYINT UNSIGNED NOT NULL,
  `action` INT UNSIGNED NOT NULL DEFAULT 0,
  `type` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`characterGuid`, `class`, `spec`, `button`)
) ENGINE=InnoDB;

-- Class Armory: which item_instance rows belong to which inactive class's equipped
-- set, and which equipment slot they came out of. The item_instance row itself
-- is never touched -- this table only records "this item currently has no
-- character_inventory row because it's parked for class X."
CREATE TABLE `av_core_class_armory_item` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `equipSlot` TINYINT UNSIGNED NOT NULL,        -- EQUIPMENT_SLOT_START..END-1 (0-18)
  `itemGuid` INT UNSIGNED NOT NULL,             -- item_instance.guid
  `storedAt` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`characterGuid`, `class`, `equipSlot`),
  UNIQUE KEY `idx_item` (`itemGuid`)            -- an item can be parked in exactly one place
) ENGINE=InnoDB;

-- Audit log. Append-only, never updated in place.
CREATE TABLE `av_core_class_switch_log` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `characterGuid` INT UNSIGNED NOT NULL,
  `fromClass` TINYINT UNSIGNED NOT NULL,
  `toClass` TINYINT UNSIGNED NOT NULL,
  `result` TINYINT UNSIGNED NOT NULL,           -- mirrors ClassSwitchResult enum, see 5.2
  `reason` VARCHAR(255) NULL,
  `initiatedBy` VARCHAR(64) NOT NULL,            -- 'player' or GM account name
  `createdAt` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_char` (`characterGuid`, `createdAt`)
) ENGINE=InnoDB;
```

Migration order: `av_core_class_profile` first (no dependents), then the four archive
tables and `av_core_class_armory_item` (any order, no FKs between them by design — cross
DB-engine FK enforcement across a module boundary is exactly the kind of coupling this
project is trying to avoid), then `av_core_class_switch_log` last. No table references
`characters` with an actual FOREIGN KEY, deliberately: a character delete is core's
business, and `av_core_*` cleanup on character delete is a service-layer responsibility
(§7), not a DB cascade that could silently interact with core's own delete path.

## 4. Class Armory safety model

### 4.1 Core invariant

An `item_instance` row is **never** copied and **never** deleted by this service. At all
times, an item is in exactly one of two states:
1. **Placed**: it has a `character_inventory` row (equipped, bagged, or banked).
2. **Parked**: it has an `av_core_class_armory_item` row and *no* `character_inventory`
   row.

An item is never in both, and never in neither (barring the brief window inside an
open, uncommitted transaction). The `UNIQUE KEY idx_item` on
`av_core_class_armory_item.itemGuid` plus `character_inventory.item` being a primary key
make "parked twice" and "placed twice" both structurally impossible to write
simultaneously without a constraint violation.

### 4.2 Parking (class going inactive)

For each of the outgoing class's 19 equipment slots (`EQUIPMENT_SLOT_START..END-1`,
confirmed in `Player.h`) that has an item:

1. Read the `character_inventory` row for `(guid=characterGuid, bag=INVENTORY_SLOT_BAG_0, slot=equipSlot)` → get `item` (the `item_instance.guid`).
2. `DELETE` that `character_inventory` row (un-places it; `item_instance` untouched).
3. `INSERT` into `av_core_class_armory_item (characterGuid, class, equipSlot, itemGuid)`.

Non-equipped items (bags, bank) are **not** touched. Only the 19 equipment slots are
class-specific; everything else is character-wide per the brief.

### 4.3 Restoring (class going active)

For each `av_core_class_armory_item` row matching `(characterGuid, class=targetClass)`:

1. Validate the item can still be equipped in that slot for the target class *right
   now* (see 4.4 — this can legitimately fail, e.g. a two-hander parked while the
   character was still that class, if some other change since then made it invalid).
2. If valid: `INSERT` a `character_inventory` row at `(bag=INVENTORY_SLOT_BAG_0, slot=equipSlot)`, then `DELETE` the `av_core_class_armory_item` row.
3. If invalid: leave the `av_core_class_armory_item` row exactly as it is. The item stays
   parked. `GetArmorySummary()` will show it as "held, not restored" so the player and
   any GM tooling can see it wasn't silently lost — it's exactly where it was, just not
   re-equipped.

This is the "incoming gear is restored only where valid; otherwise remains in the
Armory" requirement from the brief, satisfied structurally: failure to restore is not a
special case, it's just "don't do step 2." Nothing is ever destroyed on a failed
restore.

### 4.4 Validity checks

- `ItemTemplate::AllowableClass` bitmask includes the target class.
- Slot compatibility (`InventoryType` vs. the equip slot) still holds.
- Item is not currently referenced by a pending trade, mail, or auction (checked via
  existing item state flags — the service reads these, never sets them).

### 4.5 Inventory loader interaction — the important safety property

`Player::_LoadInventory()` (core, unmodified) builds the player's inventory purely
from `character_inventory` join `item_instance`. Because a parked item has **no**
`character_inventory` row, the stock loader already skips it automatically. **The Class
Armory needs zero changes to the inventory loader.** This is why the brief's "minimal
core modifications" instruction is achievable: the parking mechanism was chosen
specifically so the exclusion is a natural consequence of the existing schema, not a
new filter that has to be kept in sync with core's own loading logic forever.

The only way this property breaks is if something *other* than this service ever
writes a `character_inventory` row for a parked item's guid without going through
`SwitchClass`'s own restore step (§5 step 9). That is a real risk surface (any future
module or core change that does raw inventory manipulation by item guid) and is
exactly why `idx_item` is a `UNIQUE KEY`: such a write would fail loudly (constraint
violation) rather than silently duplicate the item into two places.

### 4.6 Starting equipment for a brand-new class

`CreateLevelOneClassProfile` doesn't just seed spells and action bars — it also seeds
the Armory itself, the first time a class is ever created, so switching into a class
you've never played isn't naked. The source is the exact same one real character
creation uses: `CharStartOutfitEntry` (`CharStartOutfit.dbc`, looked up by
race+class+gender via the existing `GetCharStartOutfitEntry()`), mirroring the "attempt
equip" half of `Player::StoreNewItemInBestSlots` — but writing directly into
`av_core_class_armory_item` via `Item::CreateItem()` + `Item::SaveToDB(trans)` in the
same transaction, rather than onto a live `Player`, since the class being created isn't
active yet (and couldn't pass the live object's own class-restricted equip checks
even if it were — the character is still whatever class it's switching *from* at this
point in the sequence).

Only outfit entries that resolve to one of the 19 equipment slots are kept (mapped by
`InventoryType`, a small switch deliberately simpler than `Player::FindEquipSlot` —
there is nothing else equipped yet for this brand-new class, so there's no
swap/dual-wield/Titan Grip conflict to resolve, just one obvious slot per type).
Non-equipment outfit rows (starting reagents, food, a hearthstone, etc.) are skipped
entirely and never touch `av_core_class_armory_item` — per §4.2, the Armory is
equipment-slots only; bags and consumables are character-wide, not class-specific, and
stay exactly where they already are.

These items reach the player through the exact same path as any other class's parked
gear: `SwitchClass`'s step 9 restore, immediately after `CreateLevelOneClassProfile`
runs within the same `SwitchClass` call (§5 step 7). There is no separate "first login
as this class" code path — a class's first switch and its hundredth switch both end at
the same restore step, reading whatever `av_core_class_armory_item` currently holds for
it.

## 4a. Per-class residual state — pets and auras

Spells, talents, glyphs, action bars, and equipped gear are the state the brief
explicitly calls out. Two more class-coupled tables exist in core that the brief
doesn't mention, and each needed checking against the real loader code rather than
assumed safe by analogy — they turned out to need opposite treatment.

**Pets — confirmed safe, no `av_core_*` table needed.** `Player::LoadFromDB()`
(`Player.cpp` ~line 1262) already gates pet-loading behind the *freshly loaded*
`characters.class`:

```cpp
if (result && !(playerFlags & PLAYER_FLAGS_GHOST) &&
    (plrClass == CLASS_WARLOCK || plrClass == CLASS_HUNTER ||
     (plrClass == CLASS_DEATH_KNIGHT && ...)))
```

This check exists in core for reasons that have nothing to do with Vocations —
Blizzard's own data model ties permanent pets to specific classes. The consequence for
us: once `SwitchClass` updates `characters.class`, a Hunter's stabled/current pet row in
`character_pet` is simply never loaded again for as long as the character isn't a
pet-having class — not deleted, not touched, just skipped by a check core already had.
If the character switches back to Hunter later, the exact same row (same `id`, same
saved level/exp/name/`abdata`) loads again unchanged. This is the same "dormant, not
duplicated, not destroyed" property as the Armory, achieved for free by an unrelated
pre-existing core gate. No archive table, no restore step, nothing to add here.

**Auras — a real gap, now closed.** `Player::_LoadAuras()`
(`PlayerStorage.cpp:5818`) validates only that the saved `spellid` still resolves to a
`SpellInfo` *at all* — it never checks whether the character's current class can hold
that spell. A Druid saved mid-Bear-Form, switched to Mage via `SwitchClass`, would have
this loader attempt to reapply a shapeshift aura to a class that cannot shapeshift on
the very next login. Unlike spells/talents/glyphs/gear, auras are not meant to survive
a class switch as "saved class identity" in the first place — a temporary buff, DoT, or
shapeshift form isn't part of what makes a class profile a class profile, and the
brief's own "no live hot-swap, force relog" requirement already establishes that a
switch is allowed to be a hard boundary. So the fix is not another archive table, it's
one more statement in the same transaction as the existing archive step (§5 step 5):

```sql
DELETE FROM character_aura WHERE guid = ?  -- characterGuid, run once per SwitchClass
```

This runs unconditionally on every switch, not just for shapeshift-form auras
specifically — trying to enumerate "which auras are class-unsafe" is a much larger and
more fragile validation surface than "none of them carry over," and a full relog
already resets a huge amount of other transient state (combat, aggro, movement) that
players already expect to reset on this kind of action.

## 5. Transaction sequence: `SwitchClass`

Single `CharacterDatabaseTransaction`. Preconditions (§7) are checked *before* opening
the transaction, so the transaction itself only ever fails on genuine DB-layer problems,
not on business rules — business-rule rejection should never need a rollback because it
never starts a write.

```text
SwitchClass(player, targetClass):
    1.  Guard checks (in-memory, no DB writes) -- see 7.1. Any failure returns
        immediately with a specific ClassSwitchResult, no transaction opened.
    2.  BEGIN TRANSACTION
    3.  currentClass := player.class
    4.  UPSERT av_core_class_profile (characterGuid, currentClass,
            level=player.level, xp=player.xp, isActive=0)
    5.  ARCHIVE currentClass:
            character_spell   -> av_core_class_spell   (copy, then delete from character_spell)
            character_talent  -> av_core_class_talent   (copy, then delete)
            character_glyphs  -> av_core_class_glyph    (copy, then delete)
            character_action  -> av_core_class_action    (copy, then delete)
            character_aura    -> DELETE only, no archive table (per 4a --
                                  auras are not restored on switch-back)
    6.  PARK currentClass equipment -> av_core_class_armory_item (per 4.2)
    7.  IF NOT HasClassProfile(characterGuid, targetClass):
            CreateLevelOneClassProfile writes the target's av_core_class_* rows
            in-transaction (a fresh level-1 spellbook/talents for that class),
            marks av_core_class_profile(targetClass).isActive = 0 for now
        ELSE:
            target rows already exist from a previous archive; use them as-is
    8.  RESTORE targetClass:
            av_core_class_spell   -> character_spell   (copy, then delete archived rows)
            av_core_class_talent  -> character_talent   (copy, then delete)
            av_core_class_glyph   -> character_glyphs    (copy, then delete)
            av_core_class_action  -> character_action    (copy, then delete)
    9.  RESTORE targetClass equipment from av_core_class_armory_item (per 4.3;
        per-item validity failures do not abort the transaction, they just
        leave that one item parked)
    10. UPDATE characters SET class=targetClass,
            level=av_core_class_profile(targetClass).level,
            xp=av_core_class_profile(targetClass).xp
        WHERE guid=characterGuid
    11. UPDATE av_core_class_profile SET isActive=0 WHERE characterGuid=characterGuid
        UPDATE av_core_class_profile SET isActive=1 WHERE characterGuid=characterGuid
            AND class=targetClass
    12. INSERT av_core_class_switch_log (result=SUCCESS, ...)
    13. COMMIT
    14. Force logout / require relog (brief requirement: no live hot-swap).
        Player object is not mutated in memory at all -- next login runs
        Player::LoadFromDB() fresh against the now-updated tables.

    ON ANY STEP 2-13 FAILURE:
        ROLLBACK (steps 4-11 undo as a unit; characters row was never committed
        with the new class if step 10 didn't complete)
        INSERT av_core_class_switch_log (result=<specific failure>, ...)  -- outside
            the rolled-back transaction, in its own auto-commit statement, so a
            failed switch is still auditable
        Return specific ClassSwitchResult to caller
```

Because the `Player` object in memory is never mutated mid-switch (step 14), there is
no "half-switched live object" state to worry about — the live `Player` keeps behaving
as the *old* class until the transaction commits and the character reloads. If the
transaction rolls back, the live `Player` never knew anything was attempted.

## 5a. `SwitchClassLive`: the same transaction, no forced relog

Status: designed, not yet built or tested. Scoped specifically to the main class
switch — Dual Discipline keeps its own relog-based approach (`dual-discipline-design.md`
§8) unchanged; nothing here replaces that.

Steps 1-13 above are **identical** — same guards, same transaction, same DB rows
written. `SwitchClassLive` only replaces step 14 (force logout) with live in-place
application on the already-connected `Player`, once the transaction has committed.
This is not a new invention: every individual piece already exists in this codebase,
proven and shipping, for the closely analogous dual-spec switch
(`Player::ActivateSpec`, `Player.cpp:15486`) and for normal leveling
(`Player::GiveLevel`, `Player.cpp:2480`):

```text
14 (live). After COMMIT, on the connected Player:
    a. Interrupt any non-melee cast in progress; dismiss pet/totems/summons
       (RemovePet, ClearAllReactives, UnsummonAllTotems, RemoveAllControlled) --
       exact pattern ActivateSpec already uses before it touches anything else.
    b. SendActionButtons(2) -- tell the client to clear its action bars, same
       call ActivateSpec makes.
    c. Unconditionally remove all auras (per 4a, auras never survive a switch
       either way).
    d. Unlearn every currentClass spell from m_spells (removeSpell per entry,
       real unlearn packets via the same path ActivateSpec's spell-diff loop
       uses) and unequip every equipped item (RemoveItem per slot -- the DB
       side is already parked by step 6/9's transaction, this is the live
       in-memory/visual side of the same fact).
    e. SetByteValue the class field to targetClass (plain field write, same
       replication every other UpdateField change already uses -- no
       dedicated "SetClass" helper exists in core today, this would be the
       first caller, but the mechanism itself is generic and unremarkable).
    f. SetPowerType(new class's power type) -- exact mechanism Druid
       shapeshifting already uses live, Unit.cpp:7040.
    g. GiveLevel(targetProfile.level) -- reads getClass() live (already
       updated by step e), so it naturally recalculates health/power/stats
       for the *new* class the same way every normal level-up already does.
       Needs verification at implementation time: whether GiveLevel resets XP
       as a side effect the way a normal level-up would, in which case
       targetProfile.xp must be re-applied explicitly right after.
    h. Relearn every targetClass spell (from the character_spell rows step 8
       just restored) via addSpell(..., temporary=false) -- these are real,
       permanent spellbook entries now, not a Dual Discipline-style overlay.
       Reapply talents and glyphs the same way, mirroring ActivateSpec's
       talent/glyph loops.
    i. Re-equip every valid restored item from av_core_class_armory_item (per
       4.3's validity check, unchanged) via EquipItem per slot.
    j. Reload and resend action bars: same async DB read + SendActionButtons(1)
       pattern as ActivateSpec's LoadActions.
    k. INSERT av_core_class_switch_log (result=SUCCESS, ...) -- same as today,
       "force relog" framing just no longer applies.
```

Every piece on the right has a real precedent already running in production:

| Step | Reused from |
|---|---|
| Spell unlearn/relearn, client packets | `addSpell`/`removeSpell`, used live by `ActivateSpec` |
| Action bar clear + reload + resend | `SendActionButtons(2)` → reload → `SendActionButtons(1)`, `ActivateSpec` |
| Power type change | `SetPowerType()`, Druid shapeshifting |
| Stat/level recalc for the new class | `GiveLevel()`, every normal level-up |
| Class byte | plain `SetByteValue`, same replication as any other field |
| Equipment swap | `EquipItem`/`RemoveItem`, normal functions, new orchestration only |

Genuinely new relative to `ActivateSpec` (which never changes class, level, or
equipment): the class-byte write, the level jump, and the equipment swap. None of
these are unprecedented *mechanisms* — they're normal single-purpose functions this
project would be composing for the first time in this specific sequence, not new
client protocol or new engine capability.

**Given none of this has been tested yet** (a fair concern raised directly, not
hypothetical), this ships behind its own kill switch —
`AzerothVocations.Core.LiveSwitchEnabled` (default off) — independent of
`AzerothVocations.Core.Enable`. With it off, `SwitchClass` behaves exactly as §5
describes today (steps 1-13, then forced relog). With it on, step 14 runs the live
sequence above instead. A server owner (or this project, during its own testing
phase) can revert to the proven relog path at any time with zero code change, without
needing the DB schema or transaction logic to know or care which mode is active —
steps 1-13 are identical either way.

## 6. Minimal core changes — exact files and justification

The goal stated in the brief is *minimal*. Based on the schema and sequence above, here
is what actually requires touching AzerothCore itself, and — more importantly — what
does **not**:

| Change | File | Justification |
|---|---|---|
| **None required for inventory loading.** | — | Per §4.5, parking naturally excludes items from `_LoadInventory()`. No core change. |
| **None required for spell/talent/action/glyph loading.** | — | `Player::LoadFromDB()` already reads `character_spell`/`character_talent`/`character_glyphs`/`character_action` fresh on every login; once `SwitchClass` has restored the target class's rows into those tables, the existing loader picks them up with zero changes. |
| **None required for `characters.class`.** | — | It's a normal column; a normal `UPDATE` changes it. Every system that reads `player->getClass()` already re-derives correctly from the reloaded `Player`. |
| Possibly: a `PlayerScript::OnLogin` or `OnBeforeLoadPetFromDB`-style hook, *if* any edge case is found where core code caches something keyed by class before `LoadFromDB` fully runs. | TBD, pending prototype testing | Not yet confirmed necessary. To be validated in the test matrix (§8) before assuming it's needed — the honest answer right now is "probably zero core changes," not "definitely zero." |

This is a materially smaller "core modification" footprint than the brief's framing
implied might be needed, because the archive/restore design deliberately reuses
existing AzerothCore tables and loaders as the "apply" mechanism instead of inventing a
parallel loading path. The only genuinely new core-adjacent code is the service class
itself (module-owned, not a core patch) and its transaction logic.

## 7. Guards, failure enum, and recovery

### 7.1 Pre-transaction guards (`CanSwitchClass`)

Checked in-memory against the live `Player*`, before any DB write:

- Player is alive (not dead/ghost).
- Not in combat.
- Not grouped (v1 restriction; revisit later, not in scope now).
- Not on a transport.
- Not flying (mounted-flying or `MOVEMENTFLAG_FLYING`).
- Not in an instance, battleground, or arena.
- No pending trade window, mail send, or auction listing referencing this
  character's items (protects the Armory invariant in §4.1).
- Death Knight is excluded unless explicitly config-enabled (brief requirement,
  default off, checked here so the module never has to duplicate the rule).
- Core service itself is not config-disabled (kill switch, checked first).

### 7.2 `ClassSwitchResult` enum (proposed)

```cpp
enum class ClassSwitchResult : uint8
{
    SUCCESS = 0,
    ERR_SERVICE_DISABLED,
    ERR_TARGET_CLASS_DISABLED,          // e.g. Death Knight, config-gated
    ERR_PLAYER_DEAD,
    ERR_PLAYER_IN_COMBAT,
    ERR_PLAYER_GROUPED,
    ERR_PLAYER_ON_TRANSPORT,
    ERR_PLAYER_FLYING,
    ERR_PLAYER_IN_INSTANCE,
    ERR_UNSAFE_INVENTORY_STATE,         // open trade/mail/auction touching this char
    ERR_TARGET_PROFILE_CREATE_FAILED,
    ERR_DB_TRANSACTION_FAILED,          // genuine DB-layer failure, rolled back
    ERR_ALREADY_ACTIVE_CLASS,           // target == current, no-op guard
};
```

Every value maps to a row in `av_core_class_switch_log.result` and to a specific,
player-facing message owned by `mod-azeroth-vocations` (the Core service returns the
enum; the module owns the string).

### 7.3 GM inspection / recovery

`Inspect/RecoverClassProfile(admin, characterGuid, class)` is read/repair-only:
- Inspect: dump the `av_core_class_profile` row, archived spell/talent/glyph/action row
  counts, and `av_core_class_armory_item` contents for that (character, class) pair — this
  is the primary tool for diagnosing "why didn't my gear come back" without touching
  live data.
- Recover: for a character stuck mid-failure (should not happen given §5's
  transactional design, but the brief explicitly asks for this as a safety net), re-run
  the archive/restore steps idempotently against whatever state currently exists,
  logging every step. Never guesses; only acts on rows it can already see.

### 7.4 Character delete

Deleting a character deletes its `av_core_*` rows too — but as an explicit service-side
cleanup step (triggered off the same hook core already fires for character deletion),
not a SQL `ON DELETE CASCADE`, per §3's reasoning about not coupling to core's delete
path with a real foreign key.

## 8. Test plan (outline — full matrix is a `mod-azeroth-vocations` deliverable)

Core-service-specific cases that must pass before the module is allowed to call this
service in anger:

1. Fresh character, first switch to a never-before-played class → level-1 profile
   created, archive of original class is byte-for-byte re-derivable from
   `av_core_class_*` after the switch. The new class's Class Armory is seeded from
   `CharStartOutfitEntry` (§4.6) — verify every seeded item resolves to a real
   equipment slot and none are duplicated across two characters (`idx_item` unique
   constraint).
2. Switch back to a previously-played class → exact spell/talent/glyph/action
   restoration, verified row-for-row against what was archived.
3. Equip an item, switch away, switch back → item re-equipped in the same slot,
   `item_instance.guid` unchanged (same row, not a new one).
4. Equip an item, switch away, then (simulating drift) make that item invalid for the
   class (e.g. via a hypothetical future item change) → switch back leaves the item
   parked, not equipped, not deleted; `GetArmorySummary` reports it.
5. Force a failure mid-transaction (kill the DB connection between steps 6 and 8 in a
   test harness) → `characters.class` is unchanged, no partial archive/restore rows
   exist, log records the failure.
6. Attempt switch while in combat/grouped/flying/instanced/dead → rejected before any
   DB write, correct enum returned, no log spam beyond the single rejection entry.
7. Two concurrent switch attempts for the same character (should be structurally
   impossible if a character can only have one active session, but test it anyway) →
   second attempt rejected, not merged/raced.
7a. Druid character self-casts a shapeshift form, logs out while still shapeshifted,
    switches to a non-shapeshifting class, logs back in → character loads with no
    aura at all (not the shapeshift, not any other pre-switch buff/debuff);
    `character_aura` has zero rows for that guid immediately after the switch
    transaction commits, before the character even logs back in.
7b. Hunter with an active current pet (slot 0) and one stabled pet, switches to Mage,
    logs in → no pet summoned, no error; `character_pet` rows for both are untouched
    (same `id`, `level`, `exp`, `name`). Switches back to Hunter → both pets load
    exactly as they were, unaffected by the intervening Mage session.
8. Character delete → all `av_core_*` rows for that guid are gone; no orphaned Armory
   items.

## 9. Rollback plan

- Every `av_core_*` migration is additive (`CREATE TABLE IF NOT EXISTS`); dropping the
  whole `mod-azeroth-vocations` + Core service module and its tables leaves
  `characters`/`character_spell`/`character_talent`/`character_glyphs`/
  `character_action`/`character_inventory`/`item_instance` exactly as core defines
  them, because nothing in this design ever adds a column to those tables.
- If a character is mid-adoption (has ever switched at least once), disabling the
  service leaves them frozen on whichever class was active at disable time — that
  class's rows are already the live core rows, so the character continues to function
  as a normal, single-class AzerothCore character with no special handling required.
  Any *other* class's archived data sits inert in `av_core_*` until the service is
  re-enabled or the tables are dropped.
