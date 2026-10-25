# mod-azeroth-vocations

FFXIV-inspired class switching for AzerothCore 3.3.5a. A character keeps one class
active in the normal core tables at a time, and can switch to any other class
at an allowlisted trainer ("Class Master"), starting that class fresh at level 1
the first time. Each class's spells, talents, glyphs, action bars, and
equipped gear are archived separately and restored automatically on switch
back.

This module (`av_*` tables, gossip flow, config) is a thin gameplay layer over
the **Core Vocation Service** (`src/server/game/Vocations/CoreVocationService.h`,
`av_core_*` tables), which owns every write to `characters`,
`character_spell/talent/glyphs/action/inventory`, and `item_instance` for a
class switch. This module never touches those tables directly -- see
`docs/design/core-vocation-service-design.md` for the ownership boundary and
`docs/design/classmaster-gameplay-design.md` for the gossip flow this
implements.

## Status

Implemented: trainer-triggered class switch, level-1 start for a class never
played before, the Class Armory (parked equipment), class-slot progression
(level gates + gold sink, see `docs/design/classmaster-gameplay-design.md` §6),
and the `/av` and `.classmaster` commands below. Not yet implemented: Dual
Discipline (sub-classes, see `docs/design/dual-discipline-design.md`), Loot
Vault (`docs/design/loot-vault-design.md`), `.classmaster recover` (needs a new
Core-side recovery API, not yet designed), and addon integration.

## Commands

Player (`ClassMasterCommands.cpp`):
- `/av classes` -- list your unlocked classes and their saved level.
- `/av armory [class]` -- list what's parked in a class's Class Armory
  (defaults to your current class).

GM (`ClassMasterCommands.cpp`):
- `.classmaster inspect <character> [class]` (GM) -- dump a character's class
  profiles, and optionally one class's Class Armory contents.
- `.classmaster setavailable <class> <on|off>` (Admin) -- enable/disable a
  class at every Class Master.
- `.classmaster setcost <class> <copper>` (Admin) -- set a class's switch cost.
- `.classmaster setcooldown <class> <seconds>` (Admin) -- set a class's switch
  cooldown.

`<class>` accepts either a class name (e.g. `mage`) or a numeric class id.

## Setup

1. Enable both config keys in `conf/mod_azeroth_vocations.conf.dist`:
   `AzerothVocations.Enable` and `AzerothVocations.Core.Enable`.
2. Trainers: `data/sql/db-world/mod_azeroth_vocations_world.sql` turns every
   stock class trainer for the 9 supported classes into a Class Master --
   321 creature_template entries (all races, both factions, every level
   range), covering every real "&lt;Class&gt; Trainer" NPC in the base data.
   One real conflict (Shenthul, entry 3401, already has a different
   `ScriptName`) and 4 unused/placeholder rows were excluded; every other
   entry was confirmed to have an empty `ScriptName` before being claimed.

   To add any other NPC (a non-trainer creature, say), first confirm its
   `creature_template.ScriptName` is empty (this module's `UPDATE` replaces
   that field, and a non-empty one is a real existing hook you'd be
   overwriting), then:
   ```sql
   INSERT INTO `av_classmaster_trainer` (`creatureEntry`, `class`, `enabled`) VALUES (<entry>, <class>, 1);
   UPDATE `creature_template` SET `ScriptName` = 'av_classmaster_gossip' WHERE `entry` = <entry>;
   ```
3. Adjust `av_classmaster_class_rule` (availability, switch cost, cooldown) and
   `AzerothVocations.Core.ClassEnabled.<class>` as desired. Death Knight is
   disabled by default in both places.

## How a switch works in-game

Gossiping an allowlisted trainer adds a "Change my class" option alongside
its normal trainer/vendor/quest options (which keep working unmodified).
Selecting it walks the player through availability, cooldown, saved-level/
Class Armory preview, and a confirmation, then performs the switch and logs the
player out (required so the client reloads with the new class's data).

## Ownership

- `mod-azeroth-vocations` (this module): `av_classmaster_trainer`,
  `av_classmaster_class_rule`, `av_classmaster_cooldown`, and the gossip script.
- Core Vocation Service (core, not this module): `av_core_*` tables and all
  archive/restore logic. Called only through `CoreVocationService.h`'s public
  API -- see the design docs before adding any new cross-boundary call.
