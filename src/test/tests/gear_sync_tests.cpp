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

// XI: Forever Offline (gear sync): the arithmetic in map/utils/gear_sync.h. Spec: docs/design/ERA_AND_EXPANSIONS.md section 5
// in SirTanta/gambits-revamped (cases S1 and S2).

#include "map/utils/gear_sync.h"

#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <cstdlib>

namespace
{

using gear_sync::StockScaleKind;

// The stock scaler as written in battleutils.cpp before gear sync, kept here to compare against (see also
// gear_scaler_golden_tests.cpp, which pins the real function)
auto referenceStock(const StockScaleKind kind, const int amount, const int itemLevel) -> int
{
    int16_t modAmount = static_cast<int16_t>(amount);
    switch (kind)
    {
        case StockScaleKind::Rating:
            modAmount *= 3;
            modAmount /= 4;
            break;
        case StockScaleKind::HpMp:
            modAmount /= 2;
            break;
        case StockScaleKind::Stat:
            modAmount /= 3;
            break;
        case StockScaleKind::Zeroed:
            modAmount = 0;
            break;
    }
    return modAmount / itemLevel;
}

} // namespace

TEST_CASE("S1: a level 99 item at sync 75", "[gear_sync]")
{
    // STR+15 -> 15 * 75 / 99 = 11.36 -> 11
    REQUIRE(gear_sync::syncScale(15, 75, 99) == 11);
    // DEF 40 -> 30.3 -> 30
    REQUIRE(gear_sync::syncScale(40, 75, 99) == 30);
    // weapon damage 100 -> 75.7 -> 75
    REQUIRE(gear_sync::syncScale(100, 75, 99) == 75);
    // a mod that was positive never drops to 0
    REQUIRE(gear_sync::syncScale(1, 75, 99) == 1);
    REQUIRE(gear_sync::syncScale(2, 30, 99) == 1);
    // negative mods round toward zero and may reach 0
    REQUIRE(gear_sync::syncScale(-15, 75, 99) == -11);
    REQUIRE(gear_sync::syncScale(-1, 75, 99) == 0);
    // zero stays zero
    REQUIRE(gear_sync::syncScale(0, 75, 99) == 0);
    // the item counts as level 75
    REQUIRE(gear_sync::effectiveReqLevel(75, 99) == 75);
}

TEST_CASE("S1: a 16 bit amount at the largest sync ratio does not overflow", "[gear_sync]")
{
    REQUIRE(gear_sync::syncScale(32767, 98, 99) == 32436);
    REQUIRE(gear_sync::syncScale(-32768, 98, 99) == -32437);
}

TEST_CASE("S2: with the setting at 0 nothing changes", "[gear_sync]")
{
    const int levels[]  = { 1, 30, 50, 75, 99, 119, 255 };
    const int amounts[] = { -500, -15, -1, 0, 1, 15, 500 };

    for (const int itemLevel : levels)
    {
        CAPTURE(itemLevel);
        REQUIRE_FALSE(gear_sync::syncApplies(0, itemLevel));
        REQUIRE(gear_sync::effectiveReqLevel(0, itemLevel) == itemLevel);

        for (const int amount : amounts)
        {
            CAPTURE(amount);
            REQUIRE(gear_sync::syncScale(amount, 0, itemLevel) == amount);
        }
    }
}

TEST_CASE("S2: items at or below the sync level are not touched", "[gear_sync]")
{
    for (int itemLevel = 1; itemLevel <= 75; ++itemLevel)
    {
        CAPTURE(itemLevel);
        REQUIRE_FALSE(gear_sync::syncApplies(75, itemLevel));
        REQUIRE(gear_sync::effectiveReqLevel(75, itemLevel) == itemLevel);
        REQUIRE(gear_sync::syncScale(23, 75, itemLevel) == 23);
        REQUIRE(gear_sync::syncScale(-23, 75, itemLevel) == -23);
    }

    REQUIRE(gear_sync::syncApplies(75, 76));
}

TEST_CASE("S2: a sync level never raises an amount", "[gear_sync]")
{
    for (int syncLevel = 1; syncLevel <= 98; ++syncLevel)
    {
        for (int itemLevel = syncLevel + 1; itemLevel <= 99; ++itemLevel)
        {
            for (int amount = -40; amount <= 40; ++amount)
            {
                const auto scaled = gear_sync::syncScale(amount, syncLevel, itemLevel);
                REQUIRE(std::abs(scaled) <= std::abs(amount));
                REQUIRE(((scaled >= 0) == (amount >= 0) || scaled == 0));
                if (amount > 0)
                {
                    REQUIRE(scaled >= 1);
                }
            }
        }
    }
}

TEST_CASE("The stock scaler arithmetic is what it always was", "[gear_sync]")
{
    for (const auto kind : { StockScaleKind::Rating, StockScaleKind::HpMp, StockScaleKind::Stat, StockScaleKind::Zeroed })
    {
        for (int itemLevel = 1; itemLevel <= 99; ++itemLevel)
        {
            for (int amount = -600; amount <= 600; ++amount)
            {
                REQUIRE(gear_sync::stockScale(kind, amount, itemLevel) == referenceStock(kind, amount, itemLevel));
            }
        }
    }

    // a rating of 11000 wraps in 16 bits when multiplied by 3, as it did
    REQUIRE(gear_sync::stockScale(StockScaleKind::Rating, 11000, 99) == -82);
    // golden values: STR 30 on a level 1 item is 10, HP 120 on level 40 is 1, an unlisted mod is 0
    REQUIRE(gear_sync::stockScale(StockScaleKind::Stat, 30, 1) == 10);
    REQUIRE(gear_sync::stockScale(StockScaleKind::HpMp, 120, 40) == 1);
    REQUIRE(gear_sync::stockScale(StockScaleKind::Zeroed, 7, 1) == 0);
}

TEST_CASE("Sync rule first, then the stock scaler on the result", "[gear_sync]")
{
    // Level Sync to 30 with a level 99 item at sync 75: STR 90 -> 90 * 75 / 99 = 68, then the stock scaler as for an
    // item of level 75: 68 / 3 = 22, 22 / 75 = 0
    const auto synced = gear_sync::syncScale(90, 75, 99);
    REQUIRE(synced == 68);
    REQUIRE(gear_sync::stockScale(StockScaleKind::Stat, synced, 75) == 0);

    // a large rating survives longer: DEF 11000 -> 8333, x3 wraps in 16 bits, as the stock scaler does for such a value
    const auto defSynced = gear_sync::syncScale(11000, 75, 99);
    REQUIRE(defSynced == 8333);
    REQUIRE(gear_sync::stockScale(StockScaleKind::Rating, defSynced, 75) == referenceStock(StockScaleKind::Rating, defSynced, 75));
}
