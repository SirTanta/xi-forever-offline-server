/*
===========================================================================

  Copyright (c) 2026 LandSandBoat Dev Teams

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see http://www.gnu.org/licenses/

===========================================================================
*/

#pragma once

#include <cstdint>

// XI: Forever Offline (gear sync, docs/design/ERA_AND_EXPANSIONS.md section 5 in SirTanta/gambits-revamped).
//
// The arithmetic of gear sync and of the stock gear scaler, free of engine types so it can be unit tested on its own
// (src/test/tests/gear_sync_tests.cpp, gear_scaler_golden_tests.cpp).
//
// map.GEAR_SYNC_LEVEL (default 0 = off, stock behaviour) lets a character or squad mate wear gear above the level of the
// era the world is in. For an item whose required level is above the sync level:
//   - it can be equipped as if its required level were the sync level
//   - every numeric mod, DEF and weapon damage are scaled by sync level / item level (toward zero, never below 1 for a
//     positive mod); delay is not touched; item level (ilvl) bonuses count as 0
//   - latents and the weapon hit count use the sync level as the required level
// Items at or below the sync level are not touched. With the setting at 0 nothing here changes any value.
namespace gear_sync
{

// How the stock scaler treats a mod when the wearer is below the item level
enum class StockScaleKind : uint8_t
{
    Rating, // DEF, damage ratings: x3/4
    HpMp,   // HP, MP: /2
    Stat,   // main stats, ATT, RATT, ACC, RACC, MATT, MACC: /3
    Zeroed  // everything else: 0
};

// True when the sync rule applies to an item: a sync level is set and the item is above it
constexpr auto syncApplies(const int syncLevel, const int itemLevel) -> bool
{
    return syncLevel > 0 && itemLevel > syncLevel;
}

// The level the item counts as for equip checks, latents and the hit count
constexpr auto effectiveReqLevel(const int syncLevel, const int itemLevel) -> int
{
    return syncApplies(syncLevel, itemLevel) ? syncLevel : itemLevel;
}

// amount x syncLevel / itemLevel, rounded toward zero, with at least 1 left for a positive amount.
// An item the rule does not apply to keeps its amount.
constexpr auto syncScale(const int amount, const int syncLevel, const int itemLevel) -> int
{
    if (!syncApplies(syncLevel, itemLevel))
    {
        return amount;
    }

    // 64 bits: a 16 bit amount times a level cannot overflow 32, but the product is cheap insurance
    const auto scaled = static_cast<int>(static_cast<int64_t>(amount) * syncLevel / itemLevel);
    if (amount > 0 && scaled < 1)
    {
        return 1;
    }
    return scaled;
}

// The stock scaler (battleutils::GetScaledItemModifier) for a wearer below the item level, exactly as it has always been:
// the item amount is a 16 bit value and the x3 of a rating wraps in 16 bits; the result is divided by the item level
// once more at the end.
constexpr auto stockScale(const StockScaleKind kind, const int amount, const int itemLevel) -> int
{
    auto value = static_cast<int16_t>(amount);

    switch (kind)
    {
        case StockScaleKind::Rating:
            value = static_cast<int16_t>(value * 3);
            value = static_cast<int16_t>(value / 4);
            break;
        case StockScaleKind::HpMp:
            value = static_cast<int16_t>(value / 2);
            break;
        case StockScaleKind::Stat:
            value = static_cast<int16_t>(value / 3);
            break;
        case StockScaleKind::Zeroed:
            value = 0;
            break;
    }

    return value / itemLevel;
}

} // namespace gear_sync
