-----------------------------------
-- Squad requests (XI Forever v0.3.3): what happens after a party chat line like "sneak", "all haste" or "poppelle cure me" was read.
--
-- squad_logic.lua (the thin chat layer) reads the words and asks this file at two points:
--   SQUAD_REQ.mayAnswer(player, mate)   may this mate answer a chat order at all?
--   SQUAD_REQ.cast(...)                 the asking, claiming and answering of one spell request
-- Everything here is a fix of something the party chat did wrong (docs: PARTY_REQUESTS_AUDIT, items G1 to G20), each one in its own
-- section below, and each one is switched off by one setting, so a player who wants the exact v0.3.2 behavior has it:
--
--   !sqreq              what is on
--   !sqreq off | on     all of the fixes (character variable SQREQ_OFF, default: on)
--   !sqreq more on|off  the extras that change what a line means: looser words, groups, best spell, ... (SQREQ_MORE, default: off)
--
-- With the fixes off, or with this file removed from init.txt, squad_logic.lua does exactly what it did before.
-- Hot reloadable (tools/squads/hot_reload). Load order: after squad_logic.lua.
-----------------------------------
require('modules/module_utils')

xi = xi or {}
xi.squad = xi.squad or {}

SQUAD_REQ = SQUAD_REQ or {}
local R = SQUAD_REQ

R.version = 1

-----------------------------------
-- settings
-----------------------------------
local function charVar(player, name)
    local ok, value = pcall(function()
        return player:getCharVar(name)
    end)

    if ok and type(value) == 'number' then
        return value
    end

    return 0
end

-- the fixes are on unless the player turned them off
function R.on(player)
    return charVar(player, 'SQREQ_OFF') ~= 1
end

-- the extras that change what a line means are on only when the player asked
function R.more(player)
    return R.on(player) and charVar(player, 'SQREQ_MORE') == 1
end

-----------------------------------
-- G15: a mate that is stopped does not answer chat orders
-- "!idle on" (squad_idle.lua) and Actions OFF (squad_actions.lua) set SQUAD_IDLE: that mate does nothing until you let it. A mate that
-- another system owns (GAMBITS_OWNED, set by Gambits Revamped) acts through that system's own lines, not through a chat order.
-----------------------------------
function R.mayAnswer(player, mate)
    if not R.on(player) then
        return true
    end

    local ok, idle, owned = pcall(function()
        return mate:getLocalVar('SQUAD_IDLE'), mate:getLocalVar('GAMBITS_OWNED')
    end)

    if ok and ((idle or 0) ~= 0 or (owned or 0) ~= 0) then
        return false
    end

    return true
end

-----------------------------------
-- !sqreq
-----------------------------------
local function say(player, text)
    pcall(function()
        player:printToPlayer(text)
    end)
end

function R.status(player)
    say(player, string.format('squad requests: fixes %s, extras %s', R.on(player) and 'ON' or 'OFF (!sqreq on)', R.more(player) and 'ON' or 'off (!sqreq more on)'))
end

function R.command(player, a, b)
    a, b = tostring(a or ''):lower(), tostring(b or ''):lower()
    if a == 'off' or a == 'on' then
        player:setCharVar('SQREQ_OFF', a == 'off' and 1 or 0)
    elseif a == 'more' and (b == 'on' or b == 'off') then
        player:setCharVar('SQREQ_MORE', b == 'on' and 1 or 0)
    elseif a ~= '' and a ~= 'status' then
        say(player, '!sqreq | !sqreq off | !sqreq on | !sqreq more on | !sqreq more off')
    end

    R.status(player)
end

if xi.module ~= nil and xi.module.registerCommand ~= nil then
    xi.module.registerCommand('sqreq', {
        cmdprops = { permission = 0, parameters = 'ss' },
        onTrigger = function(player, a, b)
            R.command(player, a, b)
        end,
    })
end

return R
