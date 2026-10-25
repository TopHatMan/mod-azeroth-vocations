/*
 * mod-azeroth-vocations: player and GM commands.
 * See docs/design/classmaster-gameplay-design.md §4 for the command list this
 * implements. Player commands are thin wrappers over the Core Vocation
 * Service's read-only API; GM commands write only to this module's own
 * av_classmaster_* tables -- never to av_core_* or characters-DB tables.
 */

#include "Chat.h"
#include "ClassMasterShared.h"
#include "CommandScript.h"
#include "CoreVocationService.h"
#include "DatabaseEnv.h"
#include "Player.h"

using namespace Acore::ChatCommands;
using namespace AzerothVocations;

namespace
{
bool HandleAvClassesCommand(ChatHandler* handler)
{
    Player* player = handler->GetPlayer();
    if (!player)
        return false;

    uint32 characterGuid = player->GetGUID().GetCounter();
    std::vector<ClassProfileSummary> profiles = sCoreVocationService->GetClassProfiles(characterGuid);

    handler->PSendSysMessage("Your current class: {} (level {}).", GetClassDisplayName(player->getClass()), player->GetLevel());

    if (profiles.empty())
    {
        handler->SendSysMessage("You have no other unlocked classes yet.");
    }
    else
    {
        for (ClassProfileSummary const& profile : profiles)
        {
            if (profile.classId == player->getClass())
                continue;

            ClassMasterRule rule = GetClassMasterRule(profile.classId);
            handler->PSendSysMessage("  {} -- saved at level {}{}", GetClassDisplayName(profile.classId), profile.level,
                (rule.found && !rule.available) ? " (currently unavailable)" : "");
        }
    }

    return true;
}

bool HandleAvArmoryCommand(ChatHandler* handler, Optional<std::string_view> classToken)
{
    Player* player = handler->GetPlayer();
    if (!player)
        return false;

    uint8 targetClass = player->getClass();
    if (classToken)
    {
        std::optional<uint8> parsed = ParseClassToken(*classToken);
        if (!parsed)
        {
            handler->PSendSysMessage("Unknown class '{}'.", *classToken);
            return false;
        }
        targetClass = *parsed;
    }

    std::vector<ArmoryItemSummary> items = sCoreVocationService->GetArmorySummary(player->GetGUID().GetCounter(), targetClass);
    if (items.empty())
    {
        handler->PSendSysMessage("Your {} Class Armory is empty.", GetClassDisplayName(targetClass));
        return true;
    }

    handler->PSendSysMessage("Your {} Class Armory holds {} item(s):", GetClassDisplayName(targetClass), items.size());
    for (ArmoryItemSummary const& item : items)
        handler->PSendSysMessage("  slot {} -- item entry {}", item.equipSlot, item.itemEntry);

    return true;
}

bool HandleClassMasterInspectCommand(ChatHandler* handler, PlayerIdentifier target, Optional<std::string_view> classToken)
{
    uint32 characterGuid = target.GetGUID().GetCounter();
    std::vector<ClassProfileSummary> profiles = sCoreVocationService->GetClassProfiles(characterGuid);

    handler->PSendSysMessage("Class profiles for {}:", target.GetName());
    if (profiles.empty())
    {
        handler->SendSysMessage("  (none -- this character has never switched class)");
    }
    else
    {
        for (ClassProfileSummary const& profile : profiles)
            handler->PSendSysMessage("  {} -- level {}, xp {}{}", GetClassDisplayName(profile.classId), profile.level, profile.xp,
                profile.isActive ? " (active)" : "");
    }

    if (!classToken)
        return true;

    std::optional<uint8> parsed = ParseClassToken(*classToken);
    if (!parsed)
    {
        handler->PSendSysMessage("Unknown class '{}'.", *classToken);
        return false;
    }

    std::vector<ArmoryItemSummary> items = sCoreVocationService->GetArmorySummary(characterGuid, *parsed);
    handler->PSendSysMessage("{} Class Armory: {} item(s) held.", GetClassDisplayName(*parsed), items.size());
    for (ArmoryItemSummary const& item : items)
        handler->PSendSysMessage("  slot {} -- item entry {}", item.equipSlot, item.itemEntry);

    return true;
}

bool HandleClassMasterSetAvailableCommand(ChatHandler* handler, std::string_view classToken, bool available)
{
    std::optional<uint8> classId = ParseClassToken(classToken);
    if (!classId)
    {
        handler->PSendSysMessage("Unknown class '{}'.", classToken);
        return false;
    }

    WorldDatabase.Execute(
        "INSERT INTO av_classmaster_class_rule (class, available) VALUES ({}, {}) "
        "ON DUPLICATE KEY UPDATE available = {}",
        *classId, uint32(available), uint32(available));

    handler->PSendSysMessage("{} is now {}.", GetClassDisplayName(*classId), available ? "available" : "unavailable");
    return true;
}

bool HandleClassMasterSetCostCommand(ChatHandler* handler, std::string_view classToken, uint32 copper)
{
    std::optional<uint8> classId = ParseClassToken(classToken);
    if (!classId)
    {
        handler->PSendSysMessage("Unknown class '{}'.", classToken);
        return false;
    }

    WorldDatabase.Execute(
        "INSERT INTO av_classmaster_class_rule (class, switchCost) VALUES ({}, {}) "
        "ON DUPLICATE KEY UPDATE switchCost = {}",
        *classId, copper, copper);

    handler->PSendSysMessage("{} switch cost is now {} copper.", GetClassDisplayName(*classId), copper);
    return true;
}

bool HandleClassMasterSetCooldownCommand(ChatHandler* handler, std::string_view classToken, uint32 seconds)
{
    std::optional<uint8> classId = ParseClassToken(classToken);
    if (!classId)
    {
        handler->PSendSysMessage("Unknown class '{}'.", classToken);
        return false;
    }

    WorldDatabase.Execute(
        "INSERT INTO av_classmaster_class_rule (class, cooldownSeconds) VALUES ({}, {}) "
        "ON DUPLICATE KEY UPDATE cooldownSeconds = {}",
        *classId, seconds, seconds);

    handler->PSendSysMessage("{} switch cooldown is now {} second(s).", GetClassDisplayName(*classId), seconds);
    return true;
}
} // namespace

class av_commandscript : public CommandScript
{
public:
    av_commandscript() : CommandScript("av_commandscript") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable avTable =
        {
            { "classes", HandleAvClassesCommand, SEC_PLAYER, Console::No },
            { "armory",  HandleAvArmoryCommand,  SEC_PLAYER, Console::No },
        };
        static ChatCommandTable commandTable =
        {
            { "av", avTable }
        };
        return commandTable;
    }
};

class classmaster_commandscript : public CommandScript
{
public:
    classmaster_commandscript() : CommandScript("classmaster_commandscript") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable classmasterTable =
        {
            { "inspect",      HandleClassMasterInspectCommand,      SEC_GAMEMASTER,    Console::Yes },
            { "setavailable", HandleClassMasterSetAvailableCommand, SEC_ADMINISTRATOR, Console::Yes },
            { "setcost",      HandleClassMasterSetCostCommand,      SEC_ADMINISTRATOR, Console::Yes },
            { "setcooldown",  HandleClassMasterSetCooldownCommand,  SEC_ADMINISTRATOR, Console::Yes },
        };
        static ChatCommandTable commandTable =
        {
            { "classmaster", classmasterTable }
        };
        return commandTable;
    }
};

void AddSC_av_commandscript()
{
    new av_commandscript();
    new classmaster_commandscript();
}
