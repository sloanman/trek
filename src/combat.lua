-- Real-time weapons charging, target designation, 180 deg firing arcs, auto-fire & projectiles

local C = require("src.constants")
local Galaxy = require("src.galaxy")
local Movement = require("src.movement")

local Combat = {}

function Combat.getEntityWorldPos(ent)
    return Movement.sectorToWorld(ent.x, ent.y)
end

-- Matches Animations.lua's tileCenter mapping (tile 1..8 center = wx/100 + 0.5)
function Combat.worldToTileFloat(wx, wy)
    return wx / C.SECTOR_WORLD_SCALE + 0.5, wy / C.SECTOR_WORLD_SCALE + 0.5
end

function Combat.ensureCombatState(state)
    if not state then return end
    state.projectiles = state.projectiles or {}
    state.nextProjectileId = state.nextProjectileId or 1

    local p = state.player
    if not p then return end
    if p.showFiringArcs == nil then
        p.showFiringArcs = C.COMBAT.defaultShowArcs
    end

    p.weapons = p.weapons or {}
    p.weapons.beams = p.weapons.beams or {}
    local b = p.weapons.beams
    b.charge = Movement.clamp(tonumber(b.charge) or 0, 0, 1)
    b.mode = (b.mode == "spread") and "spread" or "focused"
    if b.autoFire == nil then
        b.autoFire = true
    else
        b.autoFire = (b.autoFire == true)
    end

    p.weapons.torpedoes = p.weapons.torpedoes or {}
    local t = p.weapons.torpedoes
    t.charge = Movement.clamp(tonumber(t.charge) or 0, 0, 1)
    if t.autoFire == nil then
        t.autoFire = true
    else
        t.autoFire = (t.autoFire == true)
    end

    if p.targetId and state.galaxy then
        local quad = Galaxy.getQuad(state.galaxy, p.qx, p.qy)
        local tgt = quad and Galaxy.getEntityById(quad, p.targetId) or nil
        if not tgt or tgt.kind ~= "enemy" or tgt.cloaked then
            p.targetId = nil
        end
    end
end

function Combat.evaluateTargetGeometry(shipX, shipY, shipHeading, targetX, targetY, arcCenter, arcWidth, maxRange)
    local dx = targetX - shipX
    local dy = targetY - shipY
    local range = math.sqrt(dx * dx + dy * dy)
    local rangeSectors = range / C.SECTOR_WORLD_SCALE
    local worldBearing = (range > 1e-6) and math.atan2(dy, dx) or (shipHeading or 0)
    local relBearing = Movement.angleDiff(shipHeading or 0, worldBearing)
    local relBearingDeg = math.deg(relBearing)
    local arcAxis = Movement.normalizeAngle((shipHeading or 0) + (arcCenter or 0))
    local offsetFromArc = Movement.angleDiff(arcAxis, worldBearing)
    local halfArc = (arcWidth or math.pi) * 0.5
    local inArc = math.abs(offsetFromArc) <= (halfArc + 1e-4)
    local inRange = (maxRange == nil) or (range <= maxRange + 1e-4)

    return {
        range = range,
        rangeSectors = rangeSectors,
        worldBearing = worldBearing,
        relBearing = relBearing,
        relBearingDeg = relBearingDeg,
        offsetFromArc = offsetFromArc,
        inArc = inArc,
        inRange = inRange,
        inFiringArc = (inArc and inRange),
    }
end

-- Phase 3 hook: relative impact bearing and hull quadrant on struck vessel
function Combat.computeImpactContext(srcX, srcY, tgtX, tgtY, tgtHeading)
    local incomingAngle = math.atan2(srcY - tgtY, srcX - tgtX)
    local relImpact = Movement.angleDiff(tgtHeading or 0, incomingAngle)
    local absRel = math.abs(relImpact)
    local quadrant
    if absRel <= math.pi * 0.25 then
        quadrant = "fore"
    elseif absRel >= math.pi * 0.75 then
        quadrant = "aft"
    elseif relImpact > 0 then
        quadrant = "starboard"
    else
        quadrant = "port"
    end
    return {
        incomingAngle = incomingAngle,
        relImpact = relImpact,
        quadrant = quadrant,
    }
end

local function pointToSegmentDistSq(cx, cy, x1, y1, x2, y2)
    local vx = x2 - x1
    local vy = y2 - y1
    local lenSq = vx * vx + vy * vy
    local t = (lenSq > 1e-6) and Movement.clamp(((cx - x1) * vx + (cy - y1) * vy) / lenSq, 0, 1) or 0
    local px = x1 + vx * t
    local py = y1 + vy * t
    local dx = cx - px
    local dy = cy - py
    return dx * dx + dy * dy, t
end

function Combat.checkLineObstruction(quad, x1, y1, x2, y2, clearance)
    if not quad or not quad.entities then
        return nil, nil
    end
    local r = clearance or C.COMBAT.interlockClearance
    local rSq = r * r
    local bestOutpost, bestOutpostD = nil, rSq
    local bestStar, bestStarD = nil, rSq

    for _, ent in ipairs(quad.entities) do
        if ent.kind == "outpost" or ent.kind == "star" then
            local ex, ey = Combat.getEntityWorldPos(ent)
            local dSq = pointToSegmentDistSq(ex, ey, x1, y1, x2, y2)
            if dSq <= rSq then
                if ent.kind == "outpost" and dSq <= bestOutpostD then
                    bestOutpost = ent
                    bestOutpostD = dSq
                elseif ent.kind == "star" and dSq <= bestStarD then
                    bestStar = ent
                    bestStarD = dSq
                end
            end
        end
    end

    if bestOutpost then
        return "outpost", bestOutpost
    end
    if bestStar then
        return "star", bestStar
    end
    return nil, nil
end

function Combat.getVisibleHostiles(quad, shipX, shipY)
    local visible = Galaxy.getEnemies(quad, false)
    if not shipX or not shipY then
        table.sort(visible, function(a, b) return (a.id or 0) < (b.id or 0) end)
        return visible
    end
    table.sort(visible, function(a, b)
        local ax, ay = Combat.getEntityWorldPos(a)
        local bx, by = Combat.getEntityWorldPos(b)
        local da = (ax - shipX) ^ 2 + (ay - shipY) ^ 2
        local db = (bx - shipX) ^ 2 + (by - shipY) ^ 2
        if math.abs(da - db) > 1e-4 then
            return da < db
        end
        return (a.id or 0) < (b.id or 0)
    end)
    return visible
end

function Combat.getPrimaryTarget(state, quad)
    if not state or not state.player then return nil end
    local p = state.player
    if not p.targetId then return nil end
    quad = quad or Galaxy.getQuad(state.galaxy, p.qx, p.qy)
    local tgt = quad and Galaxy.getEntityById(quad, p.targetId) or nil
    if not tgt or tgt.kind ~= "enemy" or tgt.cloaked then
        p.targetId = nil
        return nil
    end
    return tgt
end

function Combat.getBeamTargets(state, quad)
    Combat.ensureCombatState(state)
    local p = state.player
    quad = quad or Galaxy.getQuad(state.galaxy, p.qx, p.qy)
    local spec = C.WEAPONS.beams
    local hostiles = Combat.getVisibleHostiles(quad, p.x, p.y)
    local inArcEntries = {}
    local primaryEntry = nil

    for _, e in ipairs(hostiles) do
        local ex, ey = Combat.getEntityWorldPos(e)
        local geom = Combat.evaluateTargetGeometry(p.x, p.y, p.heading, ex, ey, spec.arcCenter, spec.arcWidth, spec.range)
        if geom.inFiringArc then
            local entry = { entity = e, geom = geom }
            inArcEntries[#inArcEntries + 1] = entry
            if e.id == p.targetId then
                primaryEntry = entry
            end
        end
    end

    if p.weapons.beams.mode == "focused" then
        if primaryEntry then
            return { primaryEntry }
        end
        return {}
    end

    -- Spread mode: prioritize designated target, then up to maxSpreadTargets nearest valid targets
    local selected = {}
    local used = {}
    if primaryEntry then
        selected[1] = primaryEntry
        used[primaryEntry.entity.id] = true
    end
    for _, entry in ipairs(inArcEntries) do
        if #selected >= spec.maxSpreadTargets then
            break
        end
        if not used[entry.entity.id] then
            selected[#selected + 1] = entry
            used[entry.entity.id] = true
        end
    end
    return selected
end

function Combat.getWeaponStatus(state, quad)
    Combat.ensureCombatState(state)
    local p = state.player
    quad = quad or Galaxy.getQuad(state.galaxy, p.qx, p.qy)
    local beamSpec = C.WEAPONS.beams
    local torpSpec = C.WEAPONS.torpedoes
    local bState = p.weapons.beams
    local tState = p.weapons.torpedoes

    local hostiles = Combat.getVisibleHostiles(quad, p.x, p.y)
    local tgt = Combat.getPrimaryTarget(state, quad)
    local primaryInfo = nil
    local inBeamArc = false
    local inTorpArc = false
    local torpInterlock = false
    local torpInterlockKind = nil

    if tgt then
        local tx, ty = Combat.getEntityWorldPos(tgt)
        local bGeom = Combat.evaluateTargetGeometry(p.x, p.y, p.heading, tx, ty, beamSpec.arcCenter, beamSpec.arcWidth, beamSpec.range)
        local tGeom = Combat.evaluateTargetGeometry(p.x, p.y, p.heading, tx, ty, torpSpec.arcCenter, torpSpec.arcWidth, torpSpec.range)
        local obKind = Combat.checkLineObstruction(quad, p.x, p.y, tx, ty, C.COMBAT.interlockClearance)
        inBeamArc = bGeom.inFiringArc
        inTorpArc = tGeom.inFiringArc
        torpInterlock = (obKind ~= nil)
        torpInterlockKind = obKind
        primaryInfo = {
            entity = tgt,
            geom = bGeom,
            torpGeom = tGeom,
            inBeamArc = inBeamArc,
            inTorpArc = inTorpArc,
            torpInterlock = torpInterlock,
            torpInterlockKind = obKind,
        }
    end

    local beamTargets = Combat.getBeamTargets(state, quad)
    local beamReady = false
    local beamText
    if (p.systems and p.systems.beams or 0) <= 0 then
        beamText = "OFFLINE"
    elseif p.docked then
        beamText = "DOCKED"
    elseif (p.beamHeat or 0) >= 100 then
        beamText = "OVERHEAT"
    elseif not bState.autoFire then
        beamText = "HOLD"
    elseif (p.energy or 0) < beamSpec.energyCost then
        beamText = "LOW E"
    elseif #beamTargets == 0 then
        if bState.mode == "focused" and not tgt then
            beamText = "NO TGT"
        elseif #hostiles == 0 then
            beamText = "NO TGT"
        else
            beamText = "OUT ARC"
        end
    elseif bState.charge >= 1 then
        beamText = "READY"
        beamReady = true
    else
        beamText = "CHARGING"
    end

    local torpReady = false
    local torpText
    if (p.systems and p.systems.torpedoes or 0) <= 0 then
        torpText = "OFFLINE"
    elseif (p.torpedoes or 0) <= 0 then
        torpText = "EMPTY"
    elseif p.docked then
        torpText = "DOCKED"
    elseif not tState.autoFire then
        torpText = "MANUAL"
    elseif (p.energy or 0) < torpSpec.energyCost then
        torpText = "LOW E"
    elseif not tgt then
        torpText = "NO TGT"
    elseif not inTorpArc then
        torpText = "OUT ARC"
    elseif torpInterlock then
        torpText = "INTERLOCK"
    elseif tState.charge >= 1 then
        torpText = "READY"
        torpReady = true
    else
        torpText = "CHARGING"
    end

    return {
        primary = primaryInfo,
        inBeamArc = inBeamArc,
        inTorpArc = inTorpArc,
        torpInterlock = torpInterlock,
        torpInterlockKind = torpInterlockKind,
        beams = {
            charge = bState.charge,
            mode = bState.mode,
            autoFire = bState.autoFire,
            inArcTargets = beamTargets,
            ready = beamReady,
            statusText = beamText,
        },
        torpedoes = {
            charge = tState.charge,
            autoFire = tState.autoFire,
            ammo = p.torpedoes or 0,
            maxAmmo = p.maxTorpedoes or 0,
            primaryInArc = inTorpArc,
            interlock = torpInterlock,
            ready = torpReady,
            statusText = torpText,
        },
    }
end

function Combat.evaluateCurveArcCoverage(curve, quad, primaryTargetId)
    if not curve or not quad then
        return nil
    end
    local beamSpec = C.WEAPONS.beams
    local torpSpec = C.WEAPONS.torpedoes
    local enemies = Combat.getVisibleHostiles(quad, curve.p3.x, curve.p3.y)

    local byEnemyId = {}
    for _, e in ipairs(enemies) do
        local ex, ey = Combat.getEntityWorldPos(e)
        local endBeam = Combat.evaluateTargetGeometry(curve.p3.x, curve.p3.y, curve.endHeading, ex, ey, beamSpec.arcCenter, beamSpec.arcWidth, beamSpec.range)
        local endTorp = Combat.evaluateTargetGeometry(curve.p3.x, curve.p3.y, curve.endHeading, ex, ey, torpSpec.arcCenter, torpSpec.arcWidth, torpSpec.range)
        byEnemyId[e.id] = {
            entity = e,
            inBeamAtEnd = endBeam.inFiringArc,
            inTorpAtEnd = endTorp.inFiringArc,
            inBeamAlongCurve = endBeam.inFiringArc,
            inTorpAlongCurve = endTorp.inFiringArc,
            destRange = endBeam.range,
            destRelBearingDeg = endBeam.relBearingDeg,
        }
    end

    local pts = curve.points or { { x = curve.p3.x, y = curve.p3.y } }
    local segmentInBeam = {}
    local n = #pts

    for i = 1, n do
        local pt = pts[i]
        local ptHeading
        if curve.kind == "turn" or n < 2 or i == n then
            ptHeading = curve.endHeading
        elseif i == 1 then
            ptHeading = curve.startHeading or math.atan2(pts[2].y - pt.y, pts[2].x - pt.x)
        else
            ptHeading = math.atan2(pts[i + 1].y - pts[i - 1].y, pts[i + 1].x - pts[i - 1].x)
        end

        local segHit = false
        for _, e in ipairs(enemies) do
            local ex, ey = Combat.getEntityWorldPos(e)
            local bGeom = Combat.evaluateTargetGeometry(pt.x, pt.y, ptHeading, ex, ey, beamSpec.arcCenter, beamSpec.arcWidth, beamSpec.range)
            local tGeom = Combat.evaluateTargetGeometry(pt.x, pt.y, ptHeading, ex, ey, torpSpec.arcCenter, torpSpec.arcWidth, torpSpec.range)
            local info = byEnemyId[e.id]
            if bGeom.inFiringArc then
                info.inBeamAlongCurve = true
                if (not primaryTargetId) or (e.id == primaryTargetId) then
                    segHit = true
                end
            end
            if tGeom.inFiringArc then
                info.inTorpAlongCurve = true
            end
        end
        segmentInBeam[i] = segHit
    end

    return {
        byEnemyId = byEnemyId,
        segmentInBeam = segmentInBeam,
    }
end

local function stepPlayerBeams(state, quad, dt, rng, events, callbacks)
    local p = state.player
    local b = p.weapons.beams
    local spec = C.WEAPONS.beams
    local beamSys = (p.systems and p.systems.beams) or 0

    if beamSys > 0 and (p.beamHeat or 0) < 100 then
        local eff = 0.35 + 0.65 * (beamSys / 100)
        b.charge = math.min(1, b.charge + (dt / spec.chargeTime) * eff)
    end

    if not b.autoFire or b.charge < 1 or p.docked or (p.energy or 0) < spec.energyCost or (p.beamHeat or 0) >= 100 then
        return false
    end

    local targets = Combat.getBeamTargets(state, quad)
    if #targets == 0 then
        return false
    end

    local eff = 0.35 + 0.65 * (beamSys / 100)
    local stormMult = quad.ionStorm and 0.72 or 1.0
    local numTargets = #targets
    local dmgShare = (numTargets > 1) and (spec.spreadTotalMult / numTargets) or 1.0
    local pxT, pyT = Combat.worldToTileFloat(p.x, p.y)

    p.energy = p.energy - spec.energyCost
    p.beamHeat = math.min(100, (p.beamHeat or 0) + spec.heatPerShot)
    b.charge = 0
    events[#events + 1] = { kind = "sound", sound = "beam", volume = 0.85 }

    local beamColor = (b.mode == "spread" and numTargets > 1) and "emerald" or "cyan"
    for _, entry in ipairs(targets) do
        local enemy = entry.entity
        local ex, ey = Combat.getEntityWorldPos(enemy)
        local falloff = Movement.clamp(1 / (0.85 + 0.12 * entry.geom.rangeSectors), 0.60, 1.05)
        local jitter = rng:float(0.92, 1.08)
        local dmg = math.max(12, math.floor(spec.baseDamage * dmgShare * eff * stormMult * falloff * jitter))
        local impactCtx = Combat.computeImpactContext(p.x, p.y, ex, ey, enemy.heading)

        events[#events + 1] = {
            kind = "beam",
            x1 = pxT,
            y1 = pyT,
            x2 = enemy.x,
            y2 = enemy.y,
            color = beamColor,
        }
        callbacks.applyEnemyDamage(state, quad, enemy, dmg, spec.shieldBypass, impactCtx, rng, events)
    end

    if numTargets > 1 then
        callbacks.addLog(state, string.format("Spread Beam volley engaged %d targets (-%d E).", numTargets, spec.energyCost), "cyan")
    else
        callbacks.addLog(state, string.format("Beam Array locked & fired on %s (-%d E).", targets[1].entity.name, spec.energyCost), "cyan")
    end
    return true
end

local function stepPlayerTorpedoes(state, quad, dt, rng, events, callbacks)
    local p = state.player
    local t = p.weapons.torpedoes
    local spec = C.WEAPONS.torpedoes
    local torpSys = (p.systems and p.systems.torpedoes) or 0

    if torpSys > 0 and (p.torpedoes or 0) > 0 then
        local eff = 0.35 + 0.65 * (torpSys / 100)
        t.charge = math.min(1, t.charge + (dt / spec.chargeTime) * eff)
    end

    if not t.autoFire or t.charge < 1 or p.docked or (p.torpedoes or 0) <= 0 or (p.energy or 0) < spec.energyCost then
        return false
    end

    local tgt = Combat.getPrimaryTarget(state, quad)
    if not tgt then
        return false
    end

    local tx, ty = Combat.getEntityWorldPos(tgt)
    local geom = Combat.evaluateTargetGeometry(p.x, p.y, p.heading, tx, ty, spec.arcCenter, spec.arcWidth, spec.range)
    if not geom.inFiringArc then
        return false
    end

    local obKind = Combat.checkLineObstruction(quad, p.x, p.y, tx, ty, C.COMBAT.interlockClearance)
    if obKind ~= nil then
        return false
    end

    p.energy = p.energy - spec.energyCost
    p.torpedoes = p.torpedoes - 1
    t.charge = 0

    local launchAngle = math.atan2(ty - p.y, tx - p.x)
    local projId = state.nextProjectileId or 1
    state.nextProjectileId = projId + 1
    state.projectiles[#state.projectiles + 1] = {
        id = projId,
        kind = "torpedo",
        x = p.x + math.cos(launchAngle) * 18,
        y = p.y + math.sin(launchAngle) * 18,
        heading = launchAngle,
        speed = spec.projectileSpeed,
        maxRange = spec.range + 90,
        traveled = 0,
        targetId = tgt.id,
        dmgMin = spec.minDamage,
        dmgMax = spec.maxDamage,
        shieldBypass = spec.shieldBypass,
    }

    events[#events + 1] = { kind = "sound", sound = "torpedo", volume = 0.85 }
    callbacks.addLog(state, string.format("Auto-launched Plasma Torpedo -> %s (%d left).", tgt.name, p.torpedoes), "amber")
    return true
end

local function stepProjectiles(state, quad, dt, rng, events, callbacks)
    local list = state.projectiles
    if not list or #list == 0 then
        return false
    end

    local didImpact = false
    local hitRadius = C.WEAPONS.torpedoes.hitRadius
    local hitRadiusSq = hitRadius * hitRadius
    local obsRadiusSq = 26 * 26

    for i = #list, 1, -1 do
        local proj = list[i]

        -- Subtle terminal guidance toward locked target if still visible
        if proj.targetId then
            local lockTgt = Galaxy.getEntityById(quad, proj.targetId)
            if lockTgt and lockTgt.kind == "enemy" and not lockTgt.cloaked then
                local ltx, lty = Combat.getEntityWorldPos(lockTgt)
                local wantHdg = math.atan2(lty - proj.y, ltx - proj.x)
                proj.heading = Movement.steerToward(proj.heading, wantHdg, 2.8 * dt)
            end
        end

        local stepDist = (proj.speed or 320) * dt
        proj.x = proj.x + math.cos(proj.heading) * stepDist
        proj.y = proj.y + math.sin(proj.heading) * stepDist
        proj.traveled = (proj.traveled or 0) + stepDist

        local removeProj = false
        local outOfBounds = proj.x < 0 or proj.x > C.WORLD_SIZE or proj.y < 0 or proj.y > C.WORLD_SIZE
            or proj.traveled >= (proj.maxRange or 650)

        -- Check visible hostile hits first
        if not outOfBounds then
            for _, e in ipairs(quad.entities) do
                if e.kind == "enemy" and not e.cloaked then
                    local ex, ey = Combat.getEntityWorldPos(e)
                    local dSq = (proj.x - ex) ^ 2 + (proj.y - ey) ^ 2
                    if dSq <= hitRadiusSq then
                        local dmg = rng:int(proj.dmgMin or 260, proj.dmgMax or 330)
                        local impactCtx = Combat.computeImpactContext(
                            proj.x - math.cos(proj.heading) * 40,
                            proj.y - math.sin(proj.heading) * 40,
                            ex, ey, e.heading
                        )
                        events[#events + 1] = { kind = "explosion", x = e.x, y = e.y, size = 0.65 }
                        events[#events + 1] = { kind = "sound", sound = "hullHit", volume = 0.85 }
                        callbacks.addLog(state, string.format("Plasma Torpedo hit %s (%d piercing dmg)!", e.name, dmg), "cyan")
                        callbacks.applyEnemyDamage(state, quad, e, dmg, proj.shieldBypass or 0.40, impactCtx, rng, events)
                        didImpact = true
                        removeProj = true
                        break
                    end
                end
            end
        end

        -- Check environmental entity collisions if still flying
        if not removeProj and not outOfBounds then
            for _, e in ipairs(quad.entities) do
                if e.kind == "singularity" or e.kind == "star" or e.kind == "planet" or e.kind == "outpost" then
                    local ex, ey = Combat.getEntityWorldPos(e)
                    local dSq = (proj.x - ex) ^ 2 + (proj.y - ey) ^ 2
                    if dSq <= obsRadiusSq then
                        if e.kind == "singularity" then
                            events[#events + 1] = { kind = "floatText", x = e.x, y = e.y, text = "ABSORBED", color = "violet" }
                            callbacks.addLog(state, "Plasma Torpedo consumed by Singularity.", "violet")
                        elseif e.kind == "star" then
                            callbacks.triggerSupernova(state, quad, e, rng, events)
                        elseif e.kind == "planet" then
                            events[#events + 1] = { kind = "explosion", x = e.x, y = e.y, size = 0.6 }
                            events[#events + 1] = { kind = "sound", sound = "explosion", volume = 0.7 }
                        elseif e.kind == "outpost" then
                            events[#events + 1] = { kind = "floatText", x = e.x, y = e.y, text = "INTERLOCK", color = "amber" }
                        end
                        didImpact = true
                        removeProj = true
                        break
                    end
                end
            end
        end

        if removeProj or outOfBounds then
            table.remove(list, i)
        end
    end

    return didImpact
end

local function stepEnemies(state, quad, dt, rng, events, callbacks)
    local p = state.player
    if p.docked or (p.hull or 0) <= 0 then
        return false
    end

    local didFire = false
    local pxT, pyT = Combat.worldToTileFloat(p.x, p.y)

    for _, e in ipairs(quad.entities) do
        if (p.hull or 0) <= 0 then
            break
        end
        if e.kind == "enemy" and not e.cloaked then
            local spec = C.ENEMY_SPECS[e.class] or C.ENEMY_SPECS.raider
            local ex, ey = Combat.getEntityWorldPos(e)
            local toPlayer = math.atan2(p.y - ey, p.x - ex)

            if e.heading == nil then
                e.heading = toPlayer
            end
            e.heading = Movement.steerToward(e.heading, toPlayer, (spec.turnRate or 0.8) * dt)

            local chargeTime = spec.chargeTime or 4.0
            e.weaponCharge = math.min(1, (e.weaponCharge or 0) + dt / chargeTime)

            if e.weaponCharge >= 1 then
                local geom = Combat.evaluateTargetGeometry(
                    ex, ey, e.heading, p.x, p.y,
                    spec.arcCenter or 0, spec.arcWidth or math.pi, spec.weaponRange or 420
                )
                if geom.inFiringArc then
                    e.weaponCharge = 0
                    local dmg = rng:int(spec.rtMinDmg or 20, spec.rtMaxDmg or 36)
                    local impactCtx = Combat.computeImpactContext(ex, ey, p.x, p.y, p.heading)
                    events[#events + 1] = {
                        kind = "beam",
                        x1 = e.x,
                        y1 = e.y,
                        x2 = pxT,
                        y2 = pyT,
                        color = "crimson",
                    }
                    events[#events + 1] = { kind = "sound", sound = "beam", volume = 0.62 }
                    callbacks.applyPlayerDamage(state, dmg, e.name, impactCtx, rng, events, pxT, pyT)
                    didFire = true
                end
            end
        end
    end

    return didFire
end

function Combat.stepRealtime(state, quad, dt, rng, events, callbacks)
    Combat.ensureCombatState(state)
    if not state or state.status ~= "active" or not quad then
        return false
    end

    local p = state.player
    p.beamHeat = math.max(0, (p.beamHeat or 0) - C.COMBAT.beamCoolRate * dt)

    local didCombat = false
    if stepPlayerBeams(state, quad, dt, rng, events, callbacks) then
        didCombat = true
    end
    if stepPlayerTorpedoes(state, quad, dt, rng, events, callbacks) then
        didCombat = true
    end
    if stepProjectiles(state, quad, dt, rng, events, callbacks) then
        didCombat = true
    end
    if stepEnemies(state, quad, dt, rng, events, callbacks) then
        didCombat = true
    end

    Combat.ensureCombatState(state)
    return didCombat
end

return Combat
