/*
 * mod-azeroth-vocations: Class Master gossip flow.
 * See docs/design/classmaster-gameplay-design.md for the interaction spec this
 * implements. Talks to the Core Vocation Service (src/server/game/Vocations/
 * CoreVocationService.h) exclusively -- this file never touches characters,
 * character_spell/talent/glyphs/action/inventory, or item_instance directly.
 */

#include "ClassMasterShared.h"
#include "Config.h"
#include "CoreVocationService.h"
#include "Creature.h"
#include "CreatureScript.h"
#include "DatabaseEnv.h"
#include "Player.h"
#include "ScriptedGossip.h"
#include "ScriptMgr.h"
#include "SharedDefines.h"
#include "StringFormat.h"

using namespace AzerothVocations;

namespace
{
// npc_text row inserted by data/sql/db-world/mod_azeroth_vocations_world.sql --
// generic greeting used for every Class Master submenu this script sends.
constexpr uint32 AV_CLASSMASTER_NPC_TEXT_ID = 999900;

// Raw copper is unreadable once the new-class doubling curve climbs a few
// steps (e.g. 100000 << 6 = 6400000 copper) -- always show gold/silver/copper
// broken out instead of a bare copper count. Zero-value components are
// dropped except when the whole amount is 0.
std::string FormatMoney(uint32 copper)
{
    uint32 const gold = copper / GOLD;
    uint32 const silver = (copper % GOLD) / SILVER;
    uint32 const remainder = copper % SILVER;

    std::string out;
    if (gold)
        out += Acore::StringFormat("{} gold", gold);
    if (silver)
        out += Acore::StringFormat("{}{} silver", out.empty() ? "" : ", ", silver);
    if (remainder || out.empty())
        out += Acore::StringFormat("{}{} copper", out.empty() ? "" : ", ", remainder);
    return out;
}

// Cached at startup/reload (av_classmaster_gossip_config below), never read live
// from sConfigMgr in a gossip callback -- see .agents/docs/cpp-guidelines.md.
bool g_classmasterEnabled = false;
uint32 g_newClassBaseCost = 0;

enum AVClassMasterGossipAction : uint32
{
    AV_ACTION_OPEN_CLASS_MENU = GOSSIP_ACTION_INFO_DEF + 1,   // 1001
    AV_ACTION_CLOSE_INFO      = GOSSIP_ACTION_INFO_DEF + 2,   // 1002, dead-end info screens
    AV_ACTION_SHOW_EXPLAINER  = GOSSIP_ACTION_INFO_DEF + 3,   // 1003, "what is this?" -- info only, never touches a class
    AV_ACTION_CONFIRM_BASE    = GOSSIP_ACTION_INFO_DEF + 200, // 1200 + targetClass
};

char const* GetSwitchResultMessage(ClassSwitchResult result)
{
    switch (result)
    {
        case ClassSwitchResult::SUCCESS:                          return "Success.";
        case ClassSwitchResult::ERR_SERVICE_DISABLED:              return "Class switching is currently disabled.";
        case ClassSwitchResult::ERR_TARGET_CLASS_DISABLED:         return "That class is not available here.";
        case ClassSwitchResult::ERR_PLAYER_DEAD:                   return "You cannot do this while dead.";
        case ClassSwitchResult::ERR_PLAYER_IN_COMBAT:              return "You cannot do this while in combat.";
        case ClassSwitchResult::ERR_PLAYER_GROUPED:                return "You cannot do this while in a group.";
        case ClassSwitchResult::ERR_PLAYER_ON_TRANSPORT:           return "You cannot do this while on a transport.";
        case ClassSwitchResult::ERR_PLAYER_FLYING:                 return "You cannot do this while flying.";
        case ClassSwitchResult::ERR_PLAYER_IN_INSTANCE:            return "You cannot do this while inside a dungeon or battleground.";
        case ClassSwitchResult::ERR_UNSAFE_INVENTORY_STATE:        return "You cannot do this while trading.";
        case ClassSwitchResult::ERR_TARGET_PROFILE_CREATE_FAILED:  return "Something went wrong preparing that class. Please try again.";
        case ClassSwitchResult::ERR_DB_TRANSACTION_FAILED:         return "Something went wrong. Please try again.";
        case ClassSwitchResult::ERR_ALREADY_ACTIVE_CLASS:          return "You are already that class.";
        default:                                                  return "Unknown error.";
    }
}

struct ClassMasterTrainerRow
{
    uint8 offeredClass = 0;
    bool enabled = false;
};

ClassMasterTrainerRow GetTrainerRow(uint32 creatureEntry)
{
    ClassMasterTrainerRow row;
    if (QueryResult result = WorldDatabase.Query(
            "SELECT class, enabled FROM av_classmaster_trainer WHERE creatureEntry = {}", creatureEntry))
    {
        Field* fields = result->Fetch();
        row.offeredClass = fields[0].Get<uint8>();
        row.enabled = fields[1].Get<uint8>() != 0;
    }
    return row;
}

// Seconds remaining on cooldown, or 0 if none / already elapsed.
uint32 GetRemainingCooldown(uint32 characterGuid, uint32 cooldownSeconds)
{
    if (!cooldownSeconds)
        return 0;

    QueryResult result = CharacterDatabase.Query(
        "SELECT TIMESTAMPDIFF(SECOND, lastSwitchAt, NOW()) FROM av_classmaster_cooldown WHERE characterGuid = {}",
        characterGuid);
    if (!result)
        return 0;

    int64 elapsed = result->Fetch()[0].Get<int64>();
    if (elapsed < 0 || static_cast<uint64>(elapsed) >= cooldownSeconds)
        return 0;

    return cooldownSeconds - static_cast<uint32>(elapsed);
}

// How many distinct classes this character has ever unlocked (including
// whichever one is active right now). Every class the character has ever
// unlocked has a row in av_core_class_profile, EXCEPT the currently-active
// one if it has never once been archived (i.e. it's still the character's
// original creation-time class) -- see core-vocation-service-design.md §2a.
uint32 CountUnlockedClasses(Player* player)
{
    std::vector<ClassProfileSummary> profiles = sCoreVocationService->GetClassProfiles(player->GetGUID().GetCounter());

    bool currentClassTracked = false;
    for (ClassProfileSummary const& profile : profiles)
        if (profile.classId == player->getClass())
            currentClassTracked = true;

    return static_cast<uint32>(profiles.size()) + (currentClassTracked ? 0 : 1);
}

// Every character's original class is free -- becoming your 1st ever new
// class beyond that costs g_newClassBaseCost, doubling each additional new
// class after that (10g, 20g, 40g, 80g, ...). Pure gold sink, no level gate:
// the number of classes already unlocked is the only input. Re-switching
// back to a class you've already unlocked once is governed by
// ClassMasterRule::switchCost instead (see HandleConfirmSwitch) -- this cost
// only ever applies to a class you've never played on this character before.
uint32 GetNewClassCost(Player* player)
{
    // alreadyUnlocked is always >= 1 (your starting class), so this is
    // base*2^0 for your 1st new class, base*2^1 for your 2nd, etc.
    uint32 const alreadyUnlocked = CountUnlockedClasses(player);
    return g_newClassBaseCost << (alreadyUnlocked - 1);
}

void TouchCooldown(uint32 characterGuid)
{
    CharacterDatabase.Execute(
        "INSERT INTO av_classmaster_cooldown (characterGuid, lastSwitchAt) VALUES ({}, NOW()) "
        "ON DUPLICATE KEY UPDATE lastSwitchAt = NOW()",
        characterGuid);
}

void ShowInfoScreen(Player* player, Creature* creature, std::string const& text)
{
    ClearGossipMenuFor(player);
    AddGossipItemFor(player, GOSSIP_ICON_CHAT, text, GOSSIP_SENDER_MAIN, AV_ACTION_CLOSE_INFO);
    SendGossipMenuFor(player, AV_CLASSMASTER_NPC_TEXT_ID, creature);
}
} // namespace

class av_classmaster_gossip : public CreatureScript
{
public:
    av_classmaster_gossip() : CreatureScript("av_classmaster_gossip") { }

    bool OnGossipHello(Player* player, Creature* creature) override
    {
        if (!g_classmasterEnabled)
            return false;

        ClassMasterTrainerRow trainer = GetTrainerRow(creature->GetEntry());
        if (!trainer.enabled)
            return false;

        // Replicate the default gossip build exactly (NPCHandler.cpp's own
        // HandleGossipHelloOpcode path) so vendor/trainer/quest options this
        // NPC already has keep working unmodified; we only append our own
        // items on top.
        player->PrepareGossipMenu(creature, creature->GetGossipMenuId(), true);
        // Don't offer to become the class you already are -- e.g. a Rogue at
        // a Rogue trainer. HandleOpenClassMenu() also guards this (dead-end
        // "You are already a X" screen) for defense-in-depth, but suppressing
        // the option here means your own class's trainer behaves like an
        // ordinary trainer instead of showing a switch option that can only
        // ever dead-end.
        if (player->getClass() != trainer.offeredClass)
        {
            // Speech bubble: purely informational, never touches a class --
            // explains what Class Master does before anyone commits gold to it.
            AddGossipItemFor(player, GOSSIP_ICON_CHAT,
                "Tell me more about switching classes.", GOSSIP_SENDER_MAIN, AV_ACTION_SHOW_EXPLAINER);
            // Spellbook: the actual action -- opens the pay-and-confirm flow.
            AddGossipItemFor(player, GOSSIP_ICON_TRAINER, "Change my class.", GOSSIP_SENDER_MAIN, AV_ACTION_OPEN_CLASS_MENU);
        }
        player->SendPreparedGossip(creature);
        return true;
    }

    bool OnGossipSelect(Player* player, Creature* creature, uint32 sender, uint32 action) override
    {
        if (sender != GOSSIP_SENDER_MAIN)
            return false;

        if (action == AV_ACTION_CLOSE_INFO)
        {
            CloseGossipMenuFor(player);
            return true;
        }

        ClassMasterTrainerRow trainer = GetTrainerRow(creature->GetEntry());
        if (!trainer.enabled)
            return false;

        if (action == AV_ACTION_SHOW_EXPLAINER)
        {
            ShowInfoScreen(player, creature,
                "Class Master lets you set aside your current class and become another one. Your "
                "current class -- gear, spells, talents, glyphs, level, and XP -- is archived and "
                "waits for you here if you ever want it back. Becoming a class you've never played "
                "before on this character costs gold, and the price climbs the more classes you "
                "collect; switching back to one you've already unlocked once is free.");
            return true;
        }

        if (action == AV_ACTION_OPEN_CLASS_MENU)
        {
            HandleOpenClassMenu(player, creature, trainer.offeredClass);
            return true;
        }

        if (action >= AV_ACTION_CONFIRM_BASE && action < AV_ACTION_CONFIRM_BASE + MAX_CLASSES)
        {
            uint8 targetClass = static_cast<uint8>(action - AV_ACTION_CONFIRM_BASE);
            // Defensive: only ever confirm the one class this specific
            // trainer actually offers, regardless of what action value came
            // back over the wire.
            if (targetClass != trainer.offeredClass)
            {
                CloseGossipMenuFor(player);
                return true;
            }
            HandleConfirmSwitch(player, creature, targetClass);
            return true;
        }

        return false;
    }

private:
    void HandleOpenClassMenu(Player* player, Creature* creature, uint8 offeredClass)
    {
        ClassMasterRule rule = GetClassMasterRule(offeredClass);
        if (!rule.found || !rule.available)
        {
            ShowInfoScreen(player, creature, "That class is not available here.");
            return;
        }

        if (player->getClass() == offeredClass)
        {
            ShowInfoScreen(player, creature, Acore::StringFormat("You are already a {}.", GetClassDisplayName(offeredClass)));
            return;
        }

        if (uint32 remaining = GetRemainingCooldown(player->GetGUID().GetCounter(), rule.cooldownSeconds))
        {
            ShowInfoScreen(player, creature,
                Acore::StringFormat("You must wait {} more second(s) before switching class again.", remaining));
            return;
        }

        bool hasProfile = sCoreVocationService->HasClassProfile(player->GetGUID().GetCounter(), offeredClass);

        std::string body;
        uint32 cost;
        if (hasProfile)
        {
            std::vector<ClassProfileSummary> profiles = sCoreVocationService->GetClassProfiles(player->GetGUID().GetCounter());
            uint8 savedLevel = 1;
            for (ClassProfileSummary const& profile : profiles)
                if (profile.classId == offeredClass)
                    savedLevel = profile.level;

            size_t armoryCount = sCoreVocationService->GetArmorySummary(player->GetGUID().GetCounter(), offeredClass).size();
            body = Acore::StringFormat(
                "Become a {} again? You will resume at level {}, with {} item(s) waiting in your Class Armory.",
                GetClassDisplayName(offeredClass), savedLevel, armoryCount);
            cost = rule.switchCost;
        }
        else
        {
            cost = GetNewClassCost(player);
            body = Acore::StringFormat(
                "Become a {} for the first time? You will start over at level 1 as this class. This is a "
                "new calling for you -- the price climbs each time you pick up another one.",
                GetClassDisplayName(offeredClass));
        }

        if (cost)
            body += Acore::StringFormat(" |cffff4040This will cost you {}.|r Confirming below spends the money immediately.",
                FormatMoney(cost));

        ClearGossipMenuFor(player);
        AddGossipItemFor(player, GOSSIP_ICON_CHAT, body, GOSSIP_SENDER_MAIN, AV_ACTION_CLOSE_INFO);
        AddGossipItemFor(player, GOSSIP_ICON_TRAINER,
            cost
                ? Acore::StringFormat("Yes, pay {} and become a {}.", FormatMoney(cost), GetClassDisplayName(offeredClass))
                : Acore::StringFormat("Yes, become a {}.", GetClassDisplayName(offeredClass)),
            GOSSIP_SENDER_MAIN, AV_ACTION_CONFIRM_BASE + offeredClass);
        SendGossipMenuFor(player, AV_CLASSMASTER_NPC_TEXT_ID, creature);
    }

    void HandleConfirmSwitch(Player* player, Creature* creature, uint8 targetClass)
    {
        ClassMasterRule rule = GetClassMasterRule(targetClass);
        if (!rule.found || !rule.available)
        {
            ShowInfoScreen(player, creature, "That class is not available here.");
            return;
        }

        // Check first, charge second (design doc's recommended ordering --
        // avoids needing a refund path for the common-case rejections).
        ClassSwitchResult precheck = sCoreVocationService->CanSwitchClass(player, targetClass);
        if (precheck != ClassSwitchResult::SUCCESS)
        {
            ShowInfoScreen(player, creature, GetSwitchResultMessage(precheck));
            return;
        }

        uint32 characterGuid = player->GetGUID().GetCounter();
        // Read hasProfile BEFORE CreateLevelOneClassProfile() below can change
        // it -- this is what decides whether this is a paid new-class unlock
        // or a free re-switch, so it has to reflect the state the player was
        // actually quoted a price against.
        bool const hasProfile = sCoreVocationService->HasClassProfile(characterGuid, targetClass);
        uint32 const cost = hasProfile ? rule.switchCost : GetNewClassCost(player);

        if (cost && !player->HasEnoughMoney(cost))
        {
            ShowInfoScreen(player, creature, "You do not have enough money.");
            return;
        }

        if (cost)
            player->ModifyMoney(-static_cast<int32>(cost));

        ClassSwitchResult result = sCoreVocationService->SwitchClass(player, targetClass, "player");
        if (result != ClassSwitchResult::SUCCESS)
        {
            if (cost)
                player->ModifyMoney(static_cast<int32>(cost));
            ShowInfoScreen(player, creature, GetSwitchResultMessage(result));
            return;
        }

        TouchCooldown(characterGuid);
        // SwitchClass() already logged the player out (save=false, by design --
        // see CoreVocationService.cpp) so there is no gossip session left to
        // close here.
    }
};

class av_classmaster_gossip_config : public WorldScript
{
public:
    av_classmaster_gossip_config() : WorldScript("av_classmaster_gossip_config", {
        WORLDHOOK_ON_AFTER_CONFIG_LOAD
    }) { }

    void OnAfterConfigLoad(bool /*reload*/) override
    {
        g_classmasterEnabled = sConfigMgr->GetOption<bool>("AzerothVocations.Enable", false);
        g_newClassBaseCost = sConfigMgr->GetOption<uint32>("AzerothVocations.NewClassBaseCost", 100000);
    }
};

void AddSC_av_classmaster_gossip()
{
    new av_classmaster_gossip();
    new av_classmaster_gossip_config();
}
