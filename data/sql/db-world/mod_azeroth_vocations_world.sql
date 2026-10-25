-- mod-azeroth-vocations world-DB tables. Module-owned (av_*), never touches
-- av_core_* (Core Vocation Service) or any characters-DB table directly.

CREATE TABLE IF NOT EXISTS `av_classmaster_trainer` (
  `creatureEntry` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `enabled` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (`creatureEntry`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `av_classmaster_class_rule` (
  `class` TINYINT UNSIGNED NOT NULL,
  `available` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  `switchCost` INT UNSIGNED NOT NULL DEFAULT 0,
  `cooldownSeconds` INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`class`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Death Knight excluded by default, per the brief.
INSERT INTO `av_classmaster_class_rule` (`class`, `available`, `switchCost`, `cooldownSeconds`) VALUES
(1, 1, 0, 0),  -- Warrior
(2, 1, 0, 0),  -- Paladin
(3, 1, 0, 0),  -- Hunter
(4, 1, 0, 0),  -- Rogue
(5, 1, 0, 0),  -- Priest
(6, 0, 0, 0),  -- Death Knight (disabled by default)
(7, 1, 0, 0),  -- Shaman
(8, 1, 0, 0),  -- Mage
(9, 1, 0, 0),  -- Warlock
(11, 1, 0, 0)  -- Druid
ON DUPLICATE KEY UPDATE `class` = `class`;

-- Generic gossip greeting used by every Class Master submenu (ClassMasterGossip.cpp).
-- Module-reserved npc_text id -- do not reuse for anything else.
DELETE FROM `npc_text` WHERE `ID` = 999900;
INSERT INTO `npc_text` (`ID`, `text0_0`) VALUES
(999900, 'I can teach you the ways of a different calling, if you are willing to start anew.');

-- Full trainer population: every stock class trainer for the 9 supported
-- classes (326 candidates in creature_template.sql, minus 1 real conflict --
-- entry 3401 'Shenthul' already has ScriptName='npc_shenthul' -- and 4
-- unused/placeholder rows never spawned in the game world). Verified
-- programmatically against data/sql/base/db_world/creature_template.sql:
-- every entry below had ScriptName = '' before this file claimed it.
-- `AIName` (e.g. 'SmartAI') is untouched -- see the warning further up
-- this file for why that distinction matters.
DELETE FROM `av_classmaster_trainer` WHERE `creatureEntry` IN (911, 912, 913, 914, 985, 1229, 1403, 1901, 2119, 2131, 3041, 3042, 3043, 3059, 3063, 3153, 3169, 3353, 3354, 3408, 3593, 3598, 4087, 4089, 4593, 4594, 4595, 4992, 5113, 5114, 5479, 5480, 5959, 5966, 5967, 7315, 8141, 10291, 16503, 16771, 17120, 17480, 17504, 26332, 925, 926, 927, 928, 1232, 4988, 5147, 5148, 5149, 5491, 5492, 8140, 15280, 16275, 16501, 16679, 16680, 16681, 16761, 17121, 17483, 17509, 20406, 23128, 26327, 35281, 895, 987, 1231, 1404, 2218, 3038, 3039, 3040, 3061, 3065, 3154, 3171, 3352, 3406, 3407, 3596, 3601, 3963, 4138, 4146, 4205, 4986, 5115, 5116, 5117, 5501, 5515, 5516, 5517, 8308, 10930, 15513, 16270, 16499, 16672, 16673, 16674, 16738, 17110, 17122, 17505, 26325, 915, 916, 917, 918, 1234, 1411, 2122, 2130, 3155, 3170, 3327, 3328, 3594, 3599, 4163, 4214, 4215, 4582, 4583, 4584, 4990, 5165, 5166, 5167, 5960, 5968, 13283, 15285, 16279, 16684, 16685, 16686, 16759, 26329, 375, 376, 377, 837, 1226, 2123, 2129, 3044, 3045, 3046, 3595, 3600, 3706, 3707, 4090, 4091, 4092, 4606, 4607, 4608, 4989, 5141, 5142, 5143, 5484, 5489, 5964, 5973, 6014, 6018, 11397, 11401, 11406, 15284, 16276, 16502, 16658, 16659, 16660, 16756, 17482, 17510, 17511, 19247, 26328, 373, 986, 1406, 2219, 3030, 3031, 3032, 3062, 3066, 3157, 3173, 3344, 3403, 4991, 5965, 5971, 13417, 16661, 17089, 17204, 17212, 17219, 17519, 17520, 18270, 20407, 23127, 26330, 198, 328, 944, 1228, 2124, 2128, 3047, 3048, 3049, 4566, 4567, 4568, 4987, 5144, 5145, 5146, 5497, 5498, 5880, 5882, 5883, 5884, 5885, 5961, 5969, 7311, 7312, 7488, 15279, 16269, 16500, 16651, 16652, 16653, 16749, 17105, 17481, 17513, 17514, 23103, 26326, 27704, 28956, 28958, 459, 460, 461, 906, 988, 1408, 2126, 2127, 3156, 3172, 3324, 3325, 3326, 4563, 4564, 4565, 4993, 5171, 5172, 5173, 5495, 5496, 5612, 5962, 5970, 15283, 16266, 16646, 16647, 16648, 16770, 23534, 26331, 542, 1409, 2217, 3033, 3034, 3036, 3060, 3064, 3597, 3602, 4217, 4218, 4219, 4985, 5504, 5505, 5506, 5963, 5972, 8142, 9465, 12042, 16655, 16721, 26324);
INSERT INTO `av_classmaster_trainer` (`creatureEntry`, `class`, `enabled`) VALUES
(911, 1, 1), -- Llane Beshere, Warrior Trainer
(912, 1, 1), -- Thran Khorman, Warrior Trainer
(913, 1, 1), -- Lyria Du Lac, Warrior Trainer
(914, 1, 1), -- Ander Germaine, Warrior Trainer
(985, 1, 1), -- Malosh, Warrior Trainer
(1229, 1, 1), -- Granis Swiftaxe, Warrior Trainer
(1403, 1, 1), -- Mogwah, Warrior Trainer
(1901, 1, 1), -- Kelstrum Stonebreaker, Warrior Trainer
(2119, 1, 1), -- Dannal Stern, Warrior Trainer
(2131, 1, 1), -- Austil de Mon, Warrior Trainer
(3041, 1, 1), -- Torm Ragetotem, Warrior Trainer
(3042, 1, 1), -- Sark Ragetotem, Warrior Trainer
(3043, 1, 1), -- Ker Ragetotem, Warrior Trainer
(3059, 1, 1), -- Harutt Thunderhorn, Warrior Trainer
(3063, 1, 1), -- Krang Stonehoof, Warrior Trainer
(3153, 1, 1), -- Frang, Warrior Trainer
(3169, 1, 1), -- Tarshaw Jaggedscar, Warrior Trainer
(3353, 1, 1), -- Grezz Ragefist, Warrior Trainer
(3354, 1, 1), -- Sorek, Warrior Trainer
(3408, 1, 1), -- Zel\'mak, Warrior Trainer
(3593, 1, 1), -- Alyissia, Warrior Trainer
(3598, 1, 1), -- Kyra Windblade, Warrior Trainer
(4087, 1, 1), -- Arias\'ta Bladesinger, Warrior Trainer
(4089, 1, 1), -- Sildanair, Warrior Trainer
(4593, 1, 1), -- Christoph Walker, Warrior Trainer
(4594, 1, 1), -- Angela Curthas, Warrior Trainer
(4595, 1, 1), -- Baltus Fowler, Warrior Trainer
(4992, 1, 1), -- World Warrior Trainer, Warrior Trainer
(5113, 1, 1), -- Kelv Sternhammer, Warrior Trainer
(5114, 1, 1), -- Bilban Tosslespanner, Warrior Trainer
(5479, 1, 1), -- Wu Shen, Warrior Trainer
(5480, 1, 1), -- Ilsa Corbin, Warrior Trainer
(5959, 1, 1), -- World Dwarf Male Warrior Trainer, Warrior Trainer
(5966, 1, 1), -- World Night Elf Male Warrior Trainer, Warrior Trainer
(5967, 1, 1), -- World Dwarf Female Warrior Trainer, Warrior Trainer
(7315, 1, 1), -- Darnath Bladesinger, Warrior Trainer
(8141, 1, 1), -- Captain Evencane, Warrior Trainer
(10291, 1, 1), -- Krysteea, Warrior Trainer
(16503, 1, 1), -- Kore, Warrior Trainer
(16771, 1, 1), -- Ahonan, Warrior Trainer
(17120, 1, 1), -- Behomat, Warrior Trainer
(17480, 1, 1), -- Ruada, Warrior Trainer
(17504, 1, 1), -- Kazi, Warrior Trainer
(26332, 1, 1), -- Warrior Trainer, 
(925, 2, 1), -- Brother Sammuel, Paladin Trainer
(926, 2, 1), -- Bromos Grummner, Paladin Trainer
(927, 2, 1), -- Brother Wilhelm, Paladin Trainer
(928, 2, 1), -- Lord Grayson Shadowbreaker, Paladin Trainer
(1232, 2, 1), -- Azar Stronghammer, Paladin Trainer
(4988, 2, 1), -- World Paladin Trainer, Paladin Trainer
(5147, 2, 1), -- Valgar Highforge, Paladin Trainer
(5148, 2, 1), -- Beldruk Doombrow, Paladin Trainer
(5149, 2, 1), -- Brandur Ironhammer, Paladin Trainer
(5491, 2, 1), -- Arthur the Faithful, Paladin Trainer
(5492, 2, 1), -- Katherine the Pure, Paladin Trainer
(8140, 2, 1), -- Brother Karman, Paladin Trainer
(15280, 2, 1), -- Jesthenis Sunstriker, Paladin Trainer
(16275, 2, 1), -- Noellene, Paladin Trainer
(16501, 2, 1), -- Aurelon, Paladin Trainer
(16679, 2, 1), -- Osselan, Paladin Trainer
(16680, 2, 1), -- Ithelis, Paladin Trainer
(16681, 2, 1), -- Champion Bachi, Paladin Trainer
(16761, 2, 1), -- Baatun, Paladin Trainer
(17121, 2, 1), -- Kavaan, Paladin Trainer
(17483, 2, 1), -- Tullas, Paladin Trainer
(17509, 2, 1), -- Jol, Paladin Trainer
(20406, 2, 1), -- Champion Cyssa Dawnrose, Paladin Trainer
(23128, 2, 1), -- Master Pyreanor, Paladin Trainer
(26327, 2, 1), -- Paladin Trainer, 
(35281, 2, 1), -- Rukua, Paladin Trainer
(895, 3, 1), -- Thorgas Grimson, Hunter Trainer
(987, 3, 1), -- Ogromm, Hunter Trainer
(1231, 3, 1), -- Grif Wildheart, Hunter Trainer
(1404, 3, 1), -- Kragg, Hunter Trainer
(2218, 3, 1), -- Undead Hunter Trainer, Hunter Trainer
(3038, 3, 1), -- Kary Thunderhorn, Hunter Trainer
(3039, 3, 1), -- Holt Thunderhorn, Hunter Trainer
(3040, 3, 1), -- Urek Thunderhorn, Hunter Trainer
(3061, 3, 1), -- Lanka Farshot, Hunter Trainer
(3065, 3, 1), -- Yaw Sharpmane, Hunter Trainer
(3154, 3, 1), -- Jen\'shan, Hunter Trainer
(3171, 3, 1), -- Thotar, Hunter Trainer
(3352, 3, 1), -- Ormak Grimshot, Hunter Trainer
(3406, 3, 1), -- Xor\'juul, Hunter Trainer
(3407, 3, 1), -- Sian\'dur, Hunter Trainer
(3596, 3, 1), -- Ayanna Everstride, Hunter Trainer
(3601, 3, 1), -- Dazalar, Hunter Trainer
(3963, 3, 1), -- Danlaar Nightstride, Hunter Trainer
(4138, 3, 1), -- Jeen\'ra Nightrunner, Hunter Trainer
(4146, 3, 1), -- Jocaste, Hunter Trainer
(4205, 3, 1), -- Dorion, Hunter Trainer
(4986, 3, 1), -- World Hunter Trainer, Hunter Trainer
(5115, 3, 1), -- Daera Brightspear, Hunter Trainer
(5116, 3, 1), -- Olmin Burningbeard, Hunter Trainer
(5117, 3, 1), -- Regnus Thundergranite, Hunter Trainer
(5501, 3, 1), -- Kaerbrus, Hunter Trainer
(5515, 3, 1), -- Einris Brightspear, Hunter Trainer
(5516, 3, 1), -- Ulfir Ironbeard, Hunter Trainer
(5517, 3, 1), -- Thorfin Stoneshield, Hunter Trainer
(8308, 3, 1), -- Alenndaar Lapidaar, Hunter Trainer
(10930, 3, 1), -- Dargh Trueaim, Hunter Trainer
(15513, 3, 1), -- Ranger Sallina, Hunter Trainer
(16270, 3, 1), -- Hannovia, Hunter Trainer
(16499, 3, 1), -- Keilnei, Hunter Trainer
(16672, 3, 1), -- Tana, Hunter Trainer
(16673, 3, 1), -- Oninath, Hunter Trainer
(16674, 3, 1), -- Zandine, Hunter Trainer
(16738, 3, 1), -- Deremiis, Hunter Trainer
(17110, 3, 1), -- Acteon, Hunter Trainer
(17122, 3, 1), -- Vord, Hunter Trainer
(17505, 3, 1), -- Killac, Hunter Trainer
(26325, 3, 1), -- Hunter Trainer, 
(915, 4, 1), -- Jorik Kerridan, Rogue Trainer
(916, 4, 1), -- Solm Hargrin, Rogue Trainer
(917, 4, 1), -- Keryn Sylvius, Rogue Trainer
(918, 4, 1), -- Osborne the Night Man, Rogue Trainer
(1234, 4, 1), -- Hogral Bakkan, Rogue Trainer
(1411, 4, 1), -- Ian Strom, Rogue Trainer
(2122, 4, 1), -- David Trias, Rogue Trainer
(2130, 4, 1), -- Marion Call, Rogue Trainer
(3155, 4, 1), -- Rwag, Rogue Trainer
(3170, 4, 1), -- Kaplak, Rogue Trainer
(3327, 4, 1), -- Gest, Rogue Trainer
(3328, 4, 1), -- Ormok, Rogue Trainer
(3594, 4, 1), -- Frahun Shadewhisper, Rogue Trainer
(3599, 4, 1), -- Jannok Breezesong, Rogue Trainer
(4163, 4, 1), -- Syurna, Rogue Trainer
(4214, 4, 1), -- Erion Shadewhisper, Rogue Trainer
(4215, 4, 1), -- Anishar, Rogue Trainer
(4582, 4, 1), -- Carolyn Ward, Rogue Trainer
(4583, 4, 1), -- Miles Dexter, Rogue Trainer
(4584, 4, 1), -- Gregory Charles, Rogue Trainer
(4990, 4, 1), -- World Rogue Trainer, Rogue Trainer
(5165, 4, 1), -- Hulfdan Blackbeard, Rogue Trainer
(5166, 4, 1), -- Ormyr Flinteye, Rogue Trainer
(5167, 4, 1), -- Fenthwick, Rogue Trainer
(5960, 4, 1), -- World Human Male Rogue Trainer, Rogue Trainer
(5968, 4, 1), -- World Human Female Rogue Trainer, Rogue Trainer
(13283, 4, 1), -- Lord Tony Romano, Rogue Trainer
(15285, 4, 1), -- Pathstalker Kariel, Rogue Trainer
(16279, 4, 1), -- Tannaria, Rogue Trainer
(16684, 4, 1), -- Zelanis, Rogue Trainer
(16685, 4, 1), -- Elara, Rogue Trainer
(16686, 4, 1), -- Nerisen, Rogue Trainer
(16759, 4, 1), -- Saran Nozzlevolt, Rogue Trainer
(26329, 4, 1), -- Rogue Trainer, 
(375, 5, 1), -- Priestess Anetta, Priest Trainer
(376, 5, 1), -- High Priestess Laurena, Priest Trainer
(377, 5, 1), -- Priestess Josetta, Priest Trainer
(837, 5, 1), -- Branstock Khalder, Priest Trainer
(1226, 5, 1), -- Maxan Anvol, Priest Trainer
(2123, 5, 1), -- Dark Cleric Duesten, Priest Trainer
(2129, 5, 1), -- Dark Cleric Beryl, Priest Trainer
(3044, 5, 1), -- Miles Welsh, Priest Trainer
(3045, 5, 1), -- Malakai Cross, Priest Trainer
(3046, 5, 1), -- Father Cobb, Priest Trainer
(3595, 5, 1), -- Shanda, Priest Trainer
(3600, 5, 1), -- Laurna Morninglight, Priest Trainer
(3706, 5, 1), -- Tai\'jin, Priest Trainer
(3707, 5, 1), -- Ken\'jai, Priest Trainer
(4090, 5, 1), -- Astarii Starseeker, Priest Trainer
(4091, 5, 1), -- Jandria, Priest Trainer
(4092, 5, 1), -- Lariia, Priest Trainer
(4606, 5, 1), -- Aelthalyste, Priest Trainer
(4607, 5, 1), -- Father Lankester, Priest Trainer
(4608, 5, 1), -- Father Lazarus, Priest Trainer
(4989, 5, 1), -- World Priest Trainer, Priest Trainer
(5141, 5, 1), -- Theodrus Frostbeard, Priest Trainer
(5142, 5, 1), -- Braenna Flintcrag, Priest Trainer
(5143, 5, 1), -- Toldren Deepiron, Priest Trainer
(5484, 5, 1), -- Brother Benjamin, Priest Trainer
(5489, 5, 1), -- Brother Joshua, Priest Trainer
(5964, 5, 1), -- World Undead Male Priest Trainer, Priest Trainer
(5973, 5, 1), -- World Undead Female Priest Trainer, Priest Trainer
(6014, 5, 1), -- X\'yera, Priest Trainer
(6018, 5, 1), -- Ur\'kyo, Priest Trainer
(11397, 5, 1), -- Nara Meideros, Priest Trainer
(11401, 5, 1), -- Priestess Alathea, Priest Trainer
(11406, 5, 1), -- High Priest Rohan, Priest Trainer
(15284, 5, 1), -- Matron Arena, Priest Trainer
(16276, 5, 1), -- Ponaris, Priest Trainer
(16502, 5, 1), -- Zalduun, Priest Trainer
(16658, 5, 1), -- Aldrae, Priest Trainer
(16659, 5, 1), -- Lotheolan, Priest Trainer
(16660, 5, 1), -- Belestra, Priest Trainer
(16756, 5, 1), -- Caedmos, Priest Trainer
(17482, 5, 1), -- Guvan, Priest Trainer
(17510, 5, 1), -- Izmir, Priest Trainer
(17511, 5, 1), -- Fallat, Priest Trainer
(19247, 5, 1), -- Nuolla Dawncaller, Priest Trainer
(26328, 5, 1), -- Priest Trainer, 
(373, 7, 1), -- Murak Winterborn, Shaman Trainer
(986, 7, 1), -- Haromm, Shaman Trainer
(1406, 7, 1), -- Ghok, Shaman Trainer
(2219, 7, 1), -- Undead Shaman Trainer, Shaman Trainer
(3030, 7, 1), -- Siln Skychaser, Shaman Trainer
(3031, 7, 1), -- Tigor Skychaser, Shaman Trainer
(3032, 7, 1), -- Beram Skychaser, Shaman Trainer
(3062, 7, 1), -- Meela Dawnstrider, Shaman Trainer
(3066, 7, 1), -- Narm Skychaser, Shaman Trainer
(3157, 7, 1), -- Shikrik, Shaman Trainer
(3173, 7, 1), -- Swart, Shaman Trainer
(3344, 7, 1), -- Kardris Dreamseeker, Shaman Trainer
(3403, 7, 1), -- Sian\'tsu, Shaman Trainer
(4991, 7, 1), -- World Shaman Trainer, Shaman Trainer
(5965, 7, 1), -- World Troll Male Shaman Trainer, Shaman Trainer
(5971, 7, 1), -- World Troll Female Shaman Trainer, Shaman Trainer
(13417, 7, 1), -- Sagorne Creststrider, Shaman Trainer
(16661, 7, 1), -- Gez\'li, Shaman Trainer
(17089, 7, 1), -- Firmanvaar, Shaman Trainer
(17204, 7, 1), -- Farseer Nobundo, Shaman Trainer
(17212, 7, 1), -- Tuluun, Shaman Trainer
(17219, 7, 1), -- Sulaa, Shaman Trainer
(17519, 7, 1), -- Hobahken, Shaman Trainer
(17520, 7, 1), -- Gurrag, Shaman Trainer
(18270, 7, 1), -- Kruugall, Shaman Trainer
(20407, 7, 1), -- Farseer Umbrua, Shaman Trainer
(23127, 7, 1), -- Farseer Javad, Shaman Trainer
(26330, 7, 1), -- Shaman Trainer, 
(198, 8, 1), -- Khelden Bremen, Mage Trainer
(328, 8, 1), -- Zaldimar Wefhellt, Mage Trainer
(944, 8, 1), -- Marryk Nurribit, Mage Trainer
(1228, 8, 1), -- Magis Sparkmantle, Mage Trainer
(2124, 8, 1), -- Isabella, Mage Trainer
(2128, 8, 1), -- Cain Firesong, Mage Trainer
(3047, 8, 1), -- Archmage Shymm, Mage Trainer
(3048, 8, 1), -- Ursyn Ghull, Mage Trainer
(3049, 8, 1), -- Thurston Xane, Mage Trainer
(4566, 8, 1), -- Kaelystia Hatebringer, Mage Trainer
(4567, 8, 1), -- Pierce Shackleton, Mage Trainer
(4568, 8, 1), -- Anastasia Hartwell, Mage Trainer
(4987, 8, 1), -- World Mage Trainer, Mage Trainer
(5144, 8, 1), -- Bink, Mage Trainer
(5145, 8, 1), -- Juli Stormkettle, Mage Trainer
(5146, 8, 1), -- Nittlebur Sparkfizzle, Mage Trainer
(5497, 8, 1), -- Jennea Cannon, Mage Trainer
(5498, 8, 1), -- Elsharin, Mage Trainer
(5880, 8, 1), -- Un\'Thuwa, Mage Trainer
(5882, 8, 1), -- Pephredo, Mage Trainer
(5883, 8, 1), -- Enyo, Mage Trainer
(5884, 8, 1), -- Mai\'ah, Mage Trainer
(5885, 8, 1), -- Deino, Mage Trainer
(5961, 8, 1), -- World Gnome Male Mage Trainer, Mage Trainer
(5969, 8, 1), -- World Gnome Female Mage Trainer, Mage Trainer
(7311, 8, 1), -- Uthel\'nay, Mage Trainer
(7312, 8, 1), -- Dink, Mage Trainer
(7488, 8, 1), -- Haka\'wani, Mage Trainer
(15279, 8, 1), -- Julia Sunstriker, Mage Trainer
(16269, 8, 1), -- Garridel, Mage Trainer
(16500, 8, 1), -- Valaatu, Mage Trainer
(16651, 8, 1), -- Zaedana, Mage Trainer
(16652, 8, 1), -- Quithas, Mage Trainer
(16653, 8, 1), -- Inethven, Mage Trainer
(16749, 8, 1), -- Edirah, Mage Trainer
(17105, 8, 1), -- Emissary Valustraa, Mage Trainer
(17481, 8, 1), -- Semid, Mage Trainer
(17513, 8, 1), -- Harnan, Mage Trainer
(17514, 8, 1), -- Bati, Mage Trainer
(23103, 8, 1), -- Derek the Undying, Mage Trainer
(26326, 8, 1), -- Mage Trainer, 
(27704, 8, 1), -- Horace Alder, Mage Trainer
(28956, 8, 1), -- Warcaster Fanoraithe, Mage Trainer
(28958, 8, 1), -- Jessa Weaver, Mage Trainer
(459, 9, 1), -- Drusilla La Salle, Warlock Trainer
(460, 9, 1), -- Alamar Grimm, Warlock Trainer
(461, 9, 1), -- Demisette Cloyce, Warlock Trainer
(906, 9, 1), -- Maximillian Crowe, Warlock Trainer
(988, 9, 1), -- Kartosh, Warlock Trainer
(1408, 9, 1), -- Thragg, Warlock Trainer
(2126, 9, 1), -- Maximillion, Warlock Trainer
(2127, 9, 1), -- Rupert Boch, Warlock Trainer
(3156, 9, 1), -- Nartok, Warlock Trainer
(3172, 9, 1), -- Dhugru Gorelust, Warlock Trainer
(3324, 9, 1), -- Grol\'dar, Warlock Trainer
(3325, 9, 1), -- Mirket, Warlock Trainer
(3326, 9, 1), -- Zevrost, Warlock Trainer
(4563, 9, 1), -- Kaal Soulreaper, Warlock Trainer
(4564, 9, 1), -- Luther Pickman, Warlock Trainer
(4565, 9, 1), -- Richard Kerwin, Warlock Trainer
(4993, 9, 1), -- World Warlock Trainer, Warlock Trainer
(5171, 9, 1), -- Thistleheart, Warlock Trainer
(5172, 9, 1), -- Briarthorn, Warlock Trainer
(5173, 9, 1), -- Alexander Calder, Warlock Trainer
(5495, 9, 1), -- Ursula Deline, Warlock Trainer
(5496, 9, 1), -- Sandahl, Warlock Trainer
(5612, 9, 1), -- Gimrizz Shadowcog, Warlock Trainer
(5962, 9, 1), -- World Orc Male Warlock Trainer, Warlock Trainer
(5970, 9, 1), -- World Orc Female Warlock Trainer, Warlock Trainer
(15283, 9, 1), -- Summoner Teli\'Larien, Warlock Trainer
(16266, 9, 1), -- Celoenus, Warlock Trainer
(16646, 9, 1), -- Alamma, Warlock Trainer
(16647, 9, 1), -- Talionia, Warlock Trainer
(16648, 9, 1), -- Zanien, Warlock Trainer
(16770, 9, 1), -- Exodar Warlock Trainer, Warlock Trainer
(23534, 9, 1), -- Babagaya Shadowcleft, Warlock Trainer
(26331, 9, 1), -- Warlock Trainer, 
(542, 11, 1), -- Califex of the Deep Wood, Druid Trainer
(1409, 11, 1), -- Moorah Stormhoof, Druid Trainer
(2217, 11, 1), -- Undead Druid Trainer, Druid Trainer
(3033, 11, 1), -- Turak Runetotem, Druid Trainer
(3034, 11, 1), -- Sheal Runetotem, Druid Trainer
(3036, 11, 1), -- Kym Wildmane, Druid Trainer
(3060, 11, 1), -- Gart Mistrunner, Druid Trainer
(3064, 11, 1), -- Gennia Runetotem, Druid Trainer
(3597, 11, 1), -- Mardant Strongoak, Druid Trainer
(3602, 11, 1), -- Kal, Druid Trainer
(4217, 11, 1), -- Mathrengyl Bearwalker, Druid Trainer
(4218, 11, 1), -- Denatharion, Druid Trainer
(4219, 11, 1), -- Fylerian Nightwing, Druid Trainer
(4985, 11, 1), -- World Druid Trainer, Druid Trainer
(5504, 11, 1), -- Sheldras Moontree, Druid Trainer
(5505, 11, 1), -- Theridran, Druid Trainer
(5506, 11, 1), -- Maldryn, Druid Trainer
(5963, 11, 1), -- World Tauren Male Druid Trainer, Druid Trainer
(5972, 11, 1), -- World Tauren Female Druid Trainer, Druid Trainer
(8142, 11, 1), -- Jannos Lighthoof, Druid Trainer
(9465, 11, 1), -- Golhine the Hooded, Druid Trainer
(12042, 11, 1), -- Loganaar, Druid Trainer
(16655, 11, 1), -- Harene Plainwalker, Druid Trainer
(16721, 11, 1), -- Shalannius, Druid Trainer
(26324, 11, 1); -- Druid Trainer, 

UPDATE `creature_template` SET `ScriptName` = 'av_classmaster_gossip'
WHERE `entry` IN (911, 912, 913, 914, 985, 1229, 1403, 1901, 2119, 2131, 3041, 3042, 3043, 3059, 3063, 3153, 3169, 3353, 3354, 3408, 3593, 3598, 4087, 4089, 4593, 4594, 4595, 4992, 5113, 5114, 5479, 5480, 5959, 5966, 5967, 7315, 8141, 10291, 16503, 16771, 17120, 17480, 17504, 26332, 925, 926, 927, 928, 1232, 4988, 5147, 5148, 5149, 5491, 5492, 8140, 15280, 16275, 16501, 16679, 16680, 16681, 16761, 17121, 17483, 17509, 20406, 23128, 26327, 35281, 895, 987, 1231, 1404, 2218, 3038, 3039, 3040, 3061, 3065, 3154, 3171, 3352, 3406, 3407, 3596, 3601, 3963, 4138, 4146, 4205, 4986, 5115, 5116, 5117, 5501, 5515, 5516, 5517, 8308, 10930, 15513, 16270, 16499, 16672, 16673, 16674, 16738, 17110, 17122, 17505, 26325, 915, 916, 917, 918, 1234, 1411, 2122, 2130, 3155, 3170, 3327, 3328, 3594, 3599, 4163, 4214, 4215, 4582, 4583, 4584, 4990, 5165, 5166, 5167, 5960, 5968, 13283, 15285, 16279, 16684, 16685, 16686, 16759, 26329, 375, 376, 377, 837, 1226, 2123, 2129, 3044, 3045, 3046, 3595, 3600, 3706, 3707, 4090, 4091, 4092, 4606, 4607, 4608, 4989, 5141, 5142, 5143, 5484, 5489, 5964, 5973, 6014, 6018, 11397, 11401, 11406, 15284, 16276, 16502, 16658, 16659, 16660, 16756, 17482, 17510, 17511, 19247, 26328, 373, 986, 1406, 2219, 3030, 3031, 3032, 3062, 3066, 3157, 3173, 3344, 3403, 4991, 5965, 5971, 13417, 16661, 17089, 17204, 17212, 17219, 17519, 17520, 18270, 20407, 23127, 26330, 198, 328, 944, 1228, 2124, 2128, 3047, 3048, 3049, 4566, 4567, 4568, 4987, 5144, 5145, 5146, 5497, 5498, 5880, 5882, 5883, 5884, 5885, 5961, 5969, 7311, 7312, 7488, 15279, 16269, 16500, 16651, 16652, 16653, 16749, 17105, 17481, 17513, 17514, 23103, 26326, 27704, 28956, 28958, 459, 460, 461, 906, 988, 1408, 2126, 2127, 3156, 3172, 3324, 3325, 3326, 4563, 4564, 4565, 4993, 5171, 5172, 5173, 5495, 5496, 5612, 5962, 5970, 15283, 16266, 16646, 16647, 16648, 16770, 23534, 26331, 542, 1409, 2217, 3033, 3034, 3036, 3060, 3064, 3597, 3602, 4217, 4218, 4219, 4985, 5504, 5505, 5506, 5963, 5972, 8142, 9465, 12042, 16655, 16721, 26324);

-- Template for adding another trainer (verify ScriptName is empty first,
-- per the warning above):
--   INSERT INTO `av_classmaster_trainer` (`creatureEntry`, `class`, `enabled`) VALUES (<entry>, <class>, 1);
--   UPDATE `creature_template` SET `ScriptName` = 'av_classmaster_gossip' WHERE `entry` = <entry>;
