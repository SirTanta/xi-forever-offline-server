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
-- the request: ask the mates, claim it, answer it
-----------------------------------
local function now()
    return os.time()
end

local function idOf(entity)
    local ok, id = pcall(function()
        return entity:getID()
    end)

    return ok and id or 0
end

-- the failure that explains most: not ready beats no target beats busy beats "I do not know that" (the same order as squad_logic.lua)
local RANK = { notready = 4, notarget = 3, busy = 2 }

local function rank(result)
    return RANK[result] or 1
end

local function report(player, mate, spellName, result)
    local handler = xi.squad.onSpellCommand
    if type(handler) == 'function' then
        local ok, err = pcall(handler, player, mate, spellName, result)
        if not ok then
            print('[squad_requests] onSpellCommand failed: ' .. tostring(err))
        end
    end
end

-- Lines of this file's own (squad.lua's voices have none for these events). Printed in party chat as the mate, like every Squads line.
R.LINES = R.LINES or {}
R.LINES.selfonly = {
    '{spell} only works on whoever casts it, I cannot put it on you.',
    'I cannot cast {spell} on you, it only takes the caster.',
}

R.LINES.noraise = {
    'Nobody is down, there is nobody to raise.',
    'You are standing and so is everyone else, no Raise needed.',
}

R.LINES.failed = {
    'That {spell} did not land.',
    '{spell} fizzled, it did not take. Ask again.',
}

-- 'cure_iv' -> 'Cure IV'
local function pretty(name)
    local text = tostring(name):gsub('_', ' ')
    text = text:gsub('(%a)([%w]*)', function(first, rest)
        local word = first .. rest
        if word:match('^[ivxIVX]+$') then
            return word:upper()
        end

        return first:upper() .. rest
    end)

    return text
end

local function say(player, mate, event, vars)
    local lines = R.LINES[event]
    if lines == nil or #lines == 0 then
        return
    end

    local text = lines[math.random(#lines)]
    text = text:gsub('{(%w+)}', function(key)
        return tostring((vars or {})[key] or '')
    end)

    pcall(function()
        player:printToPlayer(text, 4, mate:getPacketName())
    end)
end

-- what the spell can be cast on: 'enemy' | 'dead' | 'party' | 'self' | '' (the binding of the rebuilt squad.cpp is missing: leave the line to squad_logic.lua)
local function kindOf(spellId)
    local f = rawget(_G, 'SquadSpellKind')
    if type(f) ~= 'function' then
        return ''
    end

    local ok, kind = pcall(f, spellId)
    return ok and kind or ''
end

-----------------------------------
-- G16: typing the same line again does not cast again
-- A cast that was accepted keeps (spell, person) taken while it is being cast and a moment after. A repeat of the line
-- finds it taken and is ignored; before, a mate that was mid-cast answered "busy" and the NEXT mate cast the same spell on the same person. Attack spells are not claimed (casting "stone" again is a new nuke, and the recast already limits it).
-----------------------------------
R.CLAIM_PAD = 2 -- seconds after the cast time
R.claims = R.claims or {} -- [player id] = { ['spell:target'] = until }

-- the cast time of a spell in seconds (the server's spell table: milliseconds); 5 when it cannot be read
local function castSeconds(spellId)
    local ok, seconds = pcall(function()
        local ms = GetSpell(spellId):getCastTime()
        return ms > 100 and ms / 1000 or ms
    end)

    if ok and type(seconds) == 'number' and seconds > 0 then
        return math.min(seconds, 30)
    end

    return 5
end

local function claimKey(spellId, target)
    return tostring(spellId) .. ':' .. tostring(idOf(target))
end

function R.taken(player, spellId, target)
    local mine = R.claims[idOf(player)]
    local untilT = mine ~= nil and mine[claimKey(spellId, target)] or nil
    return untilT ~= nil and untilT > now()
end

function R.claim(player, spellId, target)
    local key = idOf(player)
    local mine = R.claims[key] or {}
    R.claims[key] = mine
    for k, untilT in pairs(mine) do
        if untilT <= now() then
            mine[k] = nil
        end
    end

    mine[claimKey(spellId, target)] = now() + castSeconds(spellId) + R.CLAIM_PAD
end

-----------------------------------
-- G5: the acknowledgement comes when the cast landed, and a cast that did not land is said so
-- Before, "On it: Sneak!" came the moment the engine accepted the cast; an interrupt, a mate that died or an out of range target ended in
-- silence after a cheerful line. For the spells that leave an effect on the target (Sneak, Invisible, Haste, Protect, ...) the mate now
-- answers when the effect is on, after the cast time. Not landed after that: one line saying so, and the claim of G16 is let go so asking again
-- works. Spells without a visible effect (Cure, Raise, attacks) are answered at accept, as before: nothing can be read to say more.
-----------------------------------
R.EFFECT = R.EFFECT or {
    sneak = 'SNEAK', invisible = 'INVISIBLE', deodorize = 'DEODORIZE', haste = 'HASTE', protect = 'PROTECT', shell = 'SHELL', blink = 'BLINK',
    stoneskin = 'STONESKIN', phalanx = 'PHALANX', regen = 'REGEN', refresh = 'REFRESH', aquaveil = 'AQUAVEIL',
}
R.LAND_TRIES = 3 -- looks at the target: one second after the cast time, then every two seconds

local function effectOf(spellName)
    local base = tostring(spellName):gsub('_[ivx]+$', '')
    local name = R.EFFECT[base]
    return name ~= nil and xi.effect ~= nil and xi.effect[name] or nil
end

function R.release(player, spellId, target)
    local mine = R.claims[idOf(player)]
    if mine ~= nil then
        mine[claimKey(spellId, target)] = nil
    end
end

function R.acknowledge(player, mate, spellName, spellId, target)
    local effect = effectOf(spellName)
    if effect == nil then
        report(player, mate, spellName, 'cast')
        return
    end

    local tries = 0
    local function look()
        tries = tries + 1
        local ok, landed = pcall(function()
            return target:hasStatusEffect(effect)
        end)

        if ok and landed then
            report(player, mate, spellName, 'cast')
        elseif tries < R.LAND_TRIES then
            mate:timer(2000, look)
        else
            R.release(player, spellId, target)
            say(player, mate, 'failed', { spell = pretty(spellName) })
        end
    end

    local ok = pcall(function()
        mate:timer(math.floor((castSeconds(spellId) + 1) * 1000), look)
    end)

    if not ok then
        report(player, mate, spellName, 'cast') -- no timer to wait with: answer now, as before
    end
end

-- G9: the first person of your party who is knocked out, in the same zone (a squad mate cannot be raised: it is called again)
local function firstFallen(player)
    local ok, party = pcall(function()
        return player:getPartyWithTrusts()
    end)

    for _, member in pairs(ok and party or {}) do
        local isPlayer = member:getObjType() == xi.objType.PC
        if isPlayer and member:isDead() and member:getZoneID() == player:getZoneID() then
            return member
        end
    end

    return nil
end

-----------------------------------
-- G1: one answerer between the squad mates and the bot players
-- The mates (squad.cpp, listed first in init.txt) and the bots (bots.cpp) read the same party chat line and used to know nothing of each
-- other: with a mate and a bot that both could Sneak you got two Sneaks and two "On it". A request a mate took is now marked here, and the
-- bots' own request code asks before it acts (bots.lua: xi.squad.requestTaken, xi.squad.lineTaken). If no mate can, the bots keep the line.
-----------------------------------
R.LINE_SECONDS = 6
R.lines = R.lines or {} -- [player id] = { text = 'normalised', untilT = time }

local function norm(text)
    return (tostring(text or ''):lower():gsub('[^%w]', ''))
end

function R.markLine(player, text)
    R.lines[idOf(player)] = { text = norm(text), untilT = now() + R.LINE_SECONDS }
end

function R.lineTaken(player, text)
    if not R.on(player) then
        return false
    end

    local line = R.lines[idOf(player)]
    return line ~= nil and line.untilT > now() and line.text == norm(text)
end

xi.squad.lineTaken = function(player, text)
    return R.lineTaken(player, text)
end

xi.squad.requestTaken = function(player, spellId, target)
    return R.on(player) and R.taken(player, spellId, target)
end

xi.squad.requestClaim = function(player, spellId, target)
    if R.on(player) then
        R.claim(player, spellId, target)
    end
end

-- squad_logic.lua hands a spell request over: the mates it asks (in order), "all", the spell, the named target (or nil = you).
-- Returns true when the request was answered here, false to let squad_logic.lua run the old loop.
function R.cast(player, askedMates, everyone, spellId, spellName, named, text)
    if not R.on(player) then
        return false
    end

    local kind = kindOf(spellId)
    if kind == '' then
        return false
    end

    -- G9: Raise goes on someone who is knocked out and on nobody else. "raise" with nobody named means the person who is down: you, else the first
    -- fallen member of the party. Before, "raise" while you stood and a friend lay dead was "nothing to cast on", and nobody was told why.
    if kind == 'dead' and named == nil and not player:isDead() then
        named = firstFallen(player)
        if named == nil then
            say(player, askedMates[1], 'noraise', {})
            R.markLine(player, text)
            return true
        end
    end

    local target = named or player

    -- G2: "all <spell>" for a spell that goes on a person (Sneak, Protect, Haste, Cure, Raise) is ONE cast on that person. Before, every mate
    -- that could cast it did, so "all protect" gave you Protect three times and three acknowledgements. "all" keeps its meaning for attack
    -- spells: every mate that can casts at the enemy.
    if everyone and kind ~= 'enemy' then
        everyone = false
    end

    -- G6: a spell that only works on its caster (Warp, Escape, Reraise, Utsusemi, Tonko) cannot be put on you. Before, "warp" was accepted (a false
    -- "On it") or answered with the misleading "nothing to cast on". One mate says what is true, once.
    if kind == 'self' and not (named ~= nil and #askedMates == 1 and askedMates[1] == named) then
        say(player, askedMates[1], 'selfonly', { spell = pretty(spellName) })
        R.markLine(player, text)
        return true
    end

    if kind ~= 'enemy' and R.taken(player, spellId, target) then
        print(string.format('[squad_requests] %s on %s is taken (a cast is on its way): the repeated line is ignored', spellName, tostring(target:getName())))
        R.markLine(player, text)
        return true
    end

    -- ask in order; one cast is enough unless "all" was said; nobody can: the most useful reason
    local anyCast, worstFailure, failureSpeaker = false, 'unknown', askedMates[1]
    for _, mate in ipairs(askedMates) do
        local result = SquadCastSpell(player, mate, spellId, named)
        if result == 'cast' then
            anyCast = true
            if kind ~= 'enemy' then
                R.claim(player, spellId, target)
            end

            R.markLine(player, text)
            R.acknowledge(player, mate, spellName, spellId, target)
            if not everyone then
                return true
            end
        elseif rank(result) > rank(worstFailure) then
            worstFailure, failureSpeaker = result, mate
        end
    end

    if not anyCast then
        report(player, failureSpeaker, spellName, worstFailure)
    end

    return true
end

-----------------------------------
-- !sqreq
-----------------------------------
local function tell(player, text)
    pcall(function()
        player:printToPlayer(text)
    end)
end

function R.status(player)
    tell(player, string.format('squad requests: fixes %s, extras %s', R.on(player) and 'ON' or 'OFF (!sqreq on)', R.more(player) and 'ON' or 'off (!sqreq more on)'))
end

function R.command(player, a, b)
    a, b = tostring(a or ''):lower(), tostring(b or ''):lower()
    if a == 'off' or a == 'on' then
        player:setCharVar('SQREQ_OFF', a == 'off' and 1 or 0)
    elseif a == 'more' and (b == 'on' or b == 'off') then
        player:setCharVar('SQREQ_MORE', b == 'on' and 1 or 0)
    elseif a ~= '' and a ~= 'status' then
        tell(player, '!sqreq | !sqreq off | !sqreq on | !sqreq more on | !sqreq more off')
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
