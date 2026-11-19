-- Continuous 2D tactical movement, turn-rate steering, throttle kinematics & Bézier curve plotting

local C = require("src.constants")

local Movement = {}

local TWO_PI = math.pi * 2

function Movement.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Normalize angle to [-pi, pi)
function Movement.normalizeAngle(a)
    a = (a or 0) % TWO_PI
    if a >= math.pi then
        a = a - TWO_PI
    end
    return a
end

-- Signed shortest angular delta from -> to in [-pi, pi)
function Movement.angleDiff(from, to)
    return Movement.normalizeAngle((to or 0) - (from or 0))
end

-- Rotate current toward target bounded by maxDelta; returns newAngle, remainingAbsDiff
function Movement.steerToward(current, target, maxDelta)
    local diff = Movement.angleDiff(current, target)
    local ad = math.abs(diff)
    if ad <= maxDelta then
        return Movement.normalizeAngle(target), 0
    end
    local step = (diff >= 0) and maxDelta or -maxDelta
    return Movement.normalizeAngle(current + step), ad - maxDelta
end

function Movement.sectorToWorld(sx, sy)
    local s = C.SECTOR_WORLD_SCALE
    return ((sx or 4) - 0.5) * s, ((sy or 4) - 0.5) * s
end

function Movement.worldToSector(wx, wy)
    local s = C.SECTOR_WORLD_SCALE
    local sx = Movement.clamp(math.floor((wx or 0) / s) + 1, 1, C.GRID_SIZE)
    local sy = Movement.clamp(math.floor((wy or 0) / s) + 1, 1, C.GRID_SIZE)
    return sx, sy
end

function Movement.clampWorld(wx, wy)
    local m = C.WORLD_MARGIN
    local hi = C.WORLD_SIZE - m
    return Movement.clamp(wx or 0, m, hi), Movement.clamp(wy or 0, m, hi)
end

function Movement.getThrottleLabel(ratio)
    local r = Movement.clamp(ratio or 0, 0, 1)
    for _, stop in ipairs(C.THROTTLE_STOPS) do
        if math.abs(r - stop.ratio) < 0.03 then
            return stop.label
        end
    end
    return string.format("%d%%", math.floor(r * 100 + 0.5))
end

function Movement.ensurePlayerKinematics(p)
    if not p then return end
    if p.x == nil or p.y == nil then
        p.x, p.y = Movement.sectorToWorld(p.sx or 4, p.sy or 4)
    end
    p.x, p.y = Movement.clampWorld(p.x, p.y)
    p.sx, p.sy = Movement.worldToSector(p.x, p.y)
    p.heading = Movement.normalizeAngle(p.heading or 0)
    p.speed = math.max(0, p.speed or 0)
    p.maxSpeed = p.maxSpeed or C.PLAYER_MOVEMENT.maxSpeed
    p.turnRate = p.turnRate or C.PLAYER_MOVEMENT.turnRate
    p.accel = p.accel or C.PLAYER_MOVEMENT.accel
    p.decel = p.decel or C.PLAYER_MOVEMENT.decel
    p.speedSetting = (p.speedSetting ~= nil) and Movement.clamp(p.speedSetting, 0, 1) or 0
end

function Movement.evaluateBezier(p0, p1, p2, p3, t)
    local u = 1 - t
    local u2 = u * u
    local t2 = t * t

    local b0 = u2 * u
    local b1 = 3 * u2 * t
    local b2 = 3 * u * t2
    local b3 = t2 * t

    local x = b0 * p0.x + b1 * p1.x + b2 * p2.x + b3 * p3.x
    local y = b0 * p0.y + b1 * p1.y + b2 * p2.y + b3 * p3.y

    local dx = 3 * u2 * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t2 * (p3.x - p2.x)
    local dy = 3 * u2 * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t2 * (p3.y - p2.y)
    return x, y, dx, dy
end

function Movement.buildCurve(startX, startY, startHeading, destX, destY, exitHeading, exitHandleLen, samples)
    startX, startY = Movement.clampWorld(startX, startY)
    destX, destY = Movement.clampWorld(destX, destY)
    startHeading = Movement.normalizeAngle(startHeading or 0)

    local dx = destX - startX
    local dy = destY - startY
    local chord = math.sqrt(dx * dx + dy * dy)

    if chord < 18 then
        if exitHeading == nil then
            return nil
        end
        return {
            kind = "turn",
            p0 = { x = startX, y = startY },
            p3 = { x = startX, y = startY },
            startHeading = startHeading,
            endHeading = Movement.normalizeAngle(exitHeading),
            totalLength = 0,
            points = { { x = startX, y = startY, dist = 0 } },
            cursor = 1,
            completed = false,
            arriving = true,
        }
    end

    local resolvedExit = exitHeading and Movement.normalizeAngle(exitHeading) or math.atan2(dy, dx)
    local h0 = Movement.clamp(chord * 0.38, 25, 220)
    local h1 = exitHandleLen
        and Movement.clamp(exitHandleLen, 25, math.max(90, chord * 0.70))
        or Movement.clamp(chord * 0.38, 25, 220)

    local p0 = { x = startX, y = startY }
    local p1 = { x = startX + math.cos(startHeading) * h0, y = startY + math.sin(startHeading) * h0 }
    local p2 = { x = destX - math.cos(resolvedExit) * h1, y = destY - math.sin(resolvedExit) * h1 }
    local p3 = { x = destX, y = destY }

    local n = samples or 32
    local points = {}
    local totalLength = 0
    local prevX, prevY = startX, startY

    for i = 0, n do
        local t = i / n
        local px, py = Movement.evaluateBezier(p0, p1, p2, p3, t)
        px, py = Movement.clampWorld(px, py)
        if i > 0 then
            local segDx = px - prevX
            local segDy = py - prevY
            totalLength = totalLength + math.sqrt(segDx * segDx + segDy * segDy)
        end
        points[#points + 1] = { x = px, y = py, dist = totalLength }
        prevX, prevY = px, py
    end

    return {
        kind = "bezier",
        p0 = p0,
        p1 = p1,
        p2 = p2,
        p3 = p3,
        startHeading = startHeading,
        endHeading = resolvedExit,
        totalLength = totalLength,
        points = points,
        cursor = 2,
        completed = false,
        arriving = false,
    }
end

local function stepApproachSpeed(curSpeed, targetSpeed, accel, decel, dt)
    if curSpeed < targetSpeed then
        return math.min(targetSpeed, curSpeed + accel * dt)
    elseif curSpeed > targetSpeed then
        return math.max(targetSpeed, curSpeed - decel * dt)
    end
    return curSpeed
end

local function computeRemainingDistance(p, path)
    local pts = path.points
    local n = #pts
    local cur = Movement.clamp(path.cursor or 2, 1, n)
    local cPt = pts[cur]
    local dToCur = math.sqrt((cPt.x - p.x) ^ 2 + (cPt.y - p.y) ^ 2)
    local polyRem = dToCur + math.max(0, (pts[n].dist or 0) - (cPt.dist or 0))
    local direct = math.sqrt((path.p3.x - p.x) ^ 2 + (path.p3.y - p.y) ^ 2)
    return math.max(direct, polyRem)
end

local function findLookaheadPoint(p, path, lookDist)
    local pts = path.points
    local n = #pts
    local cur = Movement.clamp(path.cursor or 2, 1, n)
    for i = cur, n do
        local pt = pts[i]
        local d = math.sqrt((pt.x - p.x) ^ 2 + (pt.y - p.y) ^ 2)
        if d >= lookDist then
            return pt.x, pt.y
        end
    end
    return pts[n].x, pts[n].y
end

local function resolveObstacles(p, quad)
    if not quad or not quad.entities then return end
    local minR = C.PLAYER_MOVEMENT.obstacleRadius
    for _, ent in ipairs(quad.entities) do
        local solid = (ent.kind == "star" or ent.kind == "planet" or ent.kind == "outpost"
            or (ent.kind == "enemy" and not ent.cloaked))
        if solid then
            local ex, ey = Movement.sectorToWorld(ent.x, ent.y)
            local dx = p.x - ex
            local dy = p.y - ey
            local distSq = dx * dx + dy * dy
            if distSq < minR * minR then
                local dist = math.sqrt(distSq)
                if dist < 1e-4 then
                    local back = p.heading + math.pi
                    p.x = ex + math.cos(back) * minR
                    p.y = ey + math.sin(back) * minR
                else
                    p.x = ex + (dx / dist) * minR
                    p.y = ey + (dy / dist) * minR
                end
            end
        end
    end
end

-- Deterministic fixed-substep kinematic simulation step; returns true if a plotted path just completed
function Movement.stepPlayer(p, quad, dt)
    Movement.ensurePlayerKinematics(p)
    if not dt or dt <= 0 then
        return false
    end

    local rem = math.min(dt, 0.1)
    local thrusterPct = (p.systems and p.systems.thrusters) or 100
    local eff = (thrusterPct <= 0) and 0 or Movement.clamp(0.35 + 0.65 * (thrusterPct / 100), 0.35, 1.0)
    local effMaxSpeed = p.maxSpeed * eff
    local effTurnRate = p.turnRate * eff
    local effAccel = p.accel * eff
    local effDecel = p.decel * math.max(0.5, eff)

    local maxSubstep = C.PLAYER_MOVEMENT.maxSubstep
    local completedPath = false

    while rem > 1e-7 do
        local step = math.min(rem, maxSubstep)
        rem = rem - step

        local path = p.activePath
        if path then
            if path.kind == "turn" then
                p.speed = stepApproachSpeed(p.speed, 0, effAccel, effDecel, step)
                local newHdg, remAng = Movement.steerToward(p.heading, path.endHeading, effTurnRate * step)
                p.heading = newHdg
                if remAng <= 0.03 and p.speed <= 0.5 then
                    p.heading = path.endHeading
                    p.speed = 0
                    p.activePath = nil
                    completedPath = true
                end
            else
                local pts = path.points
                local n = #pts
                local dest = path.p3
                local cursor = Movement.clamp(path.cursor or 2, 2, n)
                while cursor < n do
                    local pt = pts[cursor]
                    local wd = math.sqrt((pt.x - p.x) ^ 2 + (pt.y - p.y) ^ 2)
                    if wd <= C.PLAYER_MOVEMENT.waypointRadius then
                        cursor = cursor + 1
                    else
                        break
                    end
                end
                path.cursor = cursor

                local distToEnd = math.sqrt((dest.x - p.x) ^ 2 + (dest.y - p.y) ^ 2)
                local remDist = computeRemainingDistance(p, path)

                if path.arriving or distToEnd <= C.PLAYER_MOVEMENT.arrivalRadius
                    or (cursor >= n and distToEnd <= C.PLAYER_MOVEMENT.arrivalRadius * 1.4) then
                    path.arriving = true
                    p.speed = stepApproachSpeed(p.speed, 0, effAccel, effDecel, step)
                    local newHdg, remAng = Movement.steerToward(p.heading, path.endHeading, effTurnRate * step)
                    p.heading = newHdg
                    if p.speed <= 1.5 and remAng <= 0.04 then
                        p.heading = path.endHeading
                        p.speed = 0
                        p.speedSetting = 0
                        p.activePath = nil
                        completedPath = true
                    end
                else
                    local effLook = math.min(C.PLAYER_MOVEMENT.lookaheadDist, math.max(12, distToEnd * 0.65))
                    local tx, ty = findLookaheadPoint(p, path, effLook)
                    local wantHdg = math.atan2(ty - p.y, tx - p.x)
                    if distToEnd < 32 and math.abs(Movement.angleDiff(wantHdg, path.endHeading)) < 0.75 then
                        local w = (32 - distToEnd) / 32 * 0.45
                        wantHdg = Movement.normalizeAngle(wantHdg + Movement.angleDiff(wantHdg, path.endHeading) * w)
                    end

                    p.heading = Movement.steerToward(p.heading, wantHdg, effTurnRate * step)

                    local desiredSpeed = effMaxSpeed * Movement.clamp(p.speedSetting, 0, 1)
                    local hdgErr = math.abs(Movement.angleDiff(p.heading, wantHdg))
                    local turnScale = Movement.clamp(0.18 + 0.82 * math.cos(math.min(hdgErr, math.pi * 0.5)), 0.18, 1.0)
                    local targetSpeed = desiredSpeed * turnScale

                    local stopDist = (p.speed * p.speed) / math.max(1, 2 * effDecel)
                    if remDist <= stopDist + 24 then
                        local brakeSpeed = math.sqrt(math.max(0, 2 * effDecel * math.max(0, remDist - 4)))
                        targetSpeed = math.min(targetSpeed, brakeSpeed)
                    end

                    p.speed = stepApproachSpeed(p.speed, targetSpeed, effAccel, effDecel, step)
                end
            end
        else
            if p.targetHeading ~= nil then
                local newHdg, remAng = Movement.steerToward(p.heading, p.targetHeading, effTurnRate * step)
                p.heading = newHdg
                if remAng <= 0.02 then
                    p.targetHeading = nil
                end
            end
            local targetSpeed = effMaxSpeed * Movement.clamp(p.speedSetting, 0, 1)
            p.speed = stepApproachSpeed(p.speed, targetSpeed, effAccel, effDecel, step)
        end

        if p.speed > 1e-4 then
            p.docked = false
            p.x = p.x + math.cos(p.heading) * p.speed * step
            p.y = p.y + math.sin(p.heading) * p.speed * step
        end

        resolveObstacles(p, quad)
        p.x, p.y = Movement.clampWorld(p.x, p.y)
        p.sx, p.sy = Movement.worldToSector(p.x, p.y)
    end

    return completedPath
end

return Movement
