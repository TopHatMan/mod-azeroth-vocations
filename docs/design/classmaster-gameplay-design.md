# Class Master Gameplay — Design Document

Status: proposed, §1-5 implemented. Module-owned (`av_*`), calls the Core Vocation
Service (`src/server/game/Vocations/CoreVocationService.h`) exclusively for anything
touching `characters`, `character_spell/talent/glyphs/action/inventory`, or
`item_instance`. This is the "multi-class" layer — a character with N saved class
profiles, switching among them through an in-fiction trainer interaction — as distinct
from Dual Discipline (`dual-discipline-design.md`), which is one main class plus one
level-scaled sub-class active simultaneously.

## 1. Trainer allowlist

Existing capital-city class trainers become Class Masters through configuration, not
through spawning anything new:

```sql
CREATE TABLE `av_classmaster_trainer` (
  `creatureEntry` INT UNSIGNED NOT NULL,   -- existing class trainer's creature_template entry
  `class` TINYINT UNSIGNED NOT NULL,       -- the one class this trainer offers as a Class Master
  `enabled` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (`creatureEntry`)
) ENGINE=InnoDB;
```

One row per trainer, one class per trainer — deliberately not a many-to-many table.
The brief is explicit that "each trainer offers only its own class"; making the schema
itself only capable of expressing that (a `class` column, not a `classMask`) means a
future misconfiguration can't accidentally offer multiple classes from one Class Master
without someone deliberately changing the table shape first, not just editing a row.

Default population: every existing class trainer already flagged as a trainer for
class X in stock `creature_template`/`npc_trainer` data gets a row here for that same
X, `enabled = 1`. Server owners narrow the allowlist by disabling rows, not by
maintaining a separate positive list from scratch.

## 2. Class rules configuration

```sql
CREATE TABLE `av_classmaster_class_rule` (
  `class` TINYINT UNSIGNED NOT NULL,
  `available` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  `switchCost` INT UNSIGNED NOT NULL DEFAULT 0,     -- copper, charged by the module
                                                      -- before calling SwitchClass, not by Core
  `cooldownSeconds` INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`class`)
) ENGINE=InnoDB;
```

Default row for `CLASS_DEATH_KNIGHT`: `available = 0`. This mirrors
`CoreVocationService::CanSwitchClass`'s own `ERR_TARGET_CLASS_DISABLED` guard (Core
design doc §7.1) — the module checks its own `available` flag *before* ever calling
Core, so a disabled class is rejected with a module-owned, configurable message rather
than always surfacing Core's generic enum text. Both layers agreeing independently
that Death Knight is off by default is intentional redundancy, not duplication to
clean up later: Core refusing it protects every caller, including future ones this
module doesn't know about yet; the module refusing it first just gives a nicer
in-fiction message.

Cooldown tracking is module-owned too — a `lastSwitchAt` timestamp per
`(characterGuid)`, checked before ever calling `CanSwitchClass`. This is a genuinely
separate table from anything Core owns:

```sql
CREATE TABLE `av_classmaster_cooldown` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `lastSwitchAt` DATETIME NOT NULL,
  PRIMARY KEY (`characterGuid`)
) ENGINE=InnoDB;
```

## 3. Interaction flow

```text
Player gossips a Class Master:
    1. Look up av_classmaster_trainer for this creature -> offeredClass
       (not enabled, or not in table at all -> ordinary trainer, no Class Master gossip
       option shown at all; this is the fallback for an addon-absent client too --
       see 3a)
    2. av_classmaster_class_rule(offeredClass).available == 0
       -> show configured "class unavailable" message, stop
    3. Cooldown check against av_classmaster_cooldown -- still on cooldown
       -> show remaining time, stop
    4. HasClassProfile(characterGuid, offeredClass) == false
       -> this is a first-time selection for this class. Show its cost as
          "first-time" (module config may price this differently from a
          re-switch -- e.g. free the first time, per class design intent)
       else
       -> show saved level, and GetArmorySummary(characterGuid, offeredClass) so
          the player can see what gear is waiting for them before committing
    5. Player confirms.
    6. Module charges switchCost (its own gold-deduction, not Core's problem).
    7. If HasClassProfile was false: CreateLevelOneClassProfile(player, offeredClass)
    8. result := CanSwitchClass(player, offeredClass)
       if result != SUCCESS: refund the charged cost, show result's message, stop
    9. result := SwitchClass(player, offeredClass)
       if result != SUCCESS: refund, show message, stop
       (SwitchClass re-runs its own guard checks internally per the Core design's
       step 1 -- the module's step 8 CanSwitchClass call is a pre-flight UX check,
       not a substitute for Core's own re-validation immediately before the
       transaction opens)
    10. On SUCCESS: write av_classmaster_cooldown.lastSwitchAt = now(),
        force the character-select return the Core design requires, done.
```

Refunding on any Core-reported failure is a module responsibility: the module charged
gold *before* calling Core specifically so the player sees the cost up front in the
gossip confirmation, which means the module must reverse that charge on any rejection
rather than assuming Core's failure implies no gold ever left the player.

### 3a. No-addon fallback

Steps 1-5 above are plain gossip menu text and options — no addon required for any of
it. The addon (when present) only replaces the *presentation* of steps 4's saved-level
and Armory-summary display with a richer window; the underlying gossip flow and every
validation step is identical whether or not the addon is installed, satisfying "the
addon never decides whether a class switch ... is valid" from the top-level brief.

## 4. Commands

Status: implemented in `ClassMasterCommands.cpp`, using the shared lookups in
`ClassMasterShared.h` (also used by `ClassMasterGossip.cpp`).

Player-facing (module-owned, thin wrappers over the read-only Core API plus
module-owned config lookups — no command in this list calls `SwitchClass` directly
without going through the same gossip-confirmation cost/cooldown logic above):

- `/av classes` — list `GetClassProfiles(characterGuid)`, annotated with each class's
  `av_classmaster_class_rule.available`.
- `/av armory [class]` — `GetArmorySummary(characterGuid, class)`.

GM commands (module-owned; `<class>` accepts a class name or a numeric id, parsed by
`ClassMasterShared.h`'s `ParseClassToken`):

- `.classmaster inspect <character> [class]` (SEC_GAMEMASTER) — dumps
  `GetClassProfiles(characterGuid)` for chat/console, and `GetArmorySummary` for the
  named class if one is given. Built directly on Core's existing read-only API rather
  than a dedicated `InspectClassProfile` Core method — nothing in the read path needs
  new Core code.
- `.classmaster setavailable <class> <on|off>`, `.classmaster setcost <class> <copper>`,
  `.classmaster setcooldown <class> <seconds>` (SEC_ADMINISTRATOR) → plain
  `av_classmaster_class_rule` writes, module-only, no Core involvement.

Not yet implemented: `.classmaster recover <character> <class>`. §7.3 of the Core
design doc calls for this to delegate to a Core-side `RecoverClassProfile` method that
doesn't exist yet — recovery logic (re-running archive/restore idempotently against
whatever state currently exists) needs its own design pass before it's built, not a
command-only add. `SwitchClass`'s existing transactional guarantees (§5 of the Core
design doc) mean the failure mode this exists to catch — a character stuck mid-switch
— should not occur in practice; this is a safety net, not a load-bearing part of normal
operation.

## 6. Class slot progression (level gates + gold sink)

Status: agreed direction; implemented in `ClassMasterGossip.cpp` alongside this doc.
Layered on top of §§1-4 — it does not replace the trainer/cost/cooldown model above,
it adds one more gate in front of "you may unlock a class you have never played."

Scope for this pass: **levels 1-60 only**, and no change to the existing
switch-cost/cooldown rules for classes already unlocked. Death Knight stays out of the
"9 classes" this system counts toward (§6.1/§6.2) the same way it's already
config-gated off by default in `av_classmaster_class_rule`/`CoreVocationService` — this
change doesn't touch that toggle, it just never counts DK as one of the 9 slots a
character is working toward. TBC/WotLK-range (61-80) content and rules are an explicit
future update, not decided here.

### 6.1 The model

A character does not unlock specific classes by leveling — leveling unlocks **slots**.
A slot is spent by choosing (and paying for) any class the player wants, at a Class Master,
same as today's flow. This is a second, independent gate on top of §3 step 2
(`av_classmaster_class_rule.available`): even an available class can't be picked as a
character's *N*th class if the character doesn't have an *N*th slot yet.

- Every character starts with **1 slot**, spent automatically on their class-creation
  class (no trainer visit needed for slot 1 — it's already "spent" the moment the
  character exists).
- **+1 slot** at character level 10, 20, 30, 40, 50, and 60 — six more slots, for **7
  total** purely from leveling.
- **Past level 60**: no further level gates. The remaining slots (there are 9
  non-Death-Knight classes, so 2 more after the 7 from leveling) are unlocked with gold
  only, at a Class Master.
- "Character level" for this gate means the **highest level that character has ever
  reached on any class**, not the currently-active class's level — a character who
  reached 35 on their starting class and then switched to a fresh level-1 second class
  keeps their level-35 slot count. This falls out of data the Core Vocation Service
  already has for free: `GREATEST(characters.level, MAX(av_core_class_profile.level)
  for that characterGuid)`. No new "highest level" column — it's a derived read.
- Buying a class does not require slots to be spent in level order or on any particular
  class — the player picks whichever of the still-locked classes they want, same free
  choice as an already-unlocked switch target.
- A slot, once spent on a class, is spent forever (matches "once they level up all the
  classes" framing) — there's no "reclaim a slot" mechanic in this design.

### 6.2 Formula

```text
freeSlots(highestLevel) = 1 + min(6, floor(highestLevel / 10))   // caps at 7, reached at level 60
totalSlots(character)   = freeSlots(highestLevel) + purchasedSlots
usedSlots(character)    = GetClassProfiles(characterGuid).size()
                           + 1 (for the character's currently-active class, unless a
                               returned profile already matches it -- a class only has
                               no profile row while it's still the character's original,
                               never-archived-away class -- see
                               core-vocation-service-design.md §2a)
```

A class-unlock attempt (i.e. `HasClassProfile == false` in §3 step 4) is only allowed
when `usedSlots < totalSlots`. Picking a class the character has *already* unlocked
(`HasClassProfile == true`) never consumes a slot and is ungated by this system — it's
purely today's switch-cost/cooldown flow.

### 6.3 New module-owned state

```sql
-- Gold-purchased slots beyond the level curve. Absence of a row == 0 purchased.
CREATE TABLE `av_classmaster_purchased_slots` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `purchasedSlots` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`characterGuid`)
) ENGINE=InnoDB;
```

No Core Vocation Service change is needed — `usedSlots`/`totalSlots` are computed from
`GetClassProfiles(characterGuid)` (already-public Core API, gives level + class per
archived profile) and `player->GetLevel()`/`player->getClass()`, plus this one new
module-owned table. The module still never reads `av_core_*` directly. The slot gate
is enforced in the gossip flow, before
step 6 (charge) / step 7 (`CreateLevelOneClassProfile`) of §3 — a rejected slot check
never reaches the Core service at all, same "module checks first, Core is the final
authority on the things Core actually owns" split already established for
`av_classmaster_class_rule.available` in §2.

### 6.4 Gossip UX addition

When a player picks a never-unlocked class at a Class Master and the slot check fails,
show which is blocking rather than a bare refusal:
- Still under the level curve: "You need to reach level {nextGate} before you can
  learn another calling." (`nextGate` = smallest multiple of 10 above `highestLevel`,
  capped display at 60.)
- Past level 60, out of purchased slots too: "You may unlock another calling for
  {slotCost} copper." with a confirm option that inserts/increments
  `av_classmaster_purchased_slots` and charges the player, before falling through to the
  normal unlock confirmation (§3 steps 6-10) for the class they picked.

`slotCost` is a new config key (`AzerothVocations.SlotPurchaseCost`, flat copper amount,
server-configurable) — deliberately not scaled per additional slot for this first pass;
revisit if a server owner reports it's too cheap/expensive in practice.

### 6.5 Hero class (future, not designed yet)

Once a character has all 9 non-Death-Knight classes at level 60, the **account**
(not just that character) unlocks a "Hero" class option for every character created on
it from then on. Explicitly out of scope to design in detail now — captured here only
so the slot/level-gate schema above doesn't paint it into a corner:

- Never selectable at character creation — every character still must start as one of
  the 9 normal classes and reach Hero (if unlocked account-wide) the same way it reaches
  any other class: via a Class Master, presumably still spending a slot, TBD.
- Concept: a single class that can use every resource type (rage/mana/energy/runic
  power/etc.) and wear every armor type — essentially the "capstone" class for an
  account that has fully completed the level-1-60 class roster once.
- Spellbook mechanism: `dual-discipline-design.md` §10 now covers this concretely —
  Hero is the Class Spellbook's tab-per-unlocked-class system with *every* tab live
  simultaneously (not just one sub-class tab), reusing the same
  `av_dual_discipline_spell_catalog` and clone-spell cost-conversion mechanism (§9),
  scaled from 1 extra live tab to 9. This still needs its own design pass for the
  armor-type-mixing half (which Class Armory validity rule applies, if any) before any
  schema or code is written for it — the spellbook half is no longer undesigned, the
  armor half still is.

## 7. Open question for joint review

Section 3 step 6 charges gold *before* the `CanSwitchClass` pre-flight check in step 8,
so that the confirmation dialog's displayed cost is guaranteed accurate even if some
guard state changes in the gap between menu-open and confirm-click — but that means a
rejection at step 8 or 9 requires a refund path to exist and be tested as carefully as
the charge path. Alternative: check `CanSwitchClass` *before* charging (reorder steps 6
and 8) and accept that the cost shown in the gossip menu could theoretically go stale
by the time of confirmation on a very fast double-click. Recommend the reorder
(check first, charge second) — it removes the refund code path entirely rather than
requiring it to be correct — but flagging rather than deciding, since it changes the
UX guarantee slightly (cost shown is "as of menu open," not "guaranteed final").
