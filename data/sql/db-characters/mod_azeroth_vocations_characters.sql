-- Module-owned (av_*), characters-DB. Not av_core_* -- this is cooldown
-- bookkeeping for the gossip flow, not class/profile state.

CREATE TABLE IF NOT EXISTS `av_classmaster_cooldown` (
  `characterGuid` INT UNSIGNED NOT NULL,
  `lastSwitchAt` DATETIME NOT NULL,
  PRIMARY KEY (`characterGuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
