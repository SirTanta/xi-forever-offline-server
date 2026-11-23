-----------------------------------
-- br_lod.lua : EXPERIMENTAL level-of-detail for bot players (Bots Revamped prototype, perf/bots-smoothness).
-- Core rule (Jon): distance from a real player is the only thing that matters. A bot is a real, rendered, walking character only
-- while a real player is within RANGE yalms, or a player zones in. Everywhere else it is a light record (where, doing what).
--   collapse     : a bot far from every real player for HYST s is logged out (BotLogout persists it) and kept as a record
--   hover        : a record moves between the zone's spots on a schedule (no walking, no packets, no aggro)
--   materialize  : a player comes within RANGE: BotPlace at the record position, BotLogin (at most MAXMAT per second)
-- Uses only bindings that already exist (BotPlace, BotLogin, BotLogout). Off unless SM_LOD=<range yalms> is set. Also here, off by
-- default: SM_BLCACHE (BotList cached per second, invalidated on login/logout/create) and SM_PROF (Lua time counters).
-- Records: see MATERIALIZE notes at the bottom (activity model, fight HP estimate); the engine side of a fight is mocked in tests.
-----------------------------------
local ffi = require('ffi')
pcall(ffi.cdef, 'int QueryPerformanceCounter(int64_t*); int QueryPerformanceFrequency(int64_t*);')
local f, c = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
ffi.C.QueryPerformanceFrequency(f)
local freq = tonumber(f[0])
local function qpc()
    ffi.C.QueryPerformanceCounter(c)
    return tonumber(c[0]) * 1000 / freq
end

xi = xi or {}
xi.lod = xi.lod or {}
local M = xi.lod
-- FINALFORM
M.qpc = qpc
M.prof = { think_ms = 0, think_n = 0, onTick_ms = 0, onTick_n = 0, lod_ms = 0, lod_n = 0 }
M.stats = { collapses = 0, materializes = 0, mat_ms = 0, mat_max = 0, hops = 0, skipped_busy = 0 }
M.active = true
M.dormant = {}   -- [bot id] = record
M.live = {}      -- [bot id] = true (online, rendered)

-- settings: modules/custom/lua/bots_config.lua keys (lod_range, lod_hysteresis_s, lod_max_materialize, idle_think_ms, zone_snapshot, botlist_cache), each also readable
-- from an environment variable of the bench (SM_LOD, SM_LOD_HYST, SM_LOD_MAXMAT, SM_IDLE, SM_SNAP, SM_BLCACHE). Nothing is on unless asked for.
local CFG = {}
do
    local ok, c = pcall(require, 'modules/custom/lua/bots_config')
    if ok and type(c) == 'table' then
        CFG = c
    end
end

local function opt(key, env)
    local v = CFG[key]
    if v == nil then
        v = os.getenv(env)
    end

    return v
end

M.opt = opt

local RANGE = tonumber(opt('lod_range', 'SM_LOD') or '')
local HYST = tonumber(opt('lod_hysteresis_s', 'SM_LOD_HYST') or '10')
local MAXMAT = tonumber(opt('lod_max_materialize', 'SM_LOD_MAXMAT') or '2')
local MARGIN = 1.15
local blCache = opt('botlist_cache', 'SM_BLCACHE')

local count = os.getenv('SM_COUNT')
if not (RANGE or blCache or count or os.getenv('SM_PROF')) then
    return M -- nothing asked for: no wrappers, no hooks (the baseline runs on the stock paths)
end

M.calls = {}

-- BotList cache -----------------------------------------------------------------------------------------------------
local function rawBotList(...) return _G.BotList(...) end
local function rawLogin(...) return _G.BotLogin(...) end
local function rawLogout(...) return _G.BotLogout(...) end
local function rawCreate(...) return _G.BotCreate(...) end
local cache, cacheT = nil, -1
local function invalidate()
    cache = nil
end

M.BotList = function(...)
    local l
    if blCache then
        local t = os.time()
        if cache and cacheT == t then
            l = cache
        else
            l = rawBotList(...)
            cache, cacheT = l, t
        end
    else
        l = rawBotList(...)
    end

    -- a dormant bot is "online" for the roster (the life module counts it toward the target and ends its session on time)
    for id, rec in pairs(M.dormant) do
        local row = l[id]
        if row then
            row.online = true
            row.zone = rec.zone
        end
    end

    return l
end

M.BotLogin = function(id, ...)
    invalidate()
    M.dormant[id] = nil
    local ok, msg = rawLogin(id, ...)
    if ok then
        M.live[id] = true
    end

    return ok, msg
end

M.BotLogout = function(id, ...)
    invalidate()
    M.dormant[id] = nil
    M.live[id] = nil
    return rawLogout(id, ...)
end

M.BotCreate = function(...)
    invalidate()
    return rawCreate(...)
end

-- LOD ---------------------------------------------------------------------------------------------------------------
local function realPlayers(zoneId, cacheZ)
    local list = cacheZ[zoneId]
    if list then
        return list
    end

    list = {}
    local zone = GetZone and GetZone(zoneId)
    if zone then
        for _, p in ipairs(zone:getPlayers()) do
            if not BotIsBot(p:getID()) then
                local pos = p:getPos()
                list[#list + 1] = { x = pos.x, z = pos.z }
            end
        end
    end

    cacheZ[zoneId] = list
    return list
end

local function nearest(list, x, z)
    local best = math.huge
    for _, p in ipairs(list) do
        local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
        if d < best then
            best = d
        end
    end

    return math.sqrt(best)
end

local function hop(rec, t)
    local spots = xi.crowds and xi.crowds.zoneSpots and xi.crowds.zoneSpots(rec.zone)
    if spots and #spots > 0 then
        local s = spots[math.random(1, #spots)]
        rec.x, rec.y, rec.z, rec.rot = s.x + (math.random() - 0.5) * 1.5, s.y, s.z + (math.random() - 0.5) * 1.5, s.rot or 0
        M.stats.hops = M.stats.hops + 1
    end

    rec.nextHop = t + math.random(30, 120)
end

-- the engine side: log a bot back in at its record position. Returns the cost in ms.
function M.materialize(id, rec)
    local a = qpc()
    BotPlace(id, rec.zone, rec.x, rec.y, rec.z, rec.rot or 0)
    local ok = M.BotLogin(id)
    local ms = qpc() - a
    M.stats.materializes = M.stats.materializes + 1
    if os.getenv('SM_LODLOG') then print(string.format('[lod] t=%d MAT id=%d ok=%s zone=%d x=%.1f z=%.1f ms=%.2f', os.time(), id, tostring(ok), rec.zone, rec.x, rec.z, ms)) end
    M.stats.mat_ms = M.stats.mat_ms + ms
    if ms > M.stats.mat_max then
        M.stats.mat_max = ms
    end

    return ok, ms
end

local function eligible(e)
    if not e or not e:isAlive() or e:isEngaged() then
        return false
    end

    if e:getPartySize() > 1 then
        return false
    end

    return true
end

function M.tick()
    if not RANGE then
        return
    end

    local a = qpc()
    local t = os.time()
    local zc = {}
    -- collapse
    for id in pairs(M.live) do
        local e = GetPlayerByID(id)
        if not e then
            M.live[id] = nil
        else
            local zid = e:getZoneID()
            local list = realPlayers(zid, zc)
            local pos = e:getPos()
            local d = #list > 0 and nearest(list, pos.x, pos.z) or math.huge
            local rec = M.dormant[id]
            if d > RANGE * MARGIN then
                M.farSince = M.farSince or {}
                M.farSince[id] = M.farSince[id] or t
                if t - M.farSince[id] >= HYST then
                    if eligible(e) then
                        local r = { zone = zid, x = pos.x, y = pos.y, z = pos.z, rot = pos.rot or 0, since = t, nextHop = t + math.random(30, 120) }
                        M.farSince[id] = nil
                        M.live[id] = nil
                        invalidate()
                        rawLogout(id)
                        M.dormant[id] = r
                        M.stats.collapses = M.stats.collapses + 1
                        if os.getenv('SM_LODLOG') then print(string.format('[lod] t=%d COL id=%d d=%.1f x=%.1f z=%.1f', t, id, d, pos.x, pos.z)) end
                    else
                        M.stats.skipped_busy = M.stats.skipped_busy + 1
                    end
                end
            elseif M.farSince then
                M.farSince[id] = nil
            end
        end
    end

    -- hover and materialize
    local nmat = 0
    for id, rec in pairs(M.dormant) do
        if t >= rec.nextHop then
            hop(rec, t)
        end

        if nmat < MAXMAT then
            local list = realPlayers(rec.zone, zc)
            if #list > 0 and nearest(list, rec.x, rec.z) < RANGE then
                nmat = nmat + 1
                M.materialize(id, rec)
            end
        end
    end

    M.prof.lod_ms = M.prof.lod_ms + (qpc() - a)
    M.prof.lod_n = M.prof.lod_n + 1
end

-- hook the 1 Hz global tick (bots.lua defines xi.bots.onTick; this module loads after it)
if xi.bots and xi.bots.onTick then
    local orig = xi.bots.onTick
    xi.bots.onTick = function(...)
        local a = qpc()
        local r = orig(...)
        M.prof.onTick_ms = M.prof.onTick_ms + (qpc() - a)
        M.prof.onTick_n = M.prof.onTick_n + 1
        M.tick()
        return r
    end
end

-----------------------------------
-- MATERIALIZE: the activity record (data model). A record is { zone, x, y, z, rot, level, job, party, act = {...} } and act is one of
--   { kind = 'town',   spot = i }                            standing at a spot (the hover above)
--   { kind = 'rest' }                                         healing: HP and MP below full, rising with time
--   { kind = 'travel', from = A, to = B, t0 = T, speed = v }  position = A + (B - A) * clamp((now - T) * v / |B - A|)
--   { kind = 'fight',  mob = { pool, level, maxhp }, camp = S, since = T, claimed_by = id|partyId }
-- Turning a fight record into entities (M.fight_state is pure and mocked in tests/realtest/smooth/lod_mock.lua):
--   elapsed = now - since; dps = f(level, job, gear) ; hpLost = min(0.95 * maxhp, dps * elapsed) ; the bot gets engaged status, TP from elapsed
--   swings, MP/HP from its regen model; the mob is spawned (or reused) at the camp spot with maxhp - hpLost and claimed by the bot (or party).
-- On collapse the live fight folds back: act = fight with since = start, mob hp known; if no player is near when the abstract fight would have
-- ended (elapsed >= maxhp / dps) it resolves: exp added, act = travel to the next camp.
-----------------------------------
function M.fight_state(rec, now)
    local act = rec.act
    local elapsed = math.max(0, now - act.since)
    local lvl = rec.level or 1
    -- damage per second of a bot of this level on a mob of its level: about 6 + 1.1 * level (a level 75 melee bot is about 90 dps with TP moves)
    local dps = 6 + 1.1 * lvl
    local maxhp = act.mob.maxhp
    local lost = math.min(0.95 * maxhp, dps * elapsed)
    local ends = elapsed >= maxhp / dps
    -- the bot takes damage too: a mob of its level does about 4 + 0.5 * level per second, healed by regen and rests
    local taken = math.min(0.6, (4 + 0.5 * lvl) * elapsed / math.max(1, (rec.maxhp or 100 + 30 * lvl)))
    return {
        mob_hp = maxhp - lost,
        mob_hp_pct = math.floor(100 * (maxhp - lost) / maxhp),
        bot_hp_pct = math.floor(100 * (1 - taken)),
        tp = math.min(3000, math.floor(elapsed * 1.5) * 100 % 3000),
        engaged = not ends,
        resolved = ends,
    }
end

-- Turn a record into entities. `api` is the engine side (real: BotPlace/BotLogin + zone mob spawn; tests: a mock):
--   api.login(id, rec) -> bot entity     api.mob_at(zone, camp, mob) -> mob entity (spawn or reuse)   api.set_mob_hp(mob, hp)   api.claim(mob, bot)
--   api.engage(bot, mob)     api.set_bot(bot, hpPct, tp)     api.set_pos(bot, x, y, z)
-- Returns the bot entity and a table describing what it did (for the tests and the log).
function M.materialize_activity(id, rec, api, now)
    local act = rec.act or { kind = 'town' }
    local did = { kind = act.kind }
    if act.kind == 'travel' then
        local dx, dz = act.to.x - act.from.x, act.to.z - act.from.z
        local len = math.sqrt(dx * dx + dz * dz)
        local f = len > 0 and math.min(1, (now - act.t0) * (act.speed or 5) / len) or 1
        rec.x, rec.z = act.from.x + dx * f, act.from.z + dz * f
        rec.y = act.from.y + (act.to.y - act.from.y) * f
        did.progress = f
        if f >= 1 then
            rec.act = { kind = 'town' }
        end
    elseif act.kind == 'fight' then
        local fs = M.fight_state(rec, now)
        did.fight = fs
        if fs.resolved then
            -- the abstract fight ended while nobody watched: exp and the next pull are the caller's (growth model); it appears resting at the camp
            rec.act = { kind = 'rest' }
            did.kind = 'rest'
        else
            rec.x, rec.y, rec.z = act.camp.x, act.camp.y, act.camp.z
        end
    end

    local bot = api.login(id, rec)
    if did.fight and not did.fight.resolved then
        local mob = api.mob_at(rec.zone, act.camp, act.mob)
        api.set_mob_hp(mob, did.fight.mob_hp)
        api.claim(mob, bot)
        api.set_bot(bot, did.fight.bot_hp_pct, did.fight.tp)
        api.engage(bot, mob)
        did.mob = mob
    elseif rec.act and rec.act.kind == 'rest' then
        api.set_bot(bot, 60, 0)
    end

    return bot, did
end

return M
