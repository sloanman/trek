-- 8x8 Galactic Quadrant & Sector Generator

local C = require("src.constants")

local Galaxy = {}

local function keyXY(x, y)
    return y * 16 + x
end

function Galaxy.getQuad(g, qx, qy)
    if not g or not g.quadrants then return nil end
    if qx < 1 or qx > C.GRID_SIZE or qy < 1 or qy > C.GRID_SIZE then
        return nil
    end
    return g.quadrants[qy][qx]
end

function Galaxy.getEntityAt(quad, sx, sy)
    if not quad or not quad.entities then return nil end
    for i, e in ipairs(quad.entities) do
        if e.x == sx and e.y == sy then
            return e, i
        end
    end
    return nil, nil
end

function Galaxy.getEntityById(quad, id)
    if not quad or not quad.entities or not id then return nil end
    for i, e in ipairs(quad.entities) do
        if e.id == id then
            return e, i
        end
    end
    return nil, nil
end

function Galaxy.findFreeSector(quad, rng, avoidX, avoidY)
    local occupied = {}
    if avoidX and avoidY then
        occupied[keyXY(avoidX, avoidY)] = true
    end
    for _, e in ipairs(quad.entities) do
        occupied[keyXY(e.x, e.y)] = true
    end
    local free = {}
    for y = 1, C.GRID_SIZE do
        for x = 1, C.GRID_SIZE do
            if not occupied[keyXY(x, y)] then
                free[#free + 1] = { x = x, y = y }
            end
        end
    end
    if #free == 0 then
        return nil, nil
    end
    local pick = rng:pick(free)
    return pick.x, pick.y
end

function Galaxy.getEnemies(quad, includeCloaked)
    local list = {}
    if not quad or not quad.entities then return list end
    for _, e in ipairs(quad.entities) do
        if e.kind == "enemy" then
            if includeCloaked ~= false or not e.cloaked then
                list[#list + 1] = e
            end
        end
    end
    return list
end

function Galaxy.getOutpost(quad)
    if not quad or not quad.entities then return nil end
    for _, e in ipairs(quad.entities) do
        if e.kind == "outpost" then
            return e
        end
    end
    return nil
end

function Galaxy.getCounts(quad, includeCloaked)
    local counts = { enemies = 0, outposts = 0, stars = 0, planets = 0, singularities = 0 }
    if not quad or not quad.entities then return counts end
    for _, e in ipairs(quad.entities) do
        if e.kind == "enemy" then
            if includeCloaked ~= false or not e.cloaked then
                counts.enemies = counts.enemies + 1
            end
        elseif e.kind == "outpost" then
            counts.outposts = counts.outposts + 1
        elseif e.kind == "star" then
            counts.stars = counts.stars + 1
        elseif e.kind == "planet" then
            counts.planets = counts.planets + 1
        elseif e.kind == "singularity" then
            counts.singularities = counts.singularities + 1
        end
    end
    return counts
end

function Galaxy.getIntelCode(quad)
    local c = Galaxy.getCounts(quad, false)
    local e = math.min(9, c.enemies)
    local b = math.min(9, c.outposts)
    local s = math.min(9, c.stars)
    return string.format("%d%d%d", e, b, s), c
end

function Galaxy.countTotalHostiles(g)
    local total = 0
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            local q = g.quadrants[qy][qx]
            for _, e in ipairs(q.entities) do
                if e.kind == "enemy" then
                    total = total + 1
                end
            end
        end
    end
    return total
end

function Galaxy.countTotalOutposts(g)
    local total = 0
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            local q = g.quadrants[qy][qx]
            for _, e in ipairs(q.entities) do
                if e.kind == "outpost" then
                    total = total + 1
                end
            end
        end
    end
    return total
end

function Galaxy.revealAround(g, qx, qy, cycle, radius)
    radius = radius or 1
    for dy = -radius, radius do
        for dx = -radius, radius do
            local q = Galaxy.getQuad(g, qx + dx, qy + dy)
            if q then
                q.explored = true
                q.scannedCycle = cycle
            end
        end
    end
end

local function newEntityId(g)
    g.nextId = g.nextId + 1
    return g.nextId
end

function Galaxy.spawnEnemy(g, quad, enemyClass, rng, avoidX, avoidY)
    local spec = C.ENEMY_SPECS[enemyClass]
    local sx, sy = Galaxy.findFreeSector(quad, rng, avoidX, avoidY)
    if not sx then
        return nil
    end
    local e = {
        id = newEntityId(g),
        kind = "enemy",
        class = spec.class,
        name = spec.name,
        code = spec.code,
        x = sx,
        y = sy,
        shield = spec.maxShield,
        maxShield = spec.maxShield,
        hull = spec.maxHull,
        maxHull = spec.maxHull,
        minDmg = spec.minDmg,
        maxDmg = spec.maxDmg,
        score = spec.score,
        cloaked = spec.canCloak and rng:chance(0.75) or false,
        decloakTurns = 0,
    }
    quad.entities[#quad.entities + 1] = e
    return e
end

function Galaxy.generate(difficultyKey, rng, startQx, startQy)
    local diff = C.DIFFICULTIES[difficultyKey] or C.DIFFICULTIES.captain
    startQx = startQx or 4
    startQy = startQy or 4

    local g = {
        nextId = 0,
        quadrants = {},
    }

    local planetNames = {}
    for i, name in ipairs(C.PLANET_NAMES) do
        planetNames[i] = name
    end
    rng:shuffle(planetNames)
    local planetNameIdx = 1

    for qy = 1, C.GRID_SIZE do
        g.quadrants[qy] = {}
        for qx = 1, C.GRID_SIZE do
            local isStart = (qx == startQx and qy == startQy)
            local quad = {
                qx = qx,
                qy = qy,
                explored = false,
                scannedCycle = nil,
                ionStorm = (not isStart) and rng:chance(0.065),
                siege = nil,
                entities = {},
            }

            -- Stars (1 to 5)
            local starCount = rng:int(1, 5)
            for _ = 1, starCount do
                local sx, sy = Galaxy.findFreeSector(quad, rng)
                if sx then
                    quad.entities[#quad.entities + 1] = {
                        id = newEntityId(g),
                        kind = "star",
                        x = sx,
                        y = sy,
                        colorIdx = rng:int(1, #C.STAR_COLORS),
                        radius = rng:float(0.85, 1.15),
                    }
                end
            end

            -- Planets (~30% of quadrants)
            if rng:chance(0.30) then
                local sx, sy = Galaxy.findFreeSector(quad, rng)
                if sx then
                    local hasFuel = rng:chance(0.55)
                    local pname = planetNames[planetNameIdx] or ("Sector-" .. qx .. qy)
                    planetNameIdx = planetNameIdx + 1
                    quad.entities[#quad.entities + 1] = {
                        id = newEntityId(g),
                        kind = "planet",
                        name = pname,
                        x = sx,
                        y = sy,
                        hasFuel = hasFuel,
                        fuelAmount = hasFuel and rng:int(250, 450) or 0,
                        mined = false,
                        habitable = (not hasFuel) and rng:chance(0.45),
                        colorIdx = rng:int(1, 4),
                    }
                end
            end

            -- Singularities (~9% of non-start quadrants)
            if (not isStart) and rng:chance(0.09) then
                local sx, sy = Galaxy.findFreeSector(quad, rng)
                if sx then
                    quad.entities[#quad.entities + 1] = {
                        id = newEntityId(g),
                        kind = "singularity",
                        x = sx,
                        y = sy,
                        phase = rng:float(0, math.pi * 2),
                    }
                end
            end

            g.quadrants[qy][qx] = quad
        end
    end

    -- Place Orbital Outposts well-spaced across the galaxy, with #1 within Manhattan dist 1..2 of start
    local outpostCoords = {}
    local nearCandidates = {}
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            local d = math.abs(qx - startQx) + math.abs(qy - startQy)
            if d >= 1 and d <= 2 then
                nearCandidates[#nearCandidates + 1] = { qx = qx, qy = qy }
            end
        end
    end
    local firstCoord = rng:pick(nearCandidates)
    outpostCoords[1] = firstCoord

    local allCoords = {}
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            if not (qx == startQx and qy == startQy) then
                allCoords[#allCoords + 1] = { qx = qx, qy = qy }
            end
        end
    end
    rng:shuffle(allCoords)

    for minDist = 3, 1, -1 do
        if #outpostCoords >= diff.outposts then break end
        for _, c in ipairs(allCoords) do
            if #outpostCoords >= diff.outposts then break end
            local ok = true
            for _, oc in ipairs(outpostCoords) do
                local d = math.abs(c.qx - oc.qx) + math.abs(c.qy - oc.qy)
                if d < minDist then
                    ok = false
                    break
                end
            end
            if ok then
                outpostCoords[#outpostCoords + 1] = c
            end
        end
    end

    for idx, coord in ipairs(outpostCoords) do
        local quad = g.quadrants[coord.qy][coord.qx]
        local sx, sy = Galaxy.findFreeSector(quad, rng)
        if sx then
            quad.entities[#quad.entities + 1] = {
                id = newEntityId(g),
                kind = "outpost",
                name = C.OUTPOST_NAMES[idx] or ("Outpost " .. idx),
                x = sx,
                y = sy,
                hp = 500,
                maxHp = 500,
            }
        end
    end

    -- Place hostile vessels according to difficulty, never in start quadrant
    local enemyPool = {}
    local classOrder = { "dreadnought", "cruiser", "stalker", "raider" }
    for _, cls in ipairs(classOrder) do
        local count = diff.enemies[cls] or 0
        for _ = 1, count do
            enemyPool[#enemyPool + 1] = cls
        end
    end

    -- Build candidate quadrants biased slightly toward clusters (max 3 enemies per quadrant)
    local hostileQuads = {}
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            if not (qx == startQx and qy == startQy) then
                hostileQuads[#hostileQuads + 1] = g.quadrants[qy][qx]
            end
        end
    end
    rng:shuffle(hostileQuads)

    local clusterQuads = {}
    local qCursor = 1
    for _, cls in ipairs(enemyPool) do
        local targetQuad = nil
        if #clusterQuads > 0 and rng:chance(0.42) then
            local cand = rng:pick(clusterQuads)
            if #Galaxy.getEnemies(cand, true) < 3 then
                targetQuad = cand
            end
        end
        if not targetQuad then
            for _ = 1, #hostileQuads do
                local cand = hostileQuads[qCursor]
                qCursor = (qCursor % #hostileQuads) + 1
                if #Galaxy.getEnemies(cand, true) < 3 then
                    targetQuad = cand
                    break
                end
            end
        end
        if targetQuad then
            Galaxy.spawnEnemy(g, targetQuad, cls, rng)
            if #Galaxy.getEnemies(targetQuad, true) < 3 then
                clusterQuads[#clusterQuads + 1] = targetQuad
            end
        end
    end

    return g
end

return Galaxy
