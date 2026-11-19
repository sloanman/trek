-- Visual VFX, smooth ship glide interpolation, screen shake, and floating text

local C = require("src.constants")
local Sound = require("src.sound")

local Animations = {}

local effects = {}
local glides = {}
local shakeTimer = 0
local shakeMax = 0
local shakeIntensity = 0
local fastMode = false

function Animations.reset()
    effects = {}
    glides = {}
    shakeTimer = 0
    shakeMax = 0
    shakeIntensity = 0
end

function Animations.setFastMode(enabled)
    fastMode = enabled == true
end

function Animations.isFastMode()
    return fastMode
end

local function colorByName(name)
    if name == "cyan" then return C.COLORS.cyan end
    if name == "emerald" then return C.COLORS.emerald end
    if name == "amber" then return C.COLORS.amber end
    if name == "crimson" then return C.COLORS.crimson end
    if name == "violet" then return C.COLORS.violet end
    if name == "gold" then return C.COLORS.gold end
    return C.COLORS.text
end

function Animations.pushEvents(events)
    if not events then return end
    for _, ev in ipairs(events) do
        if ev.kind == "sound" then
            Sound.play(ev.sound, ev.volume)
        elseif ev.kind == "shake" then
            local mag = ev.intensity or 6
            if mag > shakeIntensity or shakeTimer <= 0 then
                shakeIntensity = mag
                shakeMax = 0.35
                shakeTimer = 0.35
            end
        elseif ev.kind == "shipGlide" then
            glides[ev.id] = {
                x1 = ev.x1, y1 = ev.y1,
                x2 = ev.x2, y2 = ev.y2,
                t = 0,
                dur = 0.24,
            }
        elseif ev.kind == "beam" then
            effects[#effects + 1] = {
                kind = "beam",
                x1 = ev.x1, y1 = ev.y1,
                x2 = ev.x2, y2 = ev.y2,
                color = colorByName(ev.color or "cyan"),
                t = 0,
                dur = 0.32,
            }
        elseif ev.kind == "torpedo" then
            local dist = math.sqrt((ev.x2 - ev.x1) ^ 2 + (ev.y2 - ev.y1) ^ 2)
            effects[#effects + 1] = {
                kind = "torpedo",
                x1 = ev.x1, y1 = ev.y1,
                x2 = ev.x2, y2 = ev.y2,
                t = 0,
                dur = math.max(0.16, math.min(0.42, dist * 0.045)),
            }
        elseif ev.kind == "explosion" then
            effects[#effects + 1] = {
                kind = "explosion",
                x = ev.x, y = ev.y,
                size = ev.size or 1.0,
                t = 0,
                dur = 0.55,
            }
        elseif ev.kind == "supernova" then
            effects[#effects + 1] = {
                kind = "supernova",
                x = ev.x, y = ev.y,
                t = 0,
                dur = 0.95,
            }
        elseif ev.kind == "shieldRipple" then
            effects[#effects + 1] = {
                kind = "shieldRipple",
                x = ev.x, y = ev.y,
                color = colorByName(ev.color or "cyan"),
                t = 0,
                dur = 0.34,
            }
        elseif ev.kind == "ftlJump" then
            effects[#effects + 1] = {
                kind = "ftlJump",
                t = 0,
                dur = 0.55,
            }
        elseif ev.kind == "scanPulse" then
            effects[#effects + 1] = {
                kind = "scanPulse",
                t = 0,
                dur = 0.50,
            }
        elseif ev.kind == "floatText" then
            effects[#effects + 1] = {
                kind = "floatText",
                x = ev.x, y = ev.y,
                text = ev.text,
                color = colorByName(ev.color or "text"),
                t = 0,
                dur = 1.05,
            }
        end
    end
end

function Animations.update(dt)
    local mult = fastMode and 2.2 or 1.0
    local step = dt * mult

    if shakeTimer > 0 then
        shakeTimer = math.max(0, shakeTimer - step)
    end

    for id, g in pairs(glides) do
        g.t = g.t + step
        if g.t >= g.dur then
            glides[id] = nil
        end
    end

    for i = #effects, 1, -1 do
        local e = effects[i]
        e.t = e.t + step
        if e.t >= e.dur then
            table.remove(effects, i)
        end
    end
end

function Animations.getEntityVisualPos(id, sx, sy)
    local g = glides[id]
    if not g then
        return sx, sy
    end
    local u = math.min(1, g.t / g.dur)
    local ease = 1 - (1 - u) * (1 - u)
    return g.x1 + (g.x2 - g.x1) * ease, g.y1 + (g.y2 - g.y1) * ease
end

function Animations.isGliding(id)
    return glides[id] ~= nil
end

function Animations.getShakeOffset()
    if shakeTimer <= 0 or shakeMax <= 0 then
        return 0, 0
    end
    local frac = shakeTimer / shakeMax
    local mag = shakeIntensity * frac
    return (math.random() * 2 - 1) * mag, (math.random() * 2 - 1) * mag
end

local function tileCenter(gx, gy, tx, ty, tileSize, isoCfg)
    if isoCfg then
        local u = tx - 0.5
        local v = ty - 0.5
        return isoCfg.originX + (u - v) * isoCfg.halfW, isoCfg.originY + (u + v) * isoCfg.halfH
    end
    return gx + (tx - 0.5) * tileSize, gy + (ty - 0.5) * tileSize
end

function Animations.drawViewportEffects(gx, gy, tileSize, gridSize, fontSmall, isoCfg)
    if not (love and love.graphics) then return end
    local lg = love.graphics
    local totalW = tileSize * gridSize
    local areaX = isoCfg and isoCfg.areaX or gx
    local areaY = isoCfg and isoCfg.areaY or gy
    local areaW = isoCfg and isoCfg.areaW or totalW
    local areaH = isoCfg and isoCfg.areaH or totalW
    local isoRatio = isoCfg and (isoCfg.halfH / isoCfg.halfW) or 1.0

    for _, e in ipairs(effects) do
        local u = math.min(1, e.t / e.dur)

        if e.kind == "beam" then
            local x1, y1 = tileCenter(gx, gy, e.x1, e.y1, tileSize, isoCfg)
            local x2, y2 = tileCenter(gx, gy, e.x2, e.y2, tileSize, isoCfg)
            local alpha = (1 - u)
            lg.setLineWidth(7)
            lg.setColor(e.color[1], e.color[2], e.color[3], 0.35 * alpha)
            lg.line(x1, y1, x2, y2)
            lg.setLineWidth(3)
            lg.setColor(e.color[1], e.color[2], e.color[3], 0.9 * alpha)
            lg.line(x1, y1, x2, y2)
            lg.setLineWidth(1.2)
            lg.setColor(1, 1, 1, alpha)
            lg.line(x1, y1, x2, y2)
            -- Impact spark
            lg.setColor(e.color[1], e.color[2], e.color[3], 0.75 * alpha)
            lg.circle("fill", x2, y2, (1 - u * 0.4) * 10)
            lg.setLineWidth(1)

        elseif e.kind == "torpedo" then
            local x1, y1 = tileCenter(gx, gy, e.x1, e.y1, tileSize, isoCfg)
            local x2, y2 = tileCenter(gx, gy, e.x2, e.y2, tileSize, isoCfg)
            local px = x1 + (x2 - x1) * u
            local py = y1 + (y2 - y1) * u
            local tx = x1 + (x2 - x1) * math.max(0, u - 0.18)
            local ty = y1 + (y2 - y1) * math.max(0, u - 0.18)
            lg.setLineWidth(4)
            lg.setColor(1, 0.55, 0.15, 0.65)
            lg.line(tx, ty, px, py)
            lg.setColor(1, 0.92, 0.55, 0.95)
            lg.circle("fill", px, py, 6)
            lg.setColor(1, 1, 1, 1)
            lg.circle("fill", px, py, 3)
            lg.setLineWidth(1)

        elseif e.kind == "explosion" then
            local cx, cy = tileCenter(gx, gy, e.x, e.y, tileSize, isoCfg)
            local alpha = 1 - u
            local r = (10 + u * 36) * (e.size or 1.0)
            lg.setColor(1, 0.42, 0.15, 0.55 * alpha)
            lg.circle("fill", cx, cy, r * 0.7)
            lg.setColor(1, 0.85, 0.35, 0.9 * alpha)
            lg.setLineWidth(2.5)
            lg.circle("line", cx, cy, r)
            for p = 1, 8 do
                local ang = (p / 8) * math.pi * 2 + u * 0.4
                local d = r * 1.1
                lg.circle("fill", cx + math.cos(ang) * d, cy + math.sin(ang) * d, 3 * alpha)
            end
            lg.setLineWidth(1)

        elseif e.kind == "supernova" then
            local cx, cy = tileCenter(gx, gy, e.x, e.y, tileSize, isoCfg)
            local alpha = 1 - u
            local r = 16 + u * (tileSize * 1.85)
            lg.setColor(1, 0.95, 0.6, 0.45 * alpha)
            lg.circle("fill", cx, cy, r * 0.65)
            lg.setColor(1, 0.55, 0.15, 0.85 * alpha)
            lg.setLineWidth(4)
            lg.ellipse("line", cx, cy, r, r * isoRatio)
            lg.setColor(1, 0.9, 0.45, 0.8 * alpha)
            lg.setLineWidth(2)
            lg.ellipse("line", cx, cy, r * 0.55, r * 0.55 * isoRatio)
            lg.setLineWidth(1)

        elseif e.kind == "shieldRipple" then
            local cx, cy = tileCenter(gx, gy, e.x, e.y, tileSize, isoCfg)
            local alpha = 1 - u
            local rx = tileSize * (0.42 + u * 0.14)
            local ry = rx * 0.76
            lg.setColor(e.color[1], e.color[2], e.color[3], 0.24 * alpha)
            lg.ellipse("fill", cx, cy, rx, ry)
            lg.setColor(e.color[1], e.color[2], e.color[3], 0.90 * alpha)
            lg.setLineWidth(2.4)
            lg.ellipse("line", cx, cy, rx, ry)
            -- Crackling impact lightning arcs across bubble rim
            local tick = math.floor(u * 14)
            for k = 1, 4 do
                local baseAng = (k * 1.57 + tick * 0.85)
                local pts = {}
                for j = 0, 4 do
                    local frac = j / 4
                    local a = baseAng + frac * 0.75
                    local jag = (j == 0 or j == 4) and 1.0 or (0.86 + (((k * 17 + j * 31 + tick * 7) % 10) / 10) * 0.28)
                    pts[#pts + 1] = cx + math.cos(a) * rx * jag
                    pts[#pts + 1] = cy + math.sin(a) * ry * jag
                end
                lg.setLineWidth(2.0)
                lg.setColor(e.color[1], e.color[2], e.color[3], 0.55 * alpha)
                lg.line(pts)
                lg.setLineWidth(1.0)
                lg.setColor(1, 1, 1, 0.92 * alpha)
                lg.line(pts)
            end
            lg.setLineWidth(1)

        elseif e.kind == "ftlJump" then
            local alpha = math.sin(u * math.pi)
            lg.setColor(0.35, 0.85, 1.0, 0.22 * alpha)
            lg.rectangle("fill", areaX, areaY, areaW, areaH)
            lg.setLineWidth(2)
            for s = 1, 22 do
                local sx = areaX + ((s * 97) % areaW)
                local sy = areaY + ((s * 53 + u * 260) % areaH)
                local len = 28 + (s % 4) * 16
                lg.setColor(0.75, 0.95, 1.0, 0.75 * alpha)
                lg.line(sx, sy, sx, math.min(areaY + areaH, sy + len))
            end
            lg.setLineWidth(1)

        elseif e.kind == "scanPulse" then
            local cx, cy = tileCenter(gx, gy, gridSize * 0.5 + 0.5, gridSize * 0.5 + 0.5, tileSize, isoCfg)
            local r = u * totalW * 0.75
            lg.setColor(0.24, 0.88, 0.98, 0.7 * (1 - u))
            lg.setLineWidth(2.5)
            lg.ellipse("line", cx, cy, r, r * isoRatio)
            lg.setLineWidth(1)

        elseif e.kind == "floatText" then
            local cx, cy = tileCenter(gx, gy, e.x, e.y, tileSize, isoCfg)
            local alpha = 1 - (u * u)
            local yOff = -u * 26
            if fontSmall then
                lg.setFont(fontSmall)
            end
            lg.setColor(0, 0, 0, 0.8 * alpha)
            lg.printf(e.text, cx - 50 + 1, cy - 10 + yOff + 1, 100, "center")
            lg.setColor(e.color[1], e.color[2], e.color[3], alpha)
            lg.printf(e.text, cx - 50, cy - 10 + yOff, 100, "center")
        end
    end
end

return Animations
