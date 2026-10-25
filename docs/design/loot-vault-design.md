# Loot Vault — Design Document (standalone, not part of Class Armory)

Status: proposed, not implemented.

## Why this is a separate feature from the Class Armory

The Class Armory (`av_core_class_armory_item`, see `core-vocation-service-design.md` §4)
exists to hold a specific class's *equipped* gear (19 slots max) while that class is
inactive. It is keyed by `(characterGuid, class, equipSlot)` and only ever holds
something that was equipped at the moment of a class switch.

The actual problem here is different: general bag/bank bloat from ordinary loot —
drops piling up faster than they can be sorted, sold, or disenchanted, independent of
whether the player ever touches Vocations at all. A player who never visits a
Class Master still needs this. So this is its own module-owned feature (`av_*`, not
`av_core_*`), with its own table, usable standalone.

## Core mechanic (reuses the same safety property already proven for the Armory)

Exactly the same invariant as §4.1 of the Armory design: an `item_instance` row is
never copied, never deleted. "Depositing" an item into the Vault means removing its
`character_inventory` row (so it stops occupying bag/bank space and the stock
inventory loader stops seeing it, with zero core changes, for the same reason as the
Armory) and recording it in a Vault table instead. "Withdrawing" reverses that.

## Schema proposal

```sql
CREATE TABLE `av_loot_vault_item` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `itemGuid` INT UNSIGNED NOT NULL,       -- item_instance.guid, unchanged
  `itemEntry` INT UNSIGNED NOT NULL,      -- denormalized for display/sort only
  `stackCount` INT UNSIGNED NOT NULL DEFAULT 1,
  `depositedAt` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`itemGuid`),
  KEY `idx_char` (`characterGuid`),
  KEY `idx_char_entry` (`characterGuid`, `itemEntry`)  -- "how many of X do I have vaulted"
) ENGINE=InnoDB;
```

No class column, no class coupling. `idx_item`-style uniqueness is automatic here since
`itemGuid` is the primary key.

## Differences from the Class Armory that matter for correctness

- **Capacity.** The Armory is bounded (at most 19 rows per class, one per equip slot).
  A Loot Vault is explicitly meant to hold *many* items — capacity policy (unlimited,
  or a configured cap) is a `mod-azeroth-vocations`-owned config decision, not a Core
  service concern, since this table isn't Core-owned at all.
- **Stacking.** Equipped gear is never stackable; loot commonly is. Depositing a
  partial stack from a bag slot needs to either (a) require depositing the whole stack
  (simplest, matches "don't duplicate or delete" most cleanly — splitting a stack
  itself already goes through normal AzerothCore item-split logic *before* this
  feature sees it, so the Vault only ever handles whole `item_instance` rows) or (b)
  explicitly support partial-stack deposit by adjusting `count` on the source
  `item_instance` and creating a genuinely new `item_instance` row for the deposited
  portion via the same path a normal stack-split already uses. (a) is recommended for
  v1: simpler, and reuses an already-correct core code path (split first, then deposit
  the resulting new item) instead of reimplementing split logic here.
- **Bank vs. bag source.** Unlike the Armory (equipment slots only), Vault deposits can
  originate from a bag slot *or* a bank slot. Both are just `character_inventory` rows
  with different `bag` values; the deposit/withdraw operation doesn't care which.
- **No class/class concept at all.** Any player, Vocations or not, can use it. This is
  what makes it safe to ship independently of, and before, the Vocations project.

## Interaction with Vocations (informational only, not a dependency)

If a character *does* use Vocations, the two features never touch each other's tables.
An item parked in `av_core_class_armory_item` is not eligible for Vault deposit (it has
no `character_inventory` row to deposit *from* — it's already "elsewhere"), and a Vault
item is likewise not visible to `SwitchClass`'s equipment parking (it's not equipped, so
it was never a candidate). No shared code path, no shared table, no ordering
dependency between the two.

## Player-facing surface (module-owned, gameplay layer — not Core)

- Command or NPC-driven deposit/withdraw (exact UX — command vs. gossip vs. dedicated
  NPC — is a `mod-azeroth-vocations` gameplay decision, not part of this design doc).
- Deposit: player targets/selects an item; service validates it's not soulbound-in-a-
  way-that-matters (soulbound is fine to vault — it's still the same character's item —
  but currently equipped-and-required-for-combat state should block it same as the
  Armory's in-combat guard), removes its `character_inventory` row, inserts the Vault
  row.
- Withdraw: requires free bag space (or bank space) for the target slot; on failure,
  item stays vaulted (same "never lose it" property as the Armory's failed-restore
  case).
- Read-only listing: `GetVaultSummary(characterGuid)` — same shape as
  `GetArmorySummary`, just without the class/slot dimension.

## Open question for joint review

Should this ship as part of `mod-azeroth-vocations`, or as a fully independent module
with no dependency on Vocations at all (given it has no actual coupling to it)? Given
"no dependency exists," a standalone module is the more honest packaging — it can ship
and be used on servers that never install Vocations. Recommending standalone; flagging
for explicit agreement rather than deciding unilaterally, since it changes which
module's README/config owns it.
