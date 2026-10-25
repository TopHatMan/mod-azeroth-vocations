/*
 * mod-azeroth-vocations: small utilities shared between the Class Master
 * gossip flow (ClassMasterGossip.cpp) and the Class Master commands
 * (ClassMasterCommands.cpp). Module-owned, reads av_classmaster_class_rule
 * only -- never touches av_core_* or characters-DB tables. See
 * docs/design/classmaster-gameplay-design.md.
 */

#ifndef AV_CLASS_MASTER_SHARED_H
#define AV_CLASS_MASTER_SHARED_H

#include "DatabaseEnv.h"
#include "Define.h"
#include "QueryResult.h"
#include "SharedDefines.h"
#include "StringConvert.h"
#include <algorithm>
#include <cctype>
#include <cstring>
#include <optional>
#include <string_view>

namespace AzerothVocations
{
// Not named GetClassName: that collides with the WinAPI macro of the same
// name (GetClassName -> GetClassNameA/W via <windows.h>) on MSVC builds,
// which silently mangles every call site into the wrong function.
inline char const* GetClassDisplayName(uint8 classId)
{
    switch (classId)
    {
        case CLASS_WARRIOR:      return "Warrior";
        case CLASS_PALADIN:      return "Paladin";
        case CLASS_HUNTER:       return "Hunter";
        case CLASS_ROGUE:        return "Rogue";
        case CLASS_PRIEST:       return "Priest";
        case CLASS_DEATH_KNIGHT: return "Death Knight";
        case CLASS_SHAMAN:       return "Shaman";
        case CLASS_MAGE:         return "Mage";
        case CLASS_WARLOCK:      return "Warlock";
        case CLASS_DRUID:        return "Druid";
        default:                 return "Unknown";
    }
}

// Accepts either a numeric class id ("8") or a class name ("mage"), case
// insensitive. Returns nullopt for anything that isn't a real player class.
inline std::optional<uint8> ParseClassToken(std::string_view token)
{
    if (std::optional<uint8> asNumber = Acore::StringTo<uint8>(token))
        if (*asNumber >= 1 && *asNumber < MAX_CLASSES && *asNumber != 10)
            return *asNumber;

    for (uint8 classId = 1; classId < MAX_CLASSES; ++classId)
    {
        if (classId == 10) // unused class id, see SharedDefines.h
            continue;

        char const* name = GetClassDisplayName(classId);
        if (token.size() == strlen(name) &&
            std::equal(token.begin(), token.end(), name, [](char a, char b) { return std::tolower(a) == std::tolower(b); }))
            return classId;
    }

    return std::nullopt;
}

struct ClassMasterRule
{
    bool found = false;
    bool available = false;
    uint32 switchCost = 0;
    uint32 cooldownSeconds = 0;
};

inline ClassMasterRule GetClassMasterRule(uint8 classId)
{
    ClassMasterRule rule;
    if (QueryResult result = WorldDatabase.Query(
            "SELECT available, switchCost, cooldownSeconds FROM av_classmaster_class_rule WHERE class = {}", classId))
    {
        Field* fields = result->Fetch();
        rule.found = true;
        rule.available = fields[0].Get<uint8>() != 0;
        rule.switchCost = fields[1].Get<uint32>();
        rule.cooldownSeconds = fields[2].Get<uint32>();
    }
    return rule;
}
} // namespace AzerothVocations

#endif // AV_CLASS_MASTER_SHARED_H
