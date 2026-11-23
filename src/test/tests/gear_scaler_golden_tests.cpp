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

// XI: Forever Offline (gear sync lane): golden values of the stock gear scaler, battleutils::GetScaledItemModifier.
//
// Written BEFORE the gear sync change and left unchanged by it. Each row is { mod, item amount, item level, character
// level, expected }. The expected values were computed from the stock arithmetic at v033a/integration ff6c1ca916
// (battleutils.cpp 6084-6139): below the item level, DEF and damage ratings x3/4 (in 16 bits), HP and MP /2, the main
// stats, ATT, RATT, ACC, RACC, MATT and MACC /3, every other mod 0, then everything / item level (integer division,
// toward zero). At or above the item level the item amount is returned as it is.
// The odd second division by the item level is stock behaviour. This test pins it; it does not endorse it.

#include "map/entities/char_entity.h"
#include "map/items/item_equipment.h"
#include "map/modifier.h"
#include "map/utils/battleutils.h"

#include <catch2/catch_test_macros.hpp>

#include <memory>

namespace
{

struct GoldenRow
{
    xi::Mod mod;
    int16   amount;
    uint8   itemLevel;
    uint8   charLevel;
    int32   expected;
};

const GoldenRow stockScalerGolden[] = {
    { xi::Mod::STR, 30, 75, 74, 0 },
    { xi::Mod::STR, 30, 75, 30, 0 },
    { xi::Mod::STR, 30, 99, 75, 0 },
    { xi::Mod::STR, 30, 40, 39, 0 },
    { xi::Mod::STR, 30, 10, 5, 1 },
    { xi::Mod::STR, 30, 2, 1, 5 },
    { xi::Mod::STR, 30, 75, 75, 30 },
    { xi::Mod::STR, 30, 40, 99, 30 },
    { xi::Mod::STR, 15, 75, 74, 0 },
    { xi::Mod::STR, 15, 75, 30, 0 },
    { xi::Mod::STR, 15, 99, 75, 0 },
    { xi::Mod::STR, 15, 40, 39, 0 },
    { xi::Mod::STR, 15, 10, 5, 0 },
    { xi::Mod::STR, 15, 2, 1, 2 },
    { xi::Mod::STR, 15, 75, 75, 15 },
    { xi::Mod::STR, 15, 40, 99, 15 },
    { xi::Mod::STR, -9, 75, 74, 0 },
    { xi::Mod::STR, -9, 75, 30, 0 },
    { xi::Mod::STR, -9, 99, 75, 0 },
    { xi::Mod::STR, -9, 40, 39, 0 },
    { xi::Mod::STR, -9, 10, 5, 0 },
    { xi::Mod::STR, -9, 2, 1, -1 },
    { xi::Mod::STR, -9, 75, 75, -9 },
    { xi::Mod::STR, -9, 40, 99, -9 },
    { xi::Mod::STR, 1, 75, 74, 0 },
    { xi::Mod::STR, 1, 75, 30, 0 },
    { xi::Mod::STR, 1, 99, 75, 0 },
    { xi::Mod::STR, 1, 40, 39, 0 },
    { xi::Mod::STR, 1, 10, 5, 0 },
    { xi::Mod::STR, 1, 2, 1, 0 },
    { xi::Mod::STR, 1, 75, 75, 1 },
    { xi::Mod::STR, 1, 40, 99, 1 },
    { xi::Mod::ATT, 45, 75, 74, 0 },
    { xi::Mod::ATT, 45, 75, 30, 0 },
    { xi::Mod::ATT, 45, 99, 75, 0 },
    { xi::Mod::ATT, 45, 40, 39, 0 },
    { xi::Mod::ATT, 45, 10, 5, 1 },
    { xi::Mod::ATT, 45, 2, 1, 7 },
    { xi::Mod::ATT, 45, 75, 75, 45 },
    { xi::Mod::ATT, 45, 40, 99, 45 },
    { xi::Mod::DEF, 40, 75, 74, 0 },
    { xi::Mod::DEF, 40, 75, 30, 0 },
    { xi::Mod::DEF, 40, 99, 75, 0 },
    { xi::Mod::DEF, 40, 40, 39, 0 },
    { xi::Mod::DEF, 40, 10, 5, 3 },
    { xi::Mod::DEF, 40, 2, 1, 15 },
    { xi::Mod::DEF, 40, 75, 75, 40 },
    { xi::Mod::DEF, 40, 40, 99, 40 },
    { xi::Mod::DEF, 11000, 75, 74, -108 },
    { xi::Mod::DEF, 11000, 75, 30, -108 },
    { xi::Mod::DEF, 11000, 99, 75, -82 },
    { xi::Mod::DEF, 11000, 40, 39, -203 },
    { xi::Mod::DEF, 11000, 10, 5, -813 },
    { xi::Mod::DEF, 11000, 2, 1, -4067 },
    { xi::Mod::DEF, 11000, 75, 75, 11000 },
    { xi::Mod::DEF, 11000, 40, 99, 11000 },
    { xi::Mod::MAIN_DMG_RATING, 12, 75, 74, 0 },
    { xi::Mod::MAIN_DMG_RATING, 12, 75, 30, 0 },
    { xi::Mod::MAIN_DMG_RATING, 12, 99, 75, 0 },
    { xi::Mod::MAIN_DMG_RATING, 12, 40, 39, 0 },
    { xi::Mod::MAIN_DMG_RATING, 12, 10, 5, 0 },
    { xi::Mod::MAIN_DMG_RATING, 12, 2, 1, 4 },
    { xi::Mod::MAIN_DMG_RATING, 12, 75, 75, 12 },
    { xi::Mod::MAIN_DMG_RATING, 12, 40, 99, 12 },
    { xi::Mod::HP, 120, 75, 74, 0 },
    { xi::Mod::HP, 120, 75, 30, 0 },
    { xi::Mod::HP, 120, 99, 75, 0 },
    { xi::Mod::HP, 120, 40, 39, 1 },
    { xi::Mod::HP, 120, 10, 5, 6 },
    { xi::Mod::HP, 120, 2, 1, 30 },
    { xi::Mod::HP, 120, 75, 75, 120 },
    { xi::Mod::HP, 120, 40, 99, 120 },
    { xi::Mod::HP, -50, 75, 74, 0 },
    { xi::Mod::HP, -50, 75, 30, 0 },
    { xi::Mod::HP, -50, 99, 75, 0 },
    { xi::Mod::HP, -50, 40, 39, 0 },
    { xi::Mod::HP, -50, 10, 5, -2 },
    { xi::Mod::HP, -50, 2, 1, -12 },
    { xi::Mod::HP, -50, 75, 75, -50 },
    { xi::Mod::HP, -50, 40, 99, -50 },
    { xi::Mod::MP, 90, 75, 74, 0 },
    { xi::Mod::MP, 90, 75, 30, 0 },
    { xi::Mod::MP, 90, 99, 75, 0 },
    { xi::Mod::MP, 90, 40, 39, 1 },
    { xi::Mod::MP, 90, 10, 5, 4 },
    { xi::Mod::MP, 90, 2, 1, 22 },
    { xi::Mod::MP, 90, 75, 75, 90 },
    { xi::Mod::MP, 90, 40, 99, 90 },
    { xi::Mod::TP_BONUS, 500, 75, 74, 0 },
    { xi::Mod::TP_BONUS, 500, 75, 30, 0 },
    { xi::Mod::TP_BONUS, 500, 99, 75, 0 },
    { xi::Mod::TP_BONUS, 500, 40, 39, 0 },
    { xi::Mod::TP_BONUS, 500, 10, 5, 0 },
    { xi::Mod::TP_BONUS, 500, 2, 1, 0 },
    { xi::Mod::TP_BONUS, 500, 75, 75, 500 },
    { xi::Mod::TP_BONUS, 500, 40, 99, 500 },
    { xi::Mod::AMMO_SWING, 7, 75, 74, 0 },
    { xi::Mod::AMMO_SWING, 7, 75, 30, 0 },
    { xi::Mod::AMMO_SWING, 7, 99, 75, 0 },
    { xi::Mod::AMMO_SWING, 7, 40, 39, 0 },
    { xi::Mod::AMMO_SWING, 7, 10, 5, 0 },
    { xi::Mod::AMMO_SWING, 7, 2, 1, 0 },
    { xi::Mod::AMMO_SWING, 7, 75, 75, 7 },
    { xi::Mod::AMMO_SWING, 7, 40, 99, 7 },
};

} // namespace

TEST_CASE("Stock gear scaler golden values", "[gear_scaler][golden]")
{
    for (const auto& row : stockScalerGolden)
    {
        CAPTURE(static_cast<int>(row.mod), row.amount, row.itemLevel, row.charLevel);

        auto PChar = std::make_unique<CCharEntity>();
        PChar->SetMLevel(row.charLevel);

        CItemEquipment item(0x4000);
        item.setReqLvl(row.itemLevel);
        item.addModifier(row.mod, row.amount);

        REQUIRE(battleutils::GetScaledItemModifier(PChar.get(), &item, row.mod) == row.expected);
    }
}

TEST_CASE("Stock gear scaler on delevel uses the previous level", "[gear_scaler][golden]")
{
    // A character who just dropped to level 75 is still treated as level 76 when the item is removed
    auto PChar = std::make_unique<CCharEntity>();
    PChar->SetMLevel(75);

    CItemEquipment item(0x4001);
    item.setReqLvl(76);
    item.addModifier(xi::Mod::HP, 120);

    // delevel: level 76, item 76: not scaled, the full amount comes back off
    REQUIRE(battleutils::GetScaledItemModifier(PChar.get(), &item, xi::Mod::HP, true) == 120);
    // not a delevel: level 75 is below 76: 120 / 2 / 76
    REQUIRE(battleutils::GetScaledItemModifier(PChar.get(), &item, xi::Mod::HP, false) == 0);
}
