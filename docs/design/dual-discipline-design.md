# Dual Discipline — Design Document (module-owned, design only, not activated)

Status: design complete, no code written yet. Both open questions from the prior
review pass are resolved (§8). Per the brief, this is written and reviewed now but
**not enabled in the first release**. Ownership: `mod-azeroth-vocations` (`av_*`
tables), not the Core Vocation Service. Core's only involvement is being *read*
through the existing `CoreVocationService` API — nothing here proposes a new Core
table or a new Core API method.

## 1. What this actually is

FFXI-style sub-class: a character keeps its active main class exactly as `SwitchClass`
already leaves it, and additionally designates one *other* class the character has a
saved profile for as a sub-class. The sub-class never becomes the active
`characters.class` — the character is still, structurally, whatever `SwitchClass` last
set it to. Dual Discipline only ever *adds* a bounded, level-scaled slice of a second
class's kit on top of that.

```text
effective sub-class level = min(floor(active-class level / 2), actual saved sub-class level)
```

Both terms on the right are already things the Core service can answer without any new
method: `player->GetLevel()` for the first, and `GetClassProfiles(characterGuid)` →
find the row where `classId == subJobClass` → `.level` for the second. Dual
Discipline reads Core's existing API; it does not need Core to expose anything new.

## 2. Why this can't just be "learn some spells from the other class"

Three problems have to be solved before a single sub-class spell is grantable, and the
brief calls out the third by name:

1. **Which spells are even candidates.** A class's full kit includes talents, forms,
   pets, presences, and class-quest rewards — all explicitly excluded for v1. What's
   left is the *baseline trainer-taught spellbook* only.
2. **Which rank of a candidate spell.** Spells rank up with level. The character's
   *real* level determines main-class spell ranks as normal; the sub-class grant must be
   evaluated against the *effective sub-class level* instead, which requires a rank
   lookup keyed on a level that isn't the character's actual level anywhere else in the
   engine.
3. **Resource cost.** A sub-class spell was designed assuming its own class's power bar.
   The wielding character has whatever power type its *active* class uses. This is the
   part the brief says must be explicitly solved before implementation, not deferred.

## 3. The spell compatibility catalog

Every class's baseline (non-talent, non-form, non-pet, non-quest-reward) spellbook
entry gets exactly one bucket, decided once, by hand, before Dual Discipline ships —
this is data curation work, not a runtime decision:

| Bucket | Definition | Resource handling |
|---|---|---|
| **native-compatible** | Spell's own resource type equals `ChrClassesEntry::powerType` for the sub-class class, *and* equals the main class's power type too (e.g., a Mana-main-class character granted a Mana-costing Priest heal as sub-class). | Used as-is, no cost conversion. Rare in practice — most cross-class pairs won't share a power type — but the cheapest case when it happens. |
| **custom-converted** | Spell's resource type differs from the main class's active power type. | Cost is remapped to the main class's *own* power type, expressed as a **percentage of max power** (not an absolute unit copy — a 1000-mana Fireball's cost doesn't mean anything as a raw number on a Rage bar, but "9% of your resource pool" means the same thing regardless of which pool it is). See §9 for why this is the field's actual unit. |
| **shared-resource** | Spell relies on a secondary meter the main class already generates natively (e.g., Combo Points, Runic Power) rather than the primary power bar. | Only offered as a sub-class candidate if the main class actually generates that specific secondary meter. If not, the spell is not a candidate for that main-class pairing at all — this bucket is evaluated per (mainClass, subClass, spell) triple, not per spell alone. |
| **excluded** | Anything requiring a resource or mechanic with no sane conversion (e.g., DK Runes, Hunter Focus/pet-happiness-adjacent mechanics), plus everything already excluded by category (talents, forms, pets, presences, stances, class quest rewards). | Never offered, in any pairing. |

This directly answers the brief's demand: mana/rage/energy conflicts are solved by
**converting cost to the main class's existing power type**, not by granting the
character a second power bar. This deliberately reuses a mechanism the engine already
has, rather than inventing one: `Unit::setPowerType()` (`Unit.cpp:7040`) is the exact
function shapeshift forms already call to swap a character's active power type
wholesale (`Player.cpp` ~10774-10788, `SpellAuraEffects.cpp` ~2090 for the aura-driven
case). Dual Discipline does not need a variant of that mechanism — a converted-cost
sub-class spell spends the character's one existing power bar, in its one existing power
type, the same way every other spell the character knows already does. No dual-bar UI,
no dual-bar tracking, no new `Unit` state.

## 4. Data model (`av_*`, module-owned)

```sql
-- One row per character; NULL subJobClass means no sub-class selected.
-- Deliberately NOT keyed by (characterGuid, class) the way av_core_class_profile
-- is -- a character has at most one sub-class selection at a time, it is not
-- itself a per-class profile.
CREATE TABLE `av_dual_discipline_selection` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `subJobClass` TINYINT UNSIGNED NULL,
  `updatedAt` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`characterGuid`)
) ENGINE=InnoDB;

-- The curated catalog from section 3. Hand-authored data, not generated at
-- runtime. One row per (class, spell) baseline spellbook entry that has been
-- reviewed at all; anything absent from this table is implicitly excluded
-- (fail-closed, not fail-open -- an unreviewed spell is never grantable).
CREATE TABLE `av_dual_discipline_spell_catalog` (
  `class` TINYINT UNSIGNED NOT NULL,
  `spell` INT UNSIGNED NOT NULL,
  `bucket` TINYINT UNSIGNED NOT NULL,      -- 0=native-compatible 1=custom-converted 2=shared-resource 3=excluded
  `requiredSecondaryResource` TINYINT UNSIGNED NULL,  -- only meaningful for bucket=2
  `convertedCost` TINYINT UNSIGNED NULL,    -- only meaningful for bucket=1; PERCENT
                                             -- of the main class's max power (0-100),
                                             -- not an absolute unit value -- see §9
  `minSubJobLevel` TINYINT UNSIGNED NOT NULL, -- the rank threshold this row represents
  PRIMARY KEY (`class`, `spell`)
) ENGINE=InnoDB;

-- Audit trail for sub-class selection changes, mirroring av_core_class_switch_log's
-- shape but module-owned since sub-class selection never touches Core's tables.
CREATE TABLE `av_dual_discipline_log` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `characterGuid` INT UNSIGNED NOT NULL,
  `subJobClass` TINYINT UNSIGNED NULL,
  `createdAt` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB;
```

Nothing here is `av_core_*`. Nothing here writes to `character_spell` at any point —
this is the important boundary. A granted sub-class spell is **not** learned into
`character_spell` the way a real spell is; see §5.

## 5. Where granted spells actually live (and why not `character_spell`)

If sub-class spells were inserted into `character_spell`, they would survive a later
`SwitchClass` archive/restore as if they were genuinely learned main-class spells,
corrupting the Core service's own invariant that `character_spell` reflects exactly
one class's real spellbook (`core-vocation-service-design.md` §1). That must not
happen — this module is explicitly forbidden from writing to Core-owned tables, and
this is a concrete case where it would be tempting to.

Resolved: sub-class grants are **not persisted as learned spells at all**. The engine
already has the exact mechanism this needs — `Player::addSpell(spellId, specMask,
updateActive, /*temporary=*/true)` marks the spell `PLAYERSPELL_TEMPORARY`. That state
sends the real "spell learned" packet (full native spellbook/cast behavior, not a
fake), but `Player::_SaveSpells()` explicitly skips `PLAYERSPELL_TEMPORARY` entries
(`PlayerStorage.cpp`, `// xinef: skip temporary spells`) — it is structurally
impossible for a temporary grant to reach `character_spell`, not a matter of this
module being careful to avoid it. Since `Player::_LoadSpells()` only ever reads from
`character_spell`, a temporary grant also doesn't survive to the next login on its
own — it has to be re-granted every time, which is exactly what the hook below does
anyway.

Hook point: `PlayerScript::OnPlayerLogin(Player* player)` — fires after
`LoadFromDB()` has already fully run, so this never touches live mid-session state,
same principle as `SwitchClass`'s forced relog, just without needing an actual logout
for something additive rather than a class-identity change. Implementation: read
`av_dual_discipline_selection` for this character; if no sub-class is set, return
immediately (the single cheap check that keeps this invisible to non-adopters, per
`core-vocation-service-design.md` §2a); otherwise recompute the effective grant list
(§6) and call `addSpell(..., temporary=true)` for each. Re-run the same computation
whenever `av_dual_discipline_selection` changes (§8's resolution: that change also
ends in the same relog `SwitchClass` uses, so in practice this only ever needs to run
at login — there is no live-session re-grant path to build).

## 6. Effective level lookup

At the point a sub-class grant list needs to be (re)computed:

1. `activeLevel := player->GetLevel()`
2. `subJobClass := av_dual_discipline_selection.subJobClass` (module table)
3. `savedSubLevel := GetClassProfiles(characterGuid)` → find `classId == subJobClass` → `.level` (Core API, read-only). If no such profile exists, the character has never played that class through the Core service — sub-class selection should be restricted to classes with `HasClassProfile(characterGuid, subJobClass) == true` at selection time, so this case shouldn't arise, but is handled as "0 spells granted" defensively if it does.
4. `effectiveSubLevel := min(floor(activeLevel / 2), savedSubLevel)`
5. Grant every `av_dual_discipline_spell_catalog` row where `class = subJobClass AND bucket != EXCLUDED AND minSubJobLevel <= effectiveSubLevel`, applying the bucket 3/4 rules from §3 for cost.

This recomputes cleanly on every main-class level-up and every sub-class reselection; there
is no stored "current effective level," it is always derived fresh from the two real
numbers in step 1 and 3.

## 7. Explicit non-goals (restated from the brief, not weakened)

No sub-class talents, glyphs, talent-granted passives, class quest rewards, pets, forms,
stances, or presences, in this design or any future revision of it without a separate
design review. The catalog in §3/§4 only ever covers baseline trainer spellbook
entries. This is not a technical limitation being worked around later — it is a scope
boundary.

## 8. Open questions — resolved

- **Sub-class selection guards**: adopted `SwitchClass`'s guard set (not dead, not in
  combat, not grouped, not on transport, not flying, not in an
  instance/battleground/arena, no unsafe trade/mail/auction state — `CanSwitchClass`'s
  actual checks, `core-vocation-service-design.md` §7.1). Selecting or changing a
  sub-class touches no Core table and no equipment, but a mid-combat resource-type
  change (main class's spell costs shift as soon as a converted-cost spell is granted)
  is exactly the kind of surprise the brief's "no live hot-swap" intent is guarding
  against elsewhere in this project. Consistency of player expectation wins over the
  fact that it's technically safe to allow anywhere. Concretely, this means a
  sub-class change also ends in the same `session->LogoutPlayer(false)` bounce to
  character select `SwitchClass` already uses (`WorldSession.cpp`'s
  `SMSG_LOGOUT_COMPLETE`) — not a separate mechanism, the *same* one. That is what
  actually makes this safe to build without any client-refresh code: the client
  rebuilds its entire UI (power bar, spellbook, action bars) from scratch on every
  login regardless of cause, so a sub-class change never needs to push spell-learn
  packets or fight stale UI state mid-session. No sub-class grant is ever visible to
  a still-connected client; it only ever appears freshly, on the login right after
  selection.
- **Catalog granularity**: stays `(class, spell)`, not `(mainClass, subClass, spell)` —
  made correct (not just simpler) by redefining `convertedCost` as a percentage of the
  main class's max power rather than an absolute unit value (§3, §4). "9% of your
  resource pool" is the same curation entry regardless of which pool the main class
  actually has, so one row per candidate spell covers every possible main-class
  pairing without re-keying. This was the blocker that made flat-number curation
  actually wrong, not just coarse — see §9 for the mechanism this enables.

## 9. Client-side display: the part an addon *can't* fix

The brief's "different power types" concern actually splits into two separate
problems, solved two different ways:

1. **Actual resource deduction** — solved already, by §3/§6: no second power bar is
   ever created; a converted-cost spell spends the main class's one existing power
   bar. Nothing further needed.
2. **What the client *displays* for that spell** — tooltip cost text and the
   cast-bar's resource check are both read by the client straight from its own copy of
   `Spell.dbc` (`PowerType` and cost fields) for whatever spell ID was cast. If a
   sub-class grant used the spell's *original* ID, the client would show the spell's
   native class's power type and raw cost — e.g. a Warrior granted a converted Fireball
   would see a tooltip claiming a Mana cost, on a character with no Mana bar at all.
   **This is not addon-fixable.** `GameTooltip` hooks are cosmetic text overlays; they
   cannot change what the native cast bar checks or displays, because that check
   happens client-side against `Spell.dbc`, not against anything Lua can intercept.

The fix is the same class of client modification already used for this project's
High Elf race work: **grant a cloned spell ID, never the original.** For every
`custom-converted` catalog entry, author one clone per power type actually in play
among the 9 supported classes — in 3.3.5a that's only **Mana, Rage, and Energy**
(Hunters still run on Mana pre-Cataclysm; Runic Power/Death Knight is excluded
entirely) — so at most 3 clone spells per catalog entry, not one per
(mainClass, subClass) pairing:

- Client side: a `Spell.dbc` patch entry per clone, with `PowerType` and the
  `convertedCost`-percentage-derived absolute cost baked in for that power type's
  typical pool size (same DBC-patching workflow already established this session).
- Server side: a matching `spell_dbc` row (AzerothCore's server-side spell data
  extension) so the server's own cost/effect handling agrees with what the client was
  told.
- Grant logic (§6 step 5) picks whichever clone matches the character's *current*
  main-class power type at the moment the grant list is (re)computed — main-class
  switches already force a relog (`core-vocation-service-design.md` §5 step 14), so
  "current power type" is stable for the whole session, no runtime reswap needed.

Net effect: tooltip, cast bar, everything the stock client shows is simply *correct*,
for every player, with no addon dependency for this specific problem.

## 10. The Class Spellbook: one tab per unlocked class

Given §9 closes the power-type display gap without an addon, the addon's real job is
showing things the stock UI has *no native concept of at all*. The organizing idea for
all of it, per the top-level brief: **the spellbook itself gains one tab per class the
character has unlocked** (Project Ascension's "more classes unlocked → more spellbook
tabs" pattern, adapted to this project's class-profile data instead of Ascension's own
loadout system). This is not a separate feature from Dual Discipline or Hero — it is
the shared presentation layer both are built on, and the reason it has to exist at all:
the stock Blizzard spellbook frame has a fixed, class-hardcoded tab set with no
supported way to inject an extra tab for a class the character isn't natively playing.
There is no "skip the addon" fallback for this specific piece the way there is for the
Class Master gossip flow (`classmaster-gameplay-design.md` §3a) — without the addon,
a player has no in-client way to see a second class's spells at all.

**What populates a tab**: `GetClassProfiles(characterGuid)` (already-public Core API)
gives one row per unlocked class. Each becomes a tab. The *active* main class's tab is
just the native spellbook — the addon doesn't need to reproduce it. Every other tab's
content is that class's baseline spellbook filtered through the same
`av_dual_discipline_spell_catalog` this document already defines (§3/§4): only
`native-compatible`/`custom-converted`/`shared-resource` entries at or below the
class's saved level ever appear, talents/forms/pets/quest rewards never do. One catalog
serves every consumer below — it is not re-curated per feature.

**How many tabs are actually live** (grant real, castable spells, per §6) is what
differs between the features that sit on top of this UI:

- **Base multi-class, no Dual Discipline or Hero active**: tabs for unlocked classes
  the character isn't sub-classed into are browse-only — informational (what you'd
  have if you switched or sub-classed into it), not castable. Only the active class's
  own tab is live, and that's just the native spellbook.
- **Dual Discipline**: exactly 2 live tabs — the active main class (native), and the
  one selected sub-class, filtered to `effectiveSubLevel` per §6. This document's
  existing scope; no change from §1-9 above.
- **Hero** (`classmaster-gameplay-design.md` §6.5): *every* unlocked class's tab is
  live simultaneously — the same catalog, the same clone-spell cost-conversion
  mechanism from §9, just with the "how many tabs get evaluated" number raised from 1
  (a sub-class) to *all 9*. This is what makes Hero tractable to actually build later:
  it reuses this catalog and this grant mechanism rather than needing its own. Hero
  does **not** get talents/forms/pets/quest rewards either — same non-goals as §7,
  same reason. "Use every resource type and wear every armor type" (the one-line
  description in `classmaster-gameplay-design.md` §6.5) means every *unlocked class's*
  baseline kit is live at once, not that every spell in the game becomes available.

Still genuinely undecided, and out of scope until spell catalog curation is underway:
exact frame layout, whether this ships as a standalone addon or part of an existing UI
mod, and the server-to-addon data channel (likely AIO or a lightweight addon-message
protocol carrying the same data `/av classes`/`/av armory` and the catalog already
compute — no new Core or module read API needed, this is a presentation layer over
data that already exists). Also still open, deferred to when Hero is actually designed
in full: whether Hero's armor-type unlock (wearing every class's gear) reuses the
Class Armory's existing per-slot validity check (`core-vocation-service-design.md`
§4.4) or needs its own rule — flagging it here only so this section doesn't quietly
assume an answer.
