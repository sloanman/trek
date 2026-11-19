-- Core tactical & strategic simulation engine for Vanguard Command

local C = require("src.constants")
local RNG = require("src.rng")
local Galaxy = require("src.galaxy")
local Movement = require("src.movement")
local Combat = require("src.combat")

local Engine = {}

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function round2(x)
    return math.floor(x * 100 + 0.5) / 100
end

local function makeRng(state)
    return RNG.new(state.rngState)
end

local function saveRng(state, rng)
    state.rngState = rng:getSeed()
end

function Engine.addLog(state, text, level)
    level = level or "info"
    state.log[#state.log + 1] = {
        cycle = round2(state.cycle),
        text = text,
        level = level,
    }
    while #state.log > 80 do
        table.remove(state.log, 1)
    end
end

function Engine.newGame(difficultyKey, seed, shipName)
    difficultyKey = C.DIFFICULTIES[difficultyKey] and difficultyKey or "captain"
    local diff = C.DIFFICULTIES[difficultyKey]
    local numericSeed = tonumber(seed)
    if not numericSeed then
        numericSeed = os.time() % 999999 + 1000
    end
    local rng = RNG.new(numericSeed)

    local startQx, startQy = 4, 4
    local gal = Galaxy.generate(difficultyKey, rng, startQx, startQy)
    local startQuad = Galaxy.getQuad(gal, startQx, startQy)
    local sx, sy = Galaxy.findFreeSector(startQuad, rng)

    Galaxy.revealAround(gal, startQx, startQy, 0, 1)

    local systems = {}
    for _, sub in ipairs(C.SUBSYSTEMS) do
        systems[sub.key] = 100
    end

    local startSx = sx or 4
    local startSy = sy or 4
    local wx, wy = Movement.sectorToWorld(startSx, startSy)

    local state = {
        version = 1,
        seed = numericSeed,
        rngState = rng:getSeed(),
        difficulty = difficultyKey,
        shipName = (shipName and shipName ~= "") and shipName or C.DEFAULT_SHIP_NAME,
        cycle = 0,
        maxCycles = diff.cycles,
        score = 0,
        status = "active",
        endReason = nil,
        turnCount = 0,
        siegeTickCounter = 0,
        paused = true,
        simTime = 0,
        projectiles = {},
        nextProjectileId = 1,
        stats = {
            killsByClass = { raider = 0, cruiser = 0, dreadnought = 0, stalker = 0 },
            totalKills = 0,
            outpostsSaved = 0,
            outpostsLost = 0,
            supernovas = 0,
            probesLaunched = 0,
            planetsMined = 0,
            damageDealt = 0,
            damageTaken = 0,
        },
        player = {
            qx = startQx,
            qy = startQy,
            sx = startSx,
            sy = startSy,
            x = wx,
            y = wy,
            heading = 0,
            speed = 0,
            maxSpeed = C.PLAYER_MOVEMENT.maxSpeed,
            turnRate = C.PLAYER_MOVEMENT.turnRate,
            accel = C.PLAYER_MOVEMENT.accel,
            decel = C.PLAYER_MOVEMENT.decel,
            speedSetting = 0.0,
            targetHeading = nil,
            activePath = nil,
            targetId = nil,
            showFiringArcs = C.COMBAT.defaultShowArcs,
            weapons = {
                beams = { charge = 0, mode = "focused", autoFire = true },
                torpedoes = { charge = 0, autoFire = true },
            },
            hull = diff.maxHull,
            maxHull = diff.maxHull,
            energy = diff.maxEnergy,
            maxEnergy = diff.maxEnergy,
            shields = math.floor(diff.maxShields * 0.6),
            maxShields = diff.maxShields,
            shieldsUp = false,
            torpedoes = diff.maxTorpedoes,
            maxTorpedoes = diff.maxTorpedoes,
            probes = diff.maxProbes,
            maxProbes = diff.maxProbes,
            auxReserve = diff.auxReserve,
            maxAuxReserve = diff.auxReserve,
            beamHeat = 0,
            lifeSupportTimer = 3,
            docked = false,
            systems = systems,
            prioritySystem = nil,
        },
        galaxy = gal,
        log = {},
    }

    local hostiles = Galaxy.countTotalHostiles(gal)
    local outposts = Galaxy.countTotalOutposts(gal)
    Engine.addLog(state, string.format(
        "%s deployed to Q(%d,%d) S(%d,%d). Eliminate %d hostiles within %d cycles.",
        state.shipName, startQx, startQy, state.player.sx, state.player.sy, hostiles, diff.cycles
    ), "cyan")
    Engine.addLog(state, string.format(
        "Concord Tactical Network online: %d Orbital Outposts active. Type HELP or press F1 for bridge manual.",
        outposts
    ), "info")

    return state
end

function Engine.currentQuad(state)
    return Galaxy.getQuad(state.galaxy, state.player.qx, state.player.qy)
end

function Engine.canDock(state)
    local quad = Engine.currentQuad(state)
    local outpost = Galaxy.getOutpost(quad)
    if not outpost then
        return false, nil
    end
    local dx = math.abs(state.player.sx - outpost.x)
    local dy = math.abs(state.player.sy - outpost.y)
    if dx <= 1 and dy <= 1 and not (dx == 0 and dy == 0) then
        return true, outpost
    end
    return false, nil
end

function Engine.getAdjacentMineablePlanet(state)
    local quad = Engine.currentQuad(state)
    for _, e in ipairs(quad.entities) do
        if e.kind == "planet" and e.hasFuel and not e.mined then
            local dx = math.abs(state.player.sx - e.x)
            local dy = math.abs(state.player.sy - e.y)
            if dx <= 1 and dy <= 1 then
                return e
            end
        end
    end
    return nil
end

function Engine.getCondition(state)
    if state.player.docked and Engine.canDock(state) then
        return "DOCKED"
    end
    local quad = Engine.currentQuad(state)
    local enemies = Galaxy.getEnemies(quad, true)
    if #enemies > 0 then
        return "RED"
    end
    if state.player.hull < state.player.maxHull * 0.45 or state.player.energy < state.player.maxEnergy * 0.2 or quad.ionStorm then
        return "YELLOW"
    end
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            if state.galaxy.quadrants[qy][qx].siege then
                return "YELLOW"
            end
        end
    end
    return "GREEN"
end

-- Shared deterministic super-sampled raycast used by both previews and execution
function Engine.traceRay(quad, x1, y1, x2, y2, extendToEdge)
    local dx = x2 - x1
    local dy = y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    local cells = {}
    if len < 1e-6 then
        return {
            cells = cells,
            hitEntity = nil,
            hitCell = nil,
            lastFreeCell = { x = x1, y = y1 },
        }
    end

    local ux, uy = dx / len, dy / len
    local maxDist = extendToEdge and 14.0 or len
    local steps = math.max(24, math.ceil(maxDist * 28))
    local seen = {}
    seen[y1 * 16 + x1] = true

    local lastFree = { x = x1, y = y1 }
    local hitEntity = nil
    local hitCell = nil

    for i = 1, steps do
        local d = (i / steps) * maxDist
        local fx = x1 + ux * d
        local fy = y1 + uy * d
        local cx = math.floor(fx + 0.5)
        local cy = math.floor(fy + 0.5)

        if cx < 1 or cx > C.GRID_SIZE or cy < 1 or cy > C.GRID_SIZE then
            break
        end

        local k = cy * 16 + cx
        if not seen[k] then
            seen[k] = true
            local cell = { x = cx, y = cy }
            cells[#cells + 1] = cell
            local ent = Galaxy.getEntityAt(quad, cx, cy)
            if ent then
                hitEntity = ent
                hitCell = cell
                break
            else
                lastFree = cell
            end
        end
    end

    return {
        cells = cells,
        hitEntity = hitEntity,
        hitCell = hitCell,
        lastFreeCell = lastFree,
    }
end

-- Helper to get the primary readable heading angle from (x1,y1) -> (x2,y2)
local function calcHeading(x1, y1, x2, y2)
    if x1 == x2 and y1 == y2 then
        return nil
    end
    return math.atan2(y2 - y1, x2 - x1)
end

-- ======================== PREVIEW / CALCULATORS ========================

function Engine.previewSublight(state, tx, ty)
    local p = state.player
    if state.status ~= "active" then
        return { ok = false, reason = "Mission has ended." }
    end
    if tx < 1 or tx > C.GRID_SIZE or ty < 1 or ty > C.GRID_SIZE then
        return { ok = false, reason = "Coordinates out of sector bounds (1-8)." }
    end
    if tx == p.sx and ty == p.sy then
        return { ok = false, reason = "Already at target sector." }
    end
    if p.systems.thrusters <= 0 then
        return { ok = false, reason = "Thrusters offline. Use Repair or Field Fix first." }
    end

    local quad = Engine.currentQuad(state)
    local ray = Engine.traceRay(quad, p.sx, p.sy, tx, ty, false)
    local destX, destY = ray.lastFreeCell.x, ray.lastFreeCell.y
    local singularityRisk = false

    if ray.hitEntity and ray.hitEntity.kind == "singularity" then
        singularityRisk = true
        destX, destY = ray.hitCell.x, ray.hitCell.y
    end

    if destX == p.sx and destY == p.sy and not singularityRisk then
        local blockerName = ray.hitEntity and (ray.hitEntity.name or ray.hitEntity.kind) or "obstacle"
        return {
            ok = false,
            reason = "Path immediately blocked by " .. blockerName .. ".",
            path = ray.cells,
            blockedBy = ray.hitEntity,
        }
    end

    local dist = math.sqrt((destX - p.sx) ^ 2 + (destY - p.sy) ^ 2)
    local thrustMult = 1.0 + (100 - p.systems.thrusters) * 0.008
    local baseEnergy = math.max(10, math.floor(dist * 14 * thrustMult))
    local energyCost = p.shieldsUp and (baseEnergy * 2) or baseEnergy
    local cycleCost = round2(math.max(0.15, dist * 0.08 * thrustMult))

    if p.energy < energyCost then
        return {
            ok = false,
            reason = string.format("Insufficient energy (%d needed, %d available).", energyCost, p.energy),
            path = ray.cells,
            blockedBy = ray.hitEntity,
            destX = destX,
            destY = destY,
            dist = dist,
            energyCost = energyCost,
            cycleCost = cycleCost,
            singularityRisk = singularityRisk,
        }
    end

    return {
        ok = true,
        path = ray.cells,
        blockedBy = ray.hitEntity,
        destX = destX,
        destY = destY,
        dist = dist,
        energyCost = energyCost,
        cycleCost = cycleCost,
        singularityRisk = singularityRisk,
    }
end

function Engine.previewFTL(state, tqx, tqy, factor)
    local p = state.player
    if state.status ~= "active" then
        return { ok = false, reason = "Mission has ended." }
    end
    if tqx < 1 or tqx > C.GRID_SIZE or tqy < 1 or tqy > C.GRID_SIZE then
        return { ok = false, reason = "Quadrant out of bounds (1-8)." }
    end
    if tqx == p.qx and tqy == p.qy then
        return { ok = false, reason = "Already stationed in this quadrant." }
    end
    local ftlHealth = p.systems.ftl
    if ftlHealth <= 0 then
        return { ok = false, reason = "FTL Drive offline. Repair subsystem first." }
    end

    factor = clamp(math.floor(tonumber(factor) or 5), 1, 9)
    local maxSafeFactor = math.max(1, math.floor(6 * (ftlHealth / 100)))
    local maxAllowedFactor = math.max(2, math.floor(9 * (ftlHealth / 100)))
    if factor > maxAllowedFactor then
        return {
            ok = false,
            reason = string.format("Damaged FTL Drive capped at Factor %d.", maxAllowedFactor),
            maxSafeFactor = maxSafeFactor,
            maxAllowedFactor = maxAllowedFactor,
        }
    end

    local dist = math.sqrt((tqx - p.qx) ^ 2 + (tqy - p.qy) ^ 2)
    local baseEnergy = math.floor(dist * (26 + factor * 10))
    local shieldsPenalty = p.shieldsUp
    local energyCost = shieldsPenalty and (baseEnergy * 2) or baseEnergy
    local cycleCost = round2(math.max(0.25, dist / (factor * 0.45)))
    local overstressRisk = 0
    if factor > maxSafeFactor then
        overstressRisk = clamp((factor - maxSafeFactor) * 0.22, 0.15, 0.85)
    end

    if p.energy < energyCost then
        return {
            ok = false,
            reason = string.format("Insufficient energy (%d needed, %d available).", energyCost, p.energy),
            dist = dist,
            factor = factor,
            maxSafeFactor = maxSafeFactor,
            maxAllowedFactor = maxAllowedFactor,
            energyCost = energyCost,
            cycleCost = cycleCost,
            overstressRisk = overstressRisk,
            shieldsPenalty = shieldsPenalty,
        }
    end

    return {
        ok = true,
        dist = dist,
        factor = factor,
        maxSafeFactor = maxSafeFactor,
        maxAllowedFactor = maxAllowedFactor,
        energyCost = energyCost,
        cycleCost = cycleCost,
        overstressRisk = overstressRisk,
        shieldsPenalty = shieldsPenalty,
    }
end

function Engine.previewBeams(state, power, targetId)
    local p = state.player
    if state.status ~= "active" then
        return { ok = false, reason = "Mission has ended." }
    end
    if p.systems.beams <= 0 then
        return { ok = false, reason = "Beam Array offline. Repair subsystem first." }
    end
    if p.beamHeat >= 100 then
        return { ok = false, reason = "Beam Array overheated (100%). Cool down or repair." }
    end

    local quad = Engine.currentQuad(state)
    local visibleEnemies = Galaxy.getEnemies(quad, false)
    if #visibleEnemies == 0 then
        local hidden = Galaxy.getEnemies(quad, true)
        if #hidden > 0 then
            return { ok = false, reason = "Hostile masked by stealth cloak. Run Active Scan (7) to reveal!" }
        end
        return { ok = false, reason = "No hostile targets in current quadrant." }
    end

    local selected = {}
    if targetId then
        local tgt = Galaxy.getEntityById(quad, targetId)
        if not tgt or tgt.kind ~= "enemy" then
            return { ok = false, reason = "Selected target no longer valid." }
        end
        if tgt.cloaked then
            return { ok = false, reason = "Target is cloaked. Run Active Scan to decloak." }
        end
        selected[1] = tgt
    else
        selected = visibleEnemies
    end

    power = math.floor(tonumber(power) or 300)
    if power < 50 then
        return { ok = false, reason = "Minimum beam allocation is 50 energy." }
    end
    if p.energy < power then
        return { ok = false, reason = string.format("Insufficient energy (%d needed, %d available).", power, p.energy) }
    end

    local perTarget = power / #selected
    local eff = 0.35 + 0.65 * (p.systems.beams / 100)
    local stormMult = quad.ionStorm and 0.72 or 1.0
    local heatDelta = math.max(6, math.floor(power / 18))
    local overheatRisk = (p.beamHeat + heatDelta) >= 100
    local computerOk = p.systems.computer > 20

    local targets = {}
    for _, e in ipairs(selected) do
        local dist = math.sqrt((e.x - p.sx) ^ 2 + (e.y - p.sy) ^ 2)
        local falloff = 1 / (0.82 + 0.20 * dist)
        local estDmg = math.max(10, math.floor(perTarget * eff * falloff * stormMult))
        local totalHp = e.shield + e.hull
        targets[#targets + 1] = {
            id = e.id,
            name = e.name,
            x = e.x,
            y = e.y,
            dist = round2(dist),
            estDmg = computerOk and estDmg or nil,
            willKill = computerOk and (estDmg >= totalHp) or false,
        }
    end

    return {
        ok = true,
        targets = targets,
        heatDelta = heatDelta,
        overheatRisk = overheatRisk,
        energyCost = power,
        cycleCost = 0.25,
        ionStorm = quad.ionStorm,
    }
end

function Engine.previewTorpedo(state, tx, ty)
    local p = state.player
    if state.status ~= "active" then
        return { ok = false, reason = "Mission has ended." }
    end
    if p.systems.torpedoes <= 0 then
        return { ok = false, reason = "Missile Tubes offline. Repair subsystem first." }
    end
    if p.torpedoes <= 0 then
        return { ok = false, reason = "No Plasma Torpedoes remaining. Dock at an Outpost." }
    end
    if tx < 1 or tx > C.GRID_SIZE or ty < 1 or ty > C.GRID_SIZE then
        return { ok = false, reason = "Coordinates out of bounds (1-8)." }
    end
    if tx == p.sx and ty == p.sy then
        return { ok = false, reason = "Cannot fire torpedo at own position." }
    end
    if p.energy < 25 then
        return { ok = false, reason = "Insufficient energy (25 needed for launch tube)." }
    end

    local quad = Engine.currentQuad(state)
    local ray = Engine.traceRay(quad, p.sx, p.sy, tx, ty, true)
    local hit = ray.hitEntity
    local friendlyBlocked = (hit ~= nil and hit.kind == "outpost")
    local novaWarning = (hit ~= nil and hit.kind == "star")
    local habitableWarning = (hit ~= nil and hit.kind == "planet" and hit.habitable == true)

    if friendlyBlocked then
        return {
            ok = false,
            reason = "Weapons interlock engaged: firing line intersects friendly Outpost!",
            path = ray.cells,
            hitEntity = hit,
            hitCell = ray.hitCell,
            friendlyBlocked = true,
            energyCost = 25,
            cycleCost = 0.25,
        }
    end

    return {
        ok = true,
        path = ray.cells,
        hitEntity = hit,
        hitCell = ray.hitCell,
        novaWarning = novaWarning,
        friendlyBlocked = false,
        habitableWarning = habitableWarning,
        energyCost = 25,
        cycleCost = 0.25,
    }
end

-- ======================== COMBAT & STRATEGIC TURN ========================

local function removeEntityById(quad, id)
    for i, e in ipairs(quad.entities) do
        if e.id == id then
            table.remove(quad.entities, i)
            return true
        end
    end
    return false
end

local function checkSiegeCleared(state, quad, events)
    if not quad.siege then
        return
    end
    local remaining = Galaxy.getEnemies(quad, true)
    if #remaining == 0 then
        quad.siege = nil
        state.score = state.score + 400
        state.stats.outpostsSaved = state.stats.outpostsSaved + 1
        local outpost = Galaxy.getOutpost(quad)
        local name = outpost and outpost.name or string.format("Outpost Q(%d,%d)", quad.qx, quad.qy)
        Engine.addLog(state, name .. " siege broken! +400 Station Saved bonus.", "emerald")
        events[#events + 1] = {
            kind = "floatText",
            x = outpost and outpost.x or state.player.sx,
            y = outpost and outpost.y or state.player.sy,
            text = "+400 SAVED",
            color = "emerald",
        }
    end
end

local function applyDamageToEnemy(state, quad, enemy, dmg, shieldBypassFraction, rng, events, impactCtx)
    shieldBypassFraction = shieldBypassFraction or 0
    if impactCtx then
        enemy.lastImpactQuadrant = impactCtx.quadrant
    end
    local bypassDmg = math.floor(dmg * shieldBypassFraction)
    local shieldPhaseDmg = dmg - bypassDmg

    local absorbed = math.min(enemy.shield, shieldPhaseDmg)
    enemy.shield = enemy.shield - absorbed
    local overflow = shieldPhaseDmg - absorbed
    local hullDmg = overflow + bypassDmg
    enemy.hull = enemy.hull - hullDmg
    state.stats.damageDealt = state.stats.damageDealt + dmg

    if absorbed > 0 then
        events[#events + 1] = { kind = "shieldRipple", x = enemy.x, y = enemy.y, color = "amber" }
    end

    if enemy.hull <= 0 then
        enemy.hull = 0
        removeEntityById(quad, enemy.id)
        if state.player and state.player.targetId == enemy.id then
            state.player.targetId = nil
        end
        state.score = state.score + (enemy.score or 100)
        state.stats.totalKills = state.stats.totalKills + 1
        state.stats.killsByClass[enemy.class] = (state.stats.killsByClass[enemy.class] or 0) + 1
        Engine.addLog(state, string.format("%s destroyed! (+%d pts)", enemy.name, enemy.score or 100), "emerald")
        events[#events + 1] = { kind = "explosion", x = enemy.x, y = enemy.y, size = 1.0 }
        events[#events + 1] = { kind = "sound", sound = "explosion" }
        events[#events + 1] = { kind = "floatText", x = enemy.x, y = enemy.y, text = "DESTROYED", color = "amber" }
        checkSiegeCleared(state, quad, events)
        return true
    else
        events[#events + 1] = { kind = "floatText", x = enemy.x, y = enemy.y, text = "-" .. tostring(dmg), color = "crimson" }
        return false
    end
end

local function applyDamageToPlayer(state, dmg, sourceName, rng, events, impactCtx, fxX, fxY)
    local p = state.player
    local hitX = fxX or p.sx
    local hitY = fxY or p.sy
    if impactCtx then
        p.lastImpactQuadrant = impactCtx.quadrant
    end
    state.stats.damageTaken = state.stats.damageTaken + dmg

    local hullDmg = dmg
    local shieldAbsorbed = 0
    if p.shieldsUp and p.shields > 0 and p.systems.shields > 0 then
        shieldAbsorbed = math.min(p.shields, dmg)
        p.shields = p.shields - shieldAbsorbed
        hullDmg = dmg - shieldAbsorbed
        events[#events + 1] = { kind = "shieldRipple", x = hitX, y = hitY, color = "cyan" }
        events[#events + 1] = { kind = "sound", sound = "shieldHit" }
        if p.shields <= 0 then
            p.shields = 0
            p.shieldsUp = false
            Engine.addLog(state, "Deflector shields collapsed under fire!", "crimson")
        end
    end

    if hullDmg > 0 then
        p.hull = math.max(0, p.hull - hullDmg)
        events[#events + 1] = { kind = "sound", sound = "hullHit" }
        events[#events + 1] = { kind = "shake", intensity = math.min(12, 3 + hullDmg / 35) }
        events[#events + 1] = { kind = "floatText", x = hitX, y = hitY, text = "-" .. tostring(hullDmg) .. " HULL", color = "crimson" }

        -- Subsystem damage roll (higher chance when shields are down)
        local sysChance = (shieldAbsorbed == 0) and 0.65 or 0.35
        if rng:chance(sysChance) then
            local sub = rng:pick(C.SUBSYSTEMS)
            local sysDmg = rng:int(12, 32)
            p.systems[sub.key] = math.max(0, p.systems[sub.key] - sysDmg)
            Engine.addLog(state, string.format("%s hit: -%d HULL, %s damaged (-%d%%)!", sourceName, hullDmg, sub.label, sysDmg), "crimson")
        else
            Engine.addLog(state, string.format("%s struck hull for %d damage!", sourceName, hullDmg), "crimson")
        end
    else
        Engine.addLog(state, string.format("%s impact absorbed by shields (%d dmg).", sourceName, shieldAbsorbed), "amber")
        events[#events + 1] = { kind = "floatText", x = hitX, y = hitY, text = "-" .. tostring(shieldAbsorbed) .. " SHD", color = "cyan" }
    end
end

local function triggerSupernova(state, quad, starEntity, rng, events)
    local sx, sy = starEntity.x, starEntity.y
    removeEntityById(quad, starEntity.id)
    state.stats.supernovas = state.stats.supernovas + 1
    Engine.addLog(state, string.format("SUPERNOVA! Star at S(%d,%d) detonates in a thermonuclear shockwave!", sx, sy), "amber")
    events[#events + 1] = { kind = "supernova", x = sx, y = sy }
    events[#events + 1] = { kind = "sound", sound = "supernova" }
    events[#events + 1] = { kind = "shake", intensity = 14 }

    -- Gather affected entities first because table changes during iteration
    local affectedEnemies = {}
    local affectedStars = {}
    local affectedOutpost = nil
    for _, e in ipairs(quad.entities) do
        if math.abs(e.x - sx) <= 1 and math.abs(e.y - sy) <= 1 then
            if e.kind == "enemy" then
                affectedEnemies[#affectedEnemies + 1] = e
            elseif e.kind == "outpost" then
                affectedOutpost = e
            elseif e.kind == "planet" then
                e.habitable = false
                e.hasFuel = false
            end
        end
    end

    for _, enemy in ipairs(affectedEnemies) do
        applyDamageToEnemy(state, quad, enemy, 500, 0.5, rng, events)
    end

    if affectedOutpost then
        affectedOutpost.hp = affectedOutpost.hp - 350
        if affectedOutpost.hp <= 0 then
            removeEntityById(quad, affectedOutpost.id)
            quad.siege = nil
            state.stats.outpostsLost = state.stats.outpostsLost + 1
            Engine.addLog(state, affectedOutpost.name .. " obliterated by supernova!", "crimson")
        else
            Engine.addLog(state, affectedOutpost.name .. " heavily scorched by supernova!", "amber")
        end
    end

    -- Check player blast radius
    if math.abs(state.player.sx - sx) <= 1 and math.abs(state.player.sy - sy) <= 1 then
        applyDamageToPlayer(state, 420, "Supernova shockwave", rng, events)
    end
end

local function stepEnemyTactics(state, quad, rng, events)
    local p = state.player
    if p.docked then
        return
    end
    local enemies = Galaxy.getEnemies(quad, true)
    if #enemies == 0 then
        return
    end

    for _, e in ipairs(enemies) do
        if p.hull <= 0 then
            break
        end
        -- Stealth Frigate cloak logic
        if e.class == "stalker" then
            if e.decloakTurns and e.decloakTurns > 0 then
                e.decloakTurns = e.decloakTurns - 1
                if e.decloakTurns == 0 and rng:chance(0.5) then
                    e.cloaked = true
                    Engine.addLog(state, e.name .. " re-engaged stealth cloak.", "amber")
                end
            elseif e.cloaked and rng:chance(0.45) then
                -- Ambush from cloak and remain visible for 1 turn
                e.cloaked = false
                e.decloakTurns = 1
                Engine.addLog(state, e.name .. " decloaks for an ambush strike!", "crimson")
            end
        end

        -- Tactical 1-tile step (45% chance to reposition toward preferred range)
        if rng:chance(0.45) then
            local dx = (e.x < p.sx) and 1 or ((e.x > p.sx) and -1 or 0)
            local dy = (e.y < p.sy) and 1 or ((e.y > p.sy) and -1 or 0)
            local dist = math.sqrt((e.x - p.sx) ^ 2 + (e.y - p.sy) ^ 2)
            if dist < 2.2 then
                dx, dy = -dx, -dy
            end
            local nx, ny = clamp(e.x + dx, 1, C.GRID_SIZE), clamp(e.y + dy, 1, C.GRID_SIZE)
            if (nx ~= e.x or ny ~= e.y) and not (nx == p.sx and ny == p.sy) and not Galaxy.getEntityAt(quad, nx, ny) then
                local oldX, oldY = e.x, e.y
                e.x, e.y = nx, ny
                e.heading = calcHeading(oldX, oldY, nx, ny) or e.heading
                events[#events + 1] = { kind = "shipGlide", id = e.id, x1 = oldX, y1 = oldY, x2 = nx, y2 = ny }
            end
        end

        -- Fire at player if not hidden in passive cloak
        if not e.cloaked then
            e.heading = calcHeading(e.x, e.y, p.sx, p.sy) or e.heading
            local dist = math.sqrt((e.x - p.sx) ^ 2 + (e.y - p.sy) ^ 2)
            local raw = rng:int(e.minDmg, e.maxDmg)
            local falloff = clamp(1.08 - dist * 0.055, 0.55, 1.0)
            local dmg = math.max(15, math.floor(raw * falloff))
            events[#events + 1] = {
                kind = "beam",
                x1 = e.x, y1 = e.y,
                x2 = p.sx, y2 = p.sy,
                color = "crimson",
            }
            events[#events + 1] = { kind = "sound", sound = "beam", volume = 0.7 }
            applyDamageToPlayer(state, dmg, e.name, rng, events)
        end
    end
end

local function stepStrategicGalaxy(state, elapsedCycles, rng, events)
    local diff = C.DIFFICULTIES[state.difficulty] or C.DIFFICULTIES.captain

    -- Tick active outpost sieges
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            local quad = state.galaxy.quadrants[qy][qx]
            if quad.siege then
                local enemies = Galaxy.getEnemies(quad, true)
                local outpost = Galaxy.getOutpost(quad)
                if #enemies == 0 or not outpost then
                    quad.siege = nil
                else
                    quad.siege.cyclesLeft = round2(quad.siege.cyclesLeft - elapsedCycles)
                    if quad.siege.cyclesLeft <= 0 then
                        removeEntityById(quad, outpost.id)
                        quad.siege = nil
                        state.stats.outpostsLost = state.stats.outpostsLost + 1
                        Engine.addLog(state, string.format("DISTRESS LOST: %s at Q(%d,%d) fell to enemy siege!", outpost.name, qx, qy), "crimson")
                        events[#events + 1] = { kind = "sound", sound = "alert" }
                    end
                end
            end
        end
    end

    -- Trigger a new siege if hostiles share a quadrant with an un-besieged outpost
    -- or occasionally let a Siege Dreadnought warp toward an Outpost
    state.siegeTickCounter = (state.siegeTickCounter or 0) + elapsedCycles
    if state.siegeTickCounter >= 1.0 then
        state.siegeTickCounter = state.siegeTickCounter - 1.0

        local activeSieges = 0
        local outpostQuads = {}
        local dreadnoughtQuads = {}
        for qy = 1, C.GRID_SIZE do
            for qx = 1, C.GRID_SIZE do
                local quad = state.galaxy.quadrants[qy][qx]
                if quad.siege then
                    activeSieges = activeSieges + 1
                end
                local outpost = Galaxy.getOutpost(quad)
                local enemies = Galaxy.getEnemies(quad, true)
                if outpost then
                    outpostQuads[#outpostQuads + 1] = quad
                    if #enemies > 0 and not quad.siege then
                        quad.siege = { cyclesLeft = 5.0, maxCycles = 5.0, outpostId = outpost.id }
                        activeSieges = activeSieges + 1
                        Engine.addLog(state, string.format("DISTRESS CALL: %s at Q(%d,%d) is under siege (5.0 cycles)!", outpost.name, qx, qy), "amber")
                        events[#events + 1] = { kind = "sound", sound = "alert" }
                    end
                end
                if #enemies > 0 and not (qx == state.player.qx and qy == state.player.qy) then
                    for _, e in ipairs(enemies) do
                        if e.class == "dreadnought" then
                            dreadnoughtQuads[#dreadnoughtQuads + 1] = { quad = quad, enemy = e }
                        end
                    end
                end
            end
        end

        -- Strategic Dreadnought movement toward an outpost
        if activeSieges < 2 and #outpostQuads > 0 and #dreadnoughtQuads > 0 and rng:chance(diff.siegeRate) then
            local pick = rng:pick(dreadnoughtQuads)
            local targetQuad = rng:pick(outpostQuads)
            if targetQuad.qx ~= pick.quad.qx or targetQuad.qy ~= pick.quad.qy then
                local stepX = clamp(pick.quad.qx + ((targetQuad.qx > pick.quad.qx) and 1 or ((targetQuad.qx < pick.quad.qx) and -1 or 0)), 1, C.GRID_SIZE)
                local stepY = clamp(pick.quad.qy + ((targetQuad.qy > pick.quad.qy) and 1 or ((targetQuad.qy < pick.quad.qy) and -1 or 0)), 1, C.GRID_SIZE)
                local destQuad = Galaxy.getQuad(state.galaxy, stepX, stepY)
                if destQuad and #Galaxy.getEnemies(destQuad, true) < 3 and not (stepX == state.player.qx and stepY == state.player.qy) then
                    local sx, sy = Galaxy.findFreeSector(destQuad, rng)
                    if sx then
                        removeEntityById(pick.quad, pick.enemy.id)
                        pick.enemy.x, pick.enemy.y = sx, sy
                        destQuad.entities[#destQuad.entities + 1] = pick.enemy
                        local outpost = Galaxy.getOutpost(destQuad)
                        if outpost and not destQuad.siege then
                            destQuad.siege = { cyclesLeft = 5.0, maxCycles = 5.0, outpostId = outpost.id }
                            Engine.addLog(state, string.format("DISTRESS CALL: %s at Q(%d,%d) under attack by %s!", outpost.name, stepX, stepY, pick.enemy.name), "amber")
                            events[#events + 1] = { kind = "sound", sound = "alert" }
                        end
                    end
                end
            end
        end
    end
end

function Engine.evaluateEndConditions(state, events)
    if state.status ~= "active" then
        return
    end
    local p = state.player
    if p.hull <= 0 then
        state.status = "defeat"
        state.endReason = state.shipName .. " was destroyed in combat."
        Engine.addLog(state, "CRITICAL: Hull integrity failed. " .. state.shipName .. " lost.", "crimson")
        events[#events + 1] = { kind = "sound", sound = "defeat" }
        return
    end
    if p.systems.lifesupport <= 0 and p.lifeSupportTimer <= 0 and not p.docked then
        state.status = "defeat"
        state.endReason = "Life Support failed before repairs could be completed."
        Engine.addLog(state, "CRITICAL: Life Support failure. Mission lost.", "crimson")
        events[#events + 1] = { kind = "sound", sound = "defeat" }
        return
    end
    if state.cycle >= state.maxCycles then
        local remaining = Galaxy.countTotalHostiles(state.galaxy)
        if remaining == 0 then
            state.status = "victory"
            state.endReason = "All hostile forces neutralized!"
            events[#events + 1] = { kind = "sound", sound = "victory" }
        else
            state.status = "defeat"
            state.endReason = string.format("Mission deadline expired (%d hostiles remain).", remaining)
            Engine.addLog(state, "DEADLINE EXPIRED: Sector lost to hostile occupation.", "crimson")
            events[#events + 1] = { kind = "sound", sound = "defeat" }
        end
        return
    end
    local remaining = Galaxy.countTotalHostiles(state.galaxy)
    if remaining == 0 then
        state.status = "victory"
        state.endReason = "All hostile forces neutralized across the sector!"
        Engine.addLog(state, "VICTORY: All hostile ships eliminated! Concord space is secure.", "emerald")
        events[#events + 1] = { kind = "sound", sound = "victory" }
    end
end

local function advanceTurn(state, elapsedCycles, skipEnemyFire, rng, events)
    local p = state.player
    state.turnCount = state.turnCount + 1
    state.cycle = round2(state.cycle + elapsedCycles)

    -- Passive beam cooling & trickle subsystem repairs
    p.beamHeat = math.max(0, math.floor(p.beamHeat - 24 * elapsedCycles))
    for _, sub in ipairs(C.SUBSYSTEMS) do
        local cur = p.systems[sub.key]
        if cur < 100 then
            local rate = (p.prioritySystem == sub.key) and 10 or 3
            p.systems[sub.key] = math.min(100, math.floor(cur + rate * elapsedCycles + 0.5))
        end
    end

    -- Life support hazard if offline
    if p.systems.lifesupport <= 0 and not p.docked then
        p.lifeSupportTimer = round2(p.lifeSupportTimer - elapsedCycles)
        Engine.addLog(state, string.format("WARNING: Life Support offline! Reserve air: %.1f cycles.", math.max(0, p.lifeSupportTimer)), "crimson")
    else
        p.lifeSupportTimer = 3.0
    end

    local quad = Engine.currentQuad(state)
    if not skipEnemyFire then
        stepEnemyTactics(state, quad, rng, events)
    end

    stepStrategicGalaxy(state, elapsedCycles, rng, events)
    Engine.evaluateEndConditions(state, events)
end

-- ======================== PUBLIC ACTIONS ========================

function Engine.moveSublight(state, tx, ty)
    local prev = Engine.previewSublight(state, tx, ty)
    if not prev.ok then
        return { ok = false, msg = prev.reason, events = {} }
    end

    local rng = makeRng(state)
    local events = {}
    local p = state.player
    p.docked = false

    local oldX, oldY = p.sx, p.sy
    p.energy = p.energy - prev.energyCost
    p.heading = calcHeading(oldX, oldY, prev.destX, prev.destY) or p.heading
    p.sx, p.sy = prev.destX, prev.destY
    p.x, p.y = Movement.sectorToWorld(p.sx, p.sy)
    p.activePath = nil
    p.targetHeading = nil
    p.speed = 0
    p.speedSetting = 0

    events[#events + 1] = { kind = "shipGlide", id = "player", x1 = oldX, y1 = oldY, x2 = p.sx, y2 = p.sy }
    events[#events + 1] = { kind = "sound", sound = "thruster" }

    if prev.singularityRisk then
        -- Gravitational slingshot to random quadrant & sector!
        local newQx, newQy = rng:int(1, C.GRID_SIZE), rng:int(1, C.GRID_SIZE)
        local destQuad = Galaxy.getQuad(state.galaxy, newQx, newQy)
        local nsx, nsy = Galaxy.findFreeSector(destQuad, rng)
        p.qx, p.qy = newQx, newQy
        p.sx, p.sy = nsx or 4, nsy or 4
        p.x, p.y = Movement.sectorToWorld(p.sx, p.sy)
        p.activePath = nil
        p.targetHeading = nil
        p.targetId = nil
        state.projectiles = {}
        p.speed = 0
        p.speedSetting = 0
        Galaxy.revealAround(state.galaxy, newQx, newQy, state.cycle, 1)
        Engine.addLog(state, string.format(
            "GRAV-SLINGSHOT! Singularity flung %s across space to Q(%d,%d) S(%d,%d)!",
            state.shipName, newQx, newQy, p.sx, p.sy
        ), "violet")
        events[#events + 1] = { kind = "ftlJump" }
        events[#events + 1] = { kind = "sound", sound = "ftl" }
        events[#events + 1] = { kind = "shake", intensity = 10 }
        advanceTurn(state, prev.cycleCost, true, rng, events)
    else
        local msg
        if prev.blockedBy and (prev.destX ~= tx or prev.destY ~= ty) then
            msg = string.format("Thrusters halted short at S(%d,%d) to avoid %s (-%d E).",
                p.sx, p.sy, prev.blockedBy.name or prev.blockedBy.kind, prev.energyCost)
            Engine.addLog(state, msg, "amber")
        else
            msg = string.format("Manoeuvred to S(%d,%d) (-%d E, +%.2f cycles).", p.sx, p.sy, prev.energyCost, prev.cycleCost)
            Engine.addLog(state, msg, "info")
        end
        advanceTurn(state, prev.cycleCost, false, rng, events)
    end

    saveRng(state, rng)
    return { ok = true, msg = state.log[#state.log].text, events = events }
end

function Engine.jumpFTL(state, tqx, tqy, factor)
    local prev = Engine.previewFTL(state, tqx, tqy, factor)
    if not prev.ok then
        return { ok = false, msg = prev.reason, events = {} }
    end

    local rng = makeRng(state)
    local events = {}
    local p = state.player
    p.docked = false

    p.energy = p.energy - prev.energyCost
    p.qx, p.qy = tqx, tqy

    local destQuad = Engine.currentQuad(state)
    local nsx, nsy = Galaxy.findFreeSector(destQuad, rng)
    p.sx, p.sy = nsx or 4, nsy or 4
    p.x, p.y = Movement.sectorToWorld(p.sx, p.sy)
    p.activePath = nil
    p.targetHeading = nil
    p.targetId = nil
    state.projectiles = {}
    p.speed = 0
    p.speedSetting = 0

    -- Overstress risk check
    if prev.overstressRisk > 0 and rng:chance(prev.overstressRisk) then
        local dmg = rng:int(15, 35)
        p.systems.ftl = math.max(10, p.systems.ftl - dmg)
        Engine.addLog(state, string.format("FTL Factor %d overstressed drive coils (-%d%% FTL Drive)!", prev.factor, dmg), "amber")
    end

    -- Auto-scan immediate 3x3 if scanner online (or current quad only if damaged)
    local scanRadius = (p.systems.scanner > 20) and 1 or 0
    Galaxy.revealAround(state.galaxy, tqx, tqy, state.cycle + prev.cycleCost, scanRadius)

    events[#events + 1] = { kind = "ftlJump" }
    events[#events + 1] = { kind = "sound", sound = "ftl" }

    local enemies = Galaxy.getEnemies(destQuad, false)
    if #enemies > 0 then
        Engine.addLog(state, string.format("FTL arrival Q(%d,%d) S(%d,%d). RED ALERT: %d hostile contact(s)!", tqx, tqy, p.sx, p.sy, #enemies), "crimson")
        events[#events + 1] = { kind = "sound", sound = "alert" }
    elseif destQuad.ionStorm then
        Engine.addLog(state, string.format("FTL arrival Q(%d,%d) S(%d,%d). Ion storm degrades beam efficiency.", tqx, tqy, p.sx, p.sy), "amber")
    else
        Engine.addLog(state, string.format("FTL Factor %d complete -> Q(%d,%d) S(%d,%d) (-%d E).", prev.factor, tqx, tqy, p.sx, p.sy, prev.energyCost), "cyan")
    end

    -- Player gets tactical initiative on FTL arrival (skipEnemyFire = true)
    advanceTurn(state, prev.cycleCost, true, rng, events)
    saveRng(state, rng)
    return { ok = true, msg = state.log[#state.log].text, events = events }
end

function Engine.fireBeams(state, power, targetId)
    local prev = Engine.previewBeams(state, power, targetId)
    if not prev.ok then
        return { ok = false, msg = prev.reason, events = {} }
    end

    local rng = makeRng(state)
    local events = {}
    local p = state.player
    local quad = Engine.currentQuad(state)

    p.energy = p.energy - prev.energyCost
    p.beamHeat = math.min(100, p.beamHeat + prev.heatDelta)
    if prev.overheatRisk then
        p.systems.beams = math.max(10, p.systems.beams - rng:int(8, 16))
        Engine.addLog(state, "Beam Array overheated! Thermal stress damaged emitter coils.", "amber")
    end

    events[#events + 1] = { kind = "sound", sound = "beam" }
    local destroyed = 0
    for _, t in ipairs(prev.targets) do
        local enemy = Galaxy.getEntityById(quad, t.id)
        if enemy then
            p.heading = calcHeading(p.sx, p.sy, enemy.x, enemy.y) or p.heading
            events[#events + 1] = {
                kind = "beam",
                x1 = p.sx, y1 = p.sy,
                x2 = enemy.x, y2 = enemy.y,
                color = "cyan",
            }
            local jitter = rng:float(0.92, 1.08)
            local baseEst = t.estDmg or math.floor((prev.energyCost / #prev.targets) * 0.75)
            local actualDmg = math.max(10, math.floor(baseEst * jitter))
            Engine.addLog(state, string.format("Beam strike on %s for %d dmg.", enemy.name, actualDmg), "cyan")
            if applyDamageToEnemy(state, quad, enemy, actualDmg, 0, rng, events) then
                destroyed = destroyed + 1
            end
        end
    end

    advanceTurn(state, prev.cycleCost, false, rng, events)
    saveRng(state, rng)
    return { ok = true, msg = string.format("Fired %d energy across %d target(s).", prev.energyCost, #prev.targets), events = events }
end

function Engine.fireTorpedo(state, tx, ty)
    local prev = Engine.previewTorpedo(state, tx, ty)
    if not prev.ok then
        return { ok = false, msg = prev.reason, events = {} }
    end

    local rng = makeRng(state)
    local events = {}
    local p = state.player
    local quad = Engine.currentQuad(state)

    p.energy = p.energy - prev.energyCost
    p.torpedoes = p.torpedoes - 1
    p.heading = calcHeading(p.sx, p.sy, tx, ty) or p.heading

    local endCell = prev.hitCell or prev.path[#prev.path] or { x = tx, y = ty }
    events[#events + 1] = {
        kind = "torpedo",
        x1 = p.sx, y1 = p.sy,
        x2 = endCell.x, y2 = endCell.y,
    }
    events[#events + 1] = { kind = "sound", sound = "torpedo" }

    local hit = prev.hitEntity
    if not hit then
        Engine.addLog(state, string.format("Plasma Torpedo missed along S(%d,%d) vector.", endCell.x, endCell.y), "amber")
    elseif hit.kind == "enemy" then
        local dmg = rng:int(340, 420)
        Engine.addLog(state, string.format("Plasma Torpedo direct hit on %s (%d piercing dmg)!", hit.name, dmg), "cyan")
        applyDamageToEnemy(state, quad, hit, dmg, 0.40, rng, events)
    elseif hit.kind == "star" then
        triggerSupernova(state, quad, hit, rng, events)
    elseif hit.kind == "singularity" then
        Engine.addLog(state, string.format("Torpedo consumed by Singularity at S(%d,%d).", hit.x, hit.y), "violet")
        events[#events + 1] = { kind = "floatText", x = hit.x, y = hit.y, text = "ABSORBED", color = "violet" }
    elseif hit.kind == "planet" then
        if hit.habitable then
            hit.habitable = false
            state.score = math.max(0, state.score - 250)
            Engine.addLog(state, string.format("TRAGEDY: Torpedo struck inhabited world %s! (-250 pts)", hit.name), "crimson")
        else
            hit.hasFuel = false
            Engine.addLog(state, string.format("Torpedo impacted barren planet %s.", hit.name), "amber")
        end
        events[#events + 1] = { kind = "explosion", x = hit.x, y = hit.y, size = 0.7 }
        events[#events + 1] = { kind = "sound", sound = "explosion" }
    end

    advanceTurn(state, prev.cycleCost, false, rng, events)
    saveRng(state, rng)
    return { ok = true, msg = state.log[#state.log].text, events = events }
end

function Engine.toggleShields(state, desiredState)
    if state.status ~= "active" then
        return { ok = false, msg = "Mission has ended.", events = {} }
    end
    local p = state.player
    if desiredState == nil then
        desiredState = not p.shieldsUp
    end
    if desiredState == p.shieldsUp then
        return { ok = true, msg = p.shieldsUp and "Shields already UP." or "Shields already DOWN.", events = {} }
    end

    if desiredState then
        if p.systems.shields <= 0 then
            return { ok = false, msg = "Shield Grid offline. Repair subsystem first.", events = {} }
        end
        if p.shields <= 0 then
            return { ok = false, msg = "Shield charge is 0. Transfer energy to shields first.", events = {} }
        end
        if p.energy < 20 then
            return { ok = false, msg = "Need 20 energy activation surge to raise shields.", events = {} }
        end
        p.energy = p.energy - 20
        p.shieldsUp = true
        Engine.addLog(state, string.format("Deflector shields RAISED (%d/%d). (-20 E surge)", p.shields, p.maxShields), "cyan")
        return { ok = true, msg = "Shields RAISED.", events = { { kind = "sound", sound = "shieldHit", volume = 0.6 } } }
    else
        p.shieldsUp = false
        Engine.addLog(state, "Deflector shields LOWERED.", "info")
        return { ok = true, msg = "Shields LOWERED.", events = { { kind = "sound", sound = "click" } } }
    end
end

function Engine.transferShieldEnergy(state, delta)
    if state.status ~= "active" then
        return { ok = false, msg = "Mission has ended.", events = {} }
    end
    local p = state.player
    delta = math.floor(tonumber(delta) or 0)
    if delta == 0 then
        return { ok = false, msg = "Specify non-zero energy amount.", events = {} }
    end
    if delta > 0 then
        local room = p.maxShields - p.shields
        local moveAmt = math.min(delta, room, p.energy)
        if moveAmt <= 0 then
            return { ok = false, msg = "Cannot transfer more energy into shields.", events = {} }
        end
        p.energy = p.energy - moveAmt
        p.shields = p.shields + moveAmt
        Engine.addLog(state, string.format("Routed +%d energy to shields (%d/%d).", moveAmt, p.shields, p.maxShields), "cyan")
        return { ok = true, msg = string.format("Shields +%d.", moveAmt), events = { { kind = "sound", sound = "click" } } }
    else
        local want = -delta
        local moveAmt = math.min(want, p.shields, p.maxEnergy - p.energy)
        if moveAmt <= 0 then
            return { ok = false, msg = "Cannot drain energy from shields.", events = {} }
        end
        p.shields = p.shields - moveAmt
        p.energy = p.energy + moveAmt
        if p.shields <= 0 then
            p.shieldsUp = false
        end
        Engine.addLog(state, string.format("Recovered +%d energy from shields.", moveAmt), "info")
        return { ok = true, msg = string.format("Recovered +%d energy.", moveAmt), events = { { kind = "sound", sound = "click" } } }
    end
end

function Engine.useAuxReserve(state)
    if state.status ~= "active" then
        return { ok = false, msg = "Mission has ended.", events = {} }
    end
    local p = state.player
    if p.auxReserve <= 0 then
        return { ok = false, msg = "Auxiliary battery reserve depleted.", events = {} }
    end
    local room = p.maxEnergy - p.energy
    if room <= 0 then
        return { ok = false, msg = "Main reactor energy already at capacity.", events = {} }
    end
    local transfer = math.min(p.auxReserve, room)
    p.auxReserve = p.auxReserve - transfer
    p.energy = p.energy + transfer
    Engine.addLog(state, string.format("Auxiliary battery discharged +%d energy to main grid!", transfer), "emerald")
    return {
        ok = true,
        msg = string.format("+%d energy from Aux Reserve.", transfer),
        events = {
            { kind = "sound", sound = "dock", volume = 0.7 },
            { kind = "floatText", x = p.sx, y = p.sy, text = "+" .. transfer .. " E", color = "emerald" },
        },
    }
end

function Engine.activeScan(state)
    if state.status ~= "active" then
        return { ok = false, msg = "Mission has ended.", events = {} }
    end
    local p = state.player
    local rng = makeRng(state)
    local events = {}
    local quad = Engine.currentQuad(state)

    local radius = (p.systems.scanner > 20) and 1 or 0
    Galaxy.revealAround(state.galaxy, p.qx, p.qy, state.cycle + 0.25, radius)

    local decloaked = 0
    for _, e in ipairs(Galaxy.getEnemies(quad, true)) do
        if e.cloaked then
            e.cloaked = false
            e.decloakTurns = 2
            decloaked = decloaked + 1
        end
    end

    local minedMsg = ""
    local planet = Engine.getAdjacentMineablePlanet(state)
    if planet then
        planet.mined = true
        local gain = math.min(planet.fuelAmount, p.maxEnergy - p.energy)
        p.energy = p.energy + gain
        state.stats.planetsMined = state.stats.planetsMined + 1
        state.score = state.score + 75
        minedMsg = string.format(" Harvested +%d fuel energy from %s (+75 pts)!", gain, planet.name)
        events[#events + 1] = { kind = "floatText", x = planet.x, y = planet.y, text = "+" .. gain .. " FUEL", color = "emerald" }
    end

    events[#events + 1] = { kind = "scanPulse" }
    events[#events + 1] = { kind = "sound", sound = "scan" }

    local decloakMsg = (decloaked > 0) and string.format(" %d stealth vessel(s) decloaked!", decloaked) or ""
    local scanScope = (radius == 1) and "3x3 neighborhood" or "local quadrant (Deep Scanner damaged)"
    Engine.addLog(state, "Active Scan updated " .. scanScope .. "." .. decloakMsg .. minedMsg, "cyan")

    advanceTurn(state, 0.25, false, rng, events)
    saveRng(state, rng)
    return { ok = true, msg = state.log[#state.log].text, events = events }
end

function Engine.launchProbe(state, tqx, tqy)
    if state.status ~= "active" then
        return { ok = false, msg = "Mission has ended.", events = {} }
    end
    local p = state.player
    if p.systems.scanner <= 0 then
        return { ok = false, msg = "Deep Scanner offline. Repair subsystem to launch probes." }
    end
    if p.probes <= 0 then
        return { ok = false, msg = "No Recon Probes remaining. Dock at an Outpost to restock." }
    end
    if tqx < 1 or tqx > C.GRID_SIZE or tqy < 1 or tqy > C.GRID_SIZE then
        return { ok = false, msg = "Target quadrant out of bounds (1-8)." }
    end

    local rng = makeRng(state)
    local events = {}
    p.probes = p.probes - 1
    state.stats.probesLaunched = state.stats.probesLaunched + 1

    local offsets = { {0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1} }
    local revealed = 0
    for _, off in ipairs(offsets) do
        local q = Galaxy.getQuad(state.galaxy, tqx + off[1], tqy + off[2])
        if q then
            q.explored = true
            q.scannedCycle = state.cycle + 0.25
            revealed = revealed + 1
        end
    end

    events[#events + 1] = { kind = "scanPulse" }
    events[#events + 1] = { kind = "sound", sound = "scan" }
    Engine.addLog(state, string.format("Recon Probe telemetry received from Q(%d,%d) (+%d cross-section quads).", tqx, tqy, revealed - 1), "cyan")

    advanceTurn(state, 0.25, false, rng, events)
    saveRng(state, rng)
    return { ok = true, msg = state.log[#state.log].text, events = events }
end

function Engine.dock(state)
    if state.status ~= "active" then
        return { ok = false, msg = "Mission has ended.", events = {} }
    end
    local can, outpost = Engine.canDock(state)
    if not can then
        return { ok = false, msg = "Must be adjacent to an Orbital Outpost to dock.", events = {} }
    end

    local rng = makeRng(state)
    local events = {}
    local p = state.player
    local quad = Engine.currentQuad(state)

    p.docked = true
    p.shieldsUp = false
    p.activePath = nil
    p.targetHeading = nil
    p.speed = 0
    p.speedSetting = 0
    p.hull = p.maxHull
    p.energy = p.maxEnergy
    p.shields = math.floor(p.maxShields * 0.75)
    p.torpedoes = p.maxTorpedoes
    p.probes = p.maxProbes
    p.auxReserve = p.maxAuxReserve
    p.beamHeat = 0
    p.lifeSupportTimer = 3.0
    for _, sub in ipairs(C.SUBSYSTEMS) do
        p.systems[sub.key] = 100
    end

    events[#events + 1] = { kind = "sound", sound = "dock" }
    events[#events + 1] = { kind = "floatText", x = p.sx, y = p.sy, text = "REARMED & REPAIRED", color = "emerald" }

    -- Outpost defensive turret hits any hostiles in the quadrant
    local enemies = Galaxy.getEnemies(quad, false)
    if #enemies > 0 then
        local target = enemies[1]
        events[#events + 1] = { kind = "beam", x1 = outpost.x, y1 = outpost.y, x2 = target.x, y2 = target.y, color = "emerald" }
        Engine.addLog(state, string.format("Docked at %s: full hull/ammo/systems restored! Defense turret fires on %s.", outpost.name, target.name), "emerald")
        applyDamageToEnemy(state, quad, target, 180, 0.2, rng, events)
    else
        Engine.addLog(state, string.format("Docked at %s: ship fully repaired, refueled, and rearmed.", outpost.name), "emerald")
    end

    advanceTurn(state, 0.5, true, rng, events)
    saveRng(state, rng)
    return { ok = true, msg = state.log[#state.log].text, events = events }
end

function Engine.fieldRepair(state)
    if state.status ~= "active" then
        return { ok = false, msg = "Mission has ended.", events = {} }
    end
    local rng = makeRng(state)
    local events = {}
    local p = state.player

    local eGain = math.min(180, p.maxEnergy - p.energy)
    p.energy = p.energy + eGain
    p.beamHeat = math.max(0, p.beamHeat - 50)

    local repairedAny = false
    for _, sub in ipairs(C.SUBSYSTEMS) do
        local cur = p.systems[sub.key]
        if cur < 100 then
            local boost = (p.prioritySystem == sub.key) and 30 or 12
            p.systems[sub.key] = math.min(100, cur + boost)
            repairedAny = true
        end
    end

    events[#events + 1] = { kind = "sound", sound = "repair" }
    if eGain > 0 then
        events[#events + 1] = { kind = "floatText", x = p.sx, y = p.sy, text = "+" .. eGain .. " E", color = "emerald" }
    end

    local priMsg = p.prioritySystem and (" (priority: " .. p.prioritySystem:upper() .. ")") or ""
    Engine.addLog(state, string.format("Field repair cycle complete: +%d reactor E%s.%s",
        eGain, repairedAny and ", subsystems patched" or "", priMsg), "emerald")

    advanceTurn(state, 1.0, false, rng, events)
    saveRng(state, rng)
    return { ok = true, msg = state.log[#state.log].text, events = events }
end

function Engine.setRepairPriority(state, sysKey)
    if not sysKey then
        state.player.prioritySystem = nil
        return { ok = true, msg = "Cleared repair priority.", events = { { kind = "sound", sound = "click" } } }
    end
    local found = nil
    local needle = sysKey:lower()
    for _, sub in ipairs(C.SUBSYSTEMS) do
        if sub.key:lower() == needle or sub.short:lower() == needle or sub.label:lower():find(needle, 1, true) then
            found = sub
            break
        end
    end
    if not found then
        return { ok = false, msg = "Unknown subsystem '" .. tostring(sysKey) .. "'.", events = {} }
    end
    if state.player.prioritySystem == found.key then
        state.player.prioritySystem = nil
        Engine.addLog(state, "Cleared repair priority (" .. found.label .. ").", "info")
        return { ok = true, msg = "Cleared priority.", events = { { kind = "sound", sound = "click" } } }
    else
        state.player.prioritySystem = found.key
        Engine.addLog(state, "Engineering priority assigned to " .. found.label .. ".", "cyan")
        return { ok = true, msg = "Priority: " .. found.label, events = { { kind = "sound", sound = "click" } } }
    end
end

function Engine.calculateFinalScore(state)
    local diff = C.DIFFICULTIES[state.difficulty] or C.DIFFICULTIES.captain
    local base = state.score
    local timeBonus = 0
    local outpostBonus = Galaxy.countTotalOutposts(state.galaxy) * 200
    local hullBonus = 0

    if state.status == "victory" then
        timeBonus = math.max(0, math.floor((state.maxCycles - state.cycle) * 45))
        hullBonus = math.floor((state.player.hull / state.player.maxHull) * 300)
    end

    local rawTotal = base + timeBonus + outpostBonus + hullBonus
    local finalScore = math.floor(rawTotal * diff.scoreMult)

    local rank
    if state.status ~= "victory" then
        rank = (state.stats.totalKills >= 8) and "Commander (MIA)" or "Ensign (MIA)"
    elseif finalScore >= 6500 then
        rank = "Fleet Admiral"
    elseif finalScore >= 5000 then
        rank = "Rear Admiral"
    elseif finalScore >= 3800 then
        rank = "Commodore"
    elseif finalScore >= 2800 then
        rank = "Captain"
    elseif finalScore >= 1800 then
        rank = "Commander"
    else
        rank = "Lieutenant"
    end

    return {
        combatScore = base,
        timeBonus = timeBonus,
        outpostBonus = outpostBonus,
        hullBonus = hullBonus,
        multiplier = diff.scoreMult,
        total = finalScore,
        rank = rank,
    }
end

-- ======================== REAL-TIME / TACTICAL PAUSE (PHASE 1) ========================

local COMBAT_CALLBACKS = {
    applyEnemyDamage = function(state, quad, enemy, dmg, shieldBypass, impactCtx, rng, events)
        return applyDamageToEnemy(state, quad, enemy, dmg, shieldBypass, rng, events, impactCtx)
    end,
    applyPlayerDamage = function(state, dmg, sourceName, impactCtx, rng, events, fxX, fxY)
        return applyDamageToPlayer(state, dmg, sourceName, rng, events, impactCtx, fxX, fxY)
    end,
    triggerSupernova = triggerSupernova,
    addLog = function(state, text, level)
        Engine.addLog(state, text, level)
    end,
}

function Engine.ensureRealtimeState(state)
    if not state then return end
    if state.paused == nil then
        state.paused = true
    end
    state.simTime = state.simTime or 0
    Movement.ensurePlayerKinematics(state.player)
    Combat.ensureCombatState(state)
end

function Engine.setPaused(state, paused)
    if not state then
        return { ok = false, msg = "No active mission.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    state.paused = (paused == true)
    local msg = state.paused and "Tactical Pause ENGAGED." or "Real-time simulation RESUMED."
    return { ok = true, paused = state.paused, msg = msg, events = {} }
end

function Engine.togglePause(state)
    if not state then
        return { ok = false, msg = "No active mission.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    return Engine.setPaused(state, not state.paused)
end

function Engine.setSpeedSetting(state, ratio)
    if not state or state.status ~= "active" then
        return { ok = false, msg = "Mission is not active.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local r = clamp(tonumber(ratio) or 0, 0, 1)
    state.player.speedSetting = r
    if r > 0 then
        state.player.docked = false
    end
    local label = Movement.getThrottleLabel(r)
    local msg = string.format("Helm throttle set to %s (target %d u/s).", label, math.floor(state.player.maxSpeed * r + 0.5))
    Engine.addLog(state, msg, "cyan")
    return {
        ok = true,
        speedSetting = r,
        msg = msg,
        events = { { kind = "sound", sound = "click", volume = 0.7 } },
    }
end

function Engine.setPlayerPath(state, path)
    if not state or state.status ~= "active" then
        return { ok = false, msg = "Mission is not active.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local p = state.player
    if p.systems and p.systems.thrusters <= 0 then
        return { ok = false, msg = "Thrusters offline. Use Repair or Field Fix first.", events = {} }
    end
    if not path then
        return { ok = false, msg = "Invalid maneuver curve.", events = {} }
    end

    p.activePath = path
    p.targetHeading = nil
    p.docked = false

    if path.kind == "bezier" and (p.speedSetting or 0) <= 0.001 then
        p.speedSetting = 0.70
    end

    local destSx, destSy = Movement.worldToSector(path.p3.x, path.p3.y)
    local exitDeg = math.floor((math.deg(path.endHeading or 0) % 360) + 0.5) % 360
    local msg
    if path.kind == "turn" then
        msg = string.format("Helm ordered to turn in place to heading %03d deg.", exitDeg)
    else
        msg = string.format("Plotted vector course -> S(%d,%d), exit hdg %03d deg (len %.0f u).",
            destSx, destSy, exitDeg, path.totalLength or 0)
    end
    Engine.addLog(state, msg, "cyan")
    return {
        ok = true,
        path = path,
        msg = msg,
        events = { { kind = "sound", sound = "click", volume = 0.8 } },
    }
end

function Engine.plotPlayerCourse(state, destX, destY, exitHeading, exitHandleLen)
    if not state or state.status ~= "active" then
        return { ok = false, msg = "Mission is not active.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local p = state.player
    local curve = Movement.buildCurve(p.x, p.y, p.heading, destX, destY, exitHeading, exitHandleLen)
    if not curve then
        return { ok = false, msg = "Destination too close to plot course.", events = {} }
    end
    return Engine.setPlayerPath(state, curve)
end

function Engine.clearPlayerPath(state)
    if not state then
        return { ok = false, msg = "No active mission.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    state.player.activePath = nil
    state.player.targetHeading = nil
    Engine.addLog(state, "Plotted course cleared.", "info")
    return { ok = true, msg = "Plotted course cleared.", events = {} }
end

-- ======================== PHASE 2 TARGETING & WEAPON CONTROLS ========================

function Engine.setTarget(state, targetId)
    if not state or state.status ~= "active" then
        return { ok = false, msg = "Mission is not active.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    if targetId == nil then
        return Engine.clearTarget(state)
    end
    local quad = Engine.currentQuad(state)
    local tgt = quad and Galaxy.getEntityById(quad, targetId) or nil
    if not tgt or tgt.kind ~= "enemy" then
        return { ok = false, msg = "Selected target no longer valid.", events = {} }
    end
    if tgt.cloaked then
        return { ok = false, msg = "Target is masked by stealth cloak. Run Active Scan (7) to reveal!", events = {} }
    end
    state.player.targetId = tgt.id
    local msg = string.format("Primary target designated: %s [%s] at S(%d,%d).", tgt.name, tgt.code, tgt.x, tgt.y)
    Engine.addLog(state, msg, "cyan")
    return {
        ok = true,
        target = tgt,
        msg = msg,
        events = { { kind = "sound", sound = "click", volume = 0.7 } },
    }
end

function Engine.clearTarget(state)
    if not state then
        return { ok = false, msg = "No active mission.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local hadTarget = state.player.targetId ~= nil
    state.player.targetId = nil
    if hadTarget then
        Engine.addLog(state, "Primary target designation cleared.", "info")
    end
    return {
        ok = true,
        msg = "Target designation cleared.",
        events = { { kind = "sound", sound = "click", volume = 0.6 } },
    }
end

function Engine.cycleTarget(state, dir)
    if not state or state.status ~= "active" then
        return { ok = false, msg = "Mission is not active.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local p = state.player
    local quad = Engine.currentQuad(state)
    local hostiles = Combat.getVisibleHostiles(quad, p.x, p.y)
    if #hostiles == 0 then
        p.targetId = nil
        local hidden = Galaxy.getEnemies(quad, true)
        if #hidden > 0 then
            return { ok = false, msg = "Only cloaked contacts detected. Run Active Scan (7) to reveal!", events = {} }
        end
        return { ok = false, msg = "No visible hostile contacts in quadrant.", events = {} }
    end

    local curIdx = nil
    if p.targetId then
        for i, e in ipairs(hostiles) do
            if e.id == p.targetId then
                curIdx = i
                break
            end
        end
    end

    local step = (dir == -1) and -1 or 1
    local nextIdx
    if not curIdx then
        nextIdx = (step < 0) and #hostiles or 1
    else
        nextIdx = ((curIdx - 1 + step) % #hostiles) + 1
    end
    return Engine.setTarget(state, hostiles[nextIdx].id)
end

function Engine.setBeamMode(state, mode)
    if not state or state.status ~= "active" then
        return { ok = false, msg = "Mission is not active.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local beams = state.player.weapons.beams
    if mode == nil then
        mode = (beams.mode == "focused") and "spread" or "focused"
    else
        mode = tostring(mode):lower()
        if mode ~= "focused" and mode ~= "spread" then
            return { ok = false, msg = "Usage: BEAMMODE <focused|spread>", events = {} }
        end
    end
    beams.mode = mode
    local msg = (mode == "spread")
        and "Beam Array mode set to SPREAD (multi-target within 180 deg bow arc)."
        or "Beam Array mode set to FOCUSED (concentrated fire on primary target)."
    Engine.addLog(state, msg, "cyan")
    return {
        ok = true,
        mode = mode,
        msg = msg,
        events = { { kind = "sound", sound = "click", volume = 0.7 } },
    }
end

function Engine.setWeaponAutoFire(state, weaponKey, enabled)
    if not state or state.status ~= "active" then
        return { ok = false, msg = "Mission is not active.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local w = state.player.weapons
    local key = weaponKey and tostring(weaponKey):lower() or "all"
    if key == "torp" or key == "torpedo" then
        key = "torpedoes"
    elseif key == "beam" then
        key = "beams"
    end

    if key ~= "beams" and key ~= "torpedoes" and key ~= "all" then
        return { ok = false, msg = "Usage: AUTOFIRE <beams|torp|all> [on|off]", events = {} }
    end

    local newVal
    if enabled == nil then
        if key == "all" then
            newVal = not (w.beams.autoFire and w.torpedoes.autoFire)
        else
            newVal = not w[key].autoFire
        end
    else
        newVal = (enabled == true)
    end

    if key == "beams" or key == "all" then
        w.beams.autoFire = newVal
    end
    if key == "torpedoes" or key == "all" then
        w.torpedoes.autoFire = newVal
    end

    local targetLabel = (key == "all") and "All Weapons" or ((key == "beams") and "Beam Array" or "Torpedo Tubes")
    local msg = string.format("%s auto-fire %s.", targetLabel, newVal and "ENGAGED" or "HELD")
    Engine.addLog(state, msg, "cyan")
    return {
        ok = true,
        autoFire = newVal,
        msg = msg,
        events = { { kind = "sound", sound = "click", volume = 0.7 } },
    }
end

function Engine.setShowFiringArcs(state, show)
    if not state then
        return { ok = false, msg = "No active mission.", events = {} }
    end
    Engine.ensureRealtimeState(state)
    local p = state.player
    if show == nil then
        p.showFiringArcs = not p.showFiringArcs
    else
        p.showFiringArcs = (show == true)
    end
    local msg = "Tactical firing arcs " .. (p.showFiringArcs and "SHOWN." or "HIDDEN.")
    return {
        ok = true,
        showFiringArcs = p.showFiringArcs,
        msg = msg,
        events = { { kind = "sound", sound = "click", volume = 0.6 } },
    }
end

function Engine.getWeaponStatus(state)
    if not state then return nil end
    return Combat.getWeaponStatus(state, Engine.currentQuad(state))
end

function Engine.updateRealtime(state, dt)
    if not state then
        return { stepped = false, events = {} }
    end
    Engine.ensureRealtimeState(state)
    if state.status ~= "active" or state.paused or not dt or dt <= 0 then
        return { stepped = false, events = {} }
    end

    local stepDt = math.min(dt, 0.1)
    state.simTime = (state.simTime or 0) + stepDt

    local quad = Engine.currentQuad(state)
    local completed = Movement.stepPlayer(state.player, quad, stepDt)
    if completed then
        local p = state.player
        local hdgDeg = math.floor((math.deg(p.heading) % 360) + 0.5) % 360
        Engine.addLog(state, string.format("Course complete: holding station at S(%d,%d) Hdg %03d deg.", p.sx, p.sy, hdgDeg), "cyan")
    end

    local events = {}
    local rng = makeRng(state)
    local didCombat = Combat.stepRealtime(state, quad, stepDt, rng, events, COMBAT_CALLBACKS)
    if didCombat then
        Engine.evaluateEndConditions(state, events)
    end
    saveRng(state, rng)

    return {
        stepped = true,
        completedPath = completed,
        events = events,
    }
end

return Engine
