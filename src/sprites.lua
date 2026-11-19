-- Procedural/sprite starship & orbital renderers and animated deep-space starfield

local C = require("src.constants")
local PlanetRenderer = require("src.planet_shader")
local TurnaroundData = require("src.turnaround_data")

local Sprites = {}

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Smooth tapered parabolic plasma cone points extending from nozzle (x, y) toward +y
local function buildTaperedCone(x, y, halfW, len)
    return {
        x - halfW * 0.78, y,
        x + halfW * 0.78, y,
        x + halfW * 0.92, y + len * 0.12,
        x + halfW * 0.58, y + len * 0.36,
        x + halfW * 0.24, y + len * 0.68,
        x,                y + len,
        x - halfW * 0.24, y + len * 0.68,
        x - halfW * 0.58, y + len * 0.36,
        x - halfW * 0.92, y + len * 0.12,
    }
end

-- Layered Expanse-style Epstein fusion drive plume with smooth parabolic taper & shock diamonds
local function drawEpsteinPlume(x, y, len, halfW, outerCol, coreCol, time, phase, thrusting, alphaScale)
    local lg = love.graphics
    alphaScale = alphaScale or 1.0
    local boost = thrusting and 1.38 or 0.98
    local f1 = 0.91 + 0.09 * math.sin(time * 36 + phase)
    local f2 = 0.88 + 0.12 * math.cos(time * 51 + phase * 1.7)
    local L = len * boost * f1
    local W = halfW * (thrusting and 1.10 or 0.94) * (0.95 + 0.05 * f2)

    -- Soft volumetric plasma bloom around nozzle mouth
    lg.setColor(outerCol[1], outerCol[2], outerCol[3], 0.14 * alphaScale)
    lg.circle("fill", x, y + L * 0.10, W * 2.55)
    lg.setColor(outerCol[1], outerCol[2], outerCol[3], 0.22 * alphaScale)
    lg.circle("fill", x, y + L * 0.06, W * 1.55)

    -- Outer smooth ionization tail
    lg.setColor(outerCol[1], outerCol[2], outerCol[3], 0.38 * alphaScale)
    lg.polygon("fill", buildTaperedCone(x, y, W * 1.06, L))

    -- Bright mid-plasma torch lance
    lg.setColor(coreCol[1], coreCol[2], coreCol[3], 0.80 * alphaScale)
    lg.polygon("fill", buildTaperedCone(x, y, W * 0.64, L * 0.78))

    -- Incandescent white-hot inner core spike
    lg.setColor(1, 0.99, 0.97, 0.96 * alphaScale)
    lg.polygon("fill", buildTaperedCone(x, y, W * 0.34, L * 0.46))

    -- Mach shock diamond compression nodes along axis
    local diamonds = thrusting and { 0.18, 0.37, 0.56 } or { 0.20, 0.42 }
    for idx, frac in ipairs(diamonds) do
        local dy = y + L * frac
        local dr = W * (0.46 - idx * 0.09)
        lg.setColor(1, 0.99, 0.97, (0.86 - idx * 0.17) * alphaScale)
        lg.polygon("fill", x, dy - dr * 1.25, x + dr * 0.65, dy, x, dy + dr * 1.25, x - dr * 0.65, dy)
    end
end

function Sprites.drawStarfield(x, y, w, h, time, seed)
    local lg = love.graphics
    seed = seed or 42
    lg.setColor(0.025, 0.038, 0.072, 1)
    lg.rectangle("fill", x, y, w, h)

    -- Subtle deep-space nebula glow
    lg.setColor(0.06, 0.14, 0.28, 0.16)
    lg.circle("fill", x + w * 0.28, y + h * 0.32, w * 0.32)
    lg.setColor(0.14, 0.07, 0.24, 0.14)
    lg.circle("fill", x + w * 0.74, y + h * 0.68, w * 0.28)

    for i = 1, 75 do
        local h1 = ((i * 73856093 + seed * 19349663) % 10000) / 10000
        local h2 = ((i * 83492791 + seed * 2971215073) % 10000) / 10000
        local sx = x + 6 + h1 * (w - 12)
        local sy = y + 6 + h2 * (h - 12)
        local twinkle = 0.45 + 0.55 * math.sin(time * (1.1 + (i % 5) * 0.4) + i * 1.7)
        local sz = (i % 9 == 0) and 2.0 or 1.2
        if i % 7 == 0 then
            lg.setColor(0.65, 0.85, 1.0, 0.45 * twinkle)
        elseif i % 11 == 0 then
            lg.setColor(1.0, 0.88, 0.68, 0.42 * twinkle)
        else
            lg.setColor(0.85, 0.90, 0.98, 0.35 * twinkle)
        end
        lg.circle("fill", sx, sy, sz)
    end
end

local shipSpriteCache = {}
local function getShipSpriteImage(path)
    if shipSpriteCache[path] == nil then
        if love and love.graphics and love.filesystem and love.filesystem.getInfo(path) then
            local img = love.graphics.newImage(path)
            img:setFilter("nearest", "nearest")
            shipSpriteCache[path] = img
        else
            shipSpriteCache[path] = false
        end
    end
    return shipSpriteCache[path] or nil
end

-- 12-point isometric turnaround frames (96x96 each, 1152x96 sheets) loaded from src/turnaround_data.lua
-- Angles start at 135 deg (Down-Left, +Y grid) and step +30 deg clockwise around the orbital plane.
local turnaroundQuads = nil
local function getTurnaroundQuads()
    if not turnaroundQuads and love and love.graphics then
        turnaroundQuads = {}
        for i = 0, 11 do
            turnaroundQuads[i + 1] = love.graphics.newQuad(i * 96, 0, 96, 96, 1152, 96)
        end
    end
    return turnaroundQuads
end

local function getTurnaroundFrameIndex(heading, defaultHeading)
    local h = heading or defaultHeading or (math.pi * 0.5)
    -- Map grid heading (0 = +X East) to isometric orbital plane yaw (45 deg = Down-Right, 135 deg = Down-Left)
    local deg = (math.deg(h + math.pi * 0.25)) % 360
    local rel = (deg - 135) % 360
    return (math.floor((rel + 15) / 30) % 12) + 1
end

local function applyTurnaroundFrame(spec, heading, defaultHeading, drawOpts)
    local quads = getTurnaroundQuads()
    local frames = spec.turnaroundKey and TurnaroundData[spec.turnaroundKey]
    local sheetImg = getShipSpriteImage(spec.path)
    if sheetImg and quads and frames then
        local frameIdx = getTurnaroundFrameIndex(heading, defaultHeading)
        local frame = frames[frameIdx] or frames[1]
        if quads[frameIdx] and frame then
            drawOpts.quad = quads[frameIdx]
            drawOpts.frameCenter = spec.frameCenter or 48
            drawOpts.exhaustAngle = frame.exhaustAngle
            drawOpts.nozzles = frame.nozzles
        end
    end
end

-- Isometric ship sprites and stern engine nozzle coordinates
local SHIP_SPRITE_SPECS = {
    player = {
        path = "assets/sprites/player_ship_sheet.png",
        fallbackPath = "assets/sprites/player_ship.png",
        turnaroundKey = "player",
        frameCenter = 48,
        exhaustAngle = -0.4873,
        scaleMult = 1.0,
        nozzles = {
            { x = 67.63, y = 21.21, len = 13, halfW = 2.5, phase = 0.0, visible = true },
            { x = 63.84, y = 13.19, len = 16, halfW = 3.0, phase = 1.2, visible = true },
            { x = 63.84, y = 17.06, len = 15, halfW = 2.9, phase = 2.4, visible = true },
            { x = 50.54, y = 12.15, len = 13, halfW = 2.5, phase = 3.6, visible = false },
        },
        outerCol = { 0.16, 0.68, 1.0 },
        coreCol  = { 0.62, 0.94, 1.0 },
        glowCol  = { 0.55, 0.92, 1.0 },
        shieldCol = { 0.26, 0.88, 1.0 },
    },
    raider = {
        path = "assets/sprites/enemy_raider_sheet.png",
        fallbackPath = "assets/sprites/enemy_raider.png",
        turnaroundKey = "raider",
        frameCenter = 48,
        exhaustAngle = -math.pi + 0.48, -- up-left
        scaleMult = 0.96,
        nozzles = {
            { x = 13.5, y = 12.5, len = 11, halfW = 2.3, phase = 0.2 },
            { x = 5.5,  y = 15.5, len = 13, halfW = 2.6, phase = 1.6 },
            { x = 5.5,  y = 20.0, len = 12, halfW = 2.4, phase = 2.9 },
        },
        outerCol = { 0.98, 0.45, 0.10 },
        coreCol  = { 1.0, 0.88, 0.42 },
        glowCol  = { 1.0, 0.78, 0.30 },
        shieldCol = { 1.0, 0.74, 0.28 },
    },
    cruiser = {
        path = "assets/sprites/enemy_cruiser_sheet.png",
        fallbackPath = "assets/sprites/enemy_cruiser.png",
        turnaroundKey = "cruiser",
        frameCenter = 48,
        exhaustAngle = -math.pi + 0.48,
        scaleMult = 1.02,
        nozzles = {
            { x = 10.0, y = 12.5, len = 12, halfW = 2.5, phase = 0.5 },
            { x = 3.0,  y = 17.0, len = 14, halfW = 2.9, phase = 1.9 },
            { x = 2.0,  y = 22.0, len = 13, halfW = 2.7, phase = 3.1 },
        },
        outerCol = { 0.96, 0.22, 0.14 },
        coreCol  = { 1.0, 0.72, 0.34 },
        glowCol  = { 1.0, 0.45, 0.22 },
        shieldCol = { 1.0, 0.36, 0.44 },
    },
    dreadnought = {
        path = "assets/sprites/enemy_dreadnought_sheet.png",
        fallbackPath = "assets/sprites/enemy_dreadnought.png",
        turnaroundKey = "dreadnought",
        frameCenter = 48,
        exhaustAngle = -math.pi + 0.48,
        scaleMult = 1.08,
        nozzles = {
            { x = 10.5, y = 8.5,  len = 12, halfW = 2.5, phase = 0.3 },
            { x = 5.5,  y = 11.0, len = 14, halfW = 2.9, phase = 1.5 },
            { x = 2.5,  y = 14.5, len = 15, halfW = 3.0, phase = 2.8 },
            { x = 2.0,  y = 19.0, len = 13, halfW = 2.7, phase = 4.1 },
        },
        outerCol = { 1.0, 0.42, 0.10 },
        coreCol  = { 1.0, 0.88, 0.44 },
        glowCol  = { 1.0, 0.68, 0.24 },
        shieldCol = { 1.0, 0.50, 0.22 },
    },
    stalker = {
        path = "assets/sprites/enemy_stalker_sheet.png",
        fallbackPath = "assets/sprites/enemy_stalker.png",
        turnaroundKey = "stalker",
        frameCenter = 48,
        exhaustAngle = -math.pi + 0.48,
        scaleMult = 0.98,
        nozzles = {
            { x = 8.5, y = 14.0, len = 9,  halfW = 2.0, phase = 0.6 },
            { x = 4.5, y = 17.5, len = 10, halfW = 2.2, phase = 2.1 },
            { x = 2.5, y = 20.0, len = 9,  halfW = 2.0, phase = 3.4 },
        },
        outerCol = { 0.48, 0.24, 0.92 },
        coreCol  = { 0.78, 0.62, 1.0 },
        glowCol  = { 0.66, 0.44, 1.0 },
        shieldCol = { 0.74, 0.46, 1.0 },
        plumeAlpha = 0.58,
    },
}

local function hash01(n)
    local s = math.sin(n * 127.1 + 311.7) * 43758.5453123
    return s - math.floor(s)
end

-- Back half of crackling energy bubble shield (drawn behind ship)
local function drawShieldBubbleBack(cx, cy, rx, ry, col, shieldPct, time, seed)
    local lg = love.graphics
    local sp = clamp01(shieldPct or 1)
    local pulse = 0.86 + 0.14 * math.sin(time * 5.2 + seed)
    local dmgFlicker = (sp < 0.32 and math.sin(time * 24 + seed) < -0.55) and 0.45 or 1.0
    local alpha = (0.36 + 0.44 * sp) * pulse * dmgFlicker

    -- Translucent interior plasma volume
    lg.setColor(col[1], col[2], col[3], 0.11 * alpha)
    lg.ellipse("fill", cx, cy, rx, ry)
    lg.setColor(col[1], col[2], col[3], 0.07 * alpha)
    lg.ellipse("fill", cx, cy, rx * 0.82, ry * 0.82)
end

-- Front half of crackling energy bubble shield: Fresnel rim, specular sheen & jagged lightning arcs
local function drawShieldBubbleFront(cx, cy, rx, ry, col, shieldPct, time, seed, lw)
    local lg = love.graphics
    local sp = clamp01(shieldPct or 1)
    local pulse = 0.86 + 0.14 * math.sin(time * 5.2 + seed)
    local dmgFlicker = (sp < 0.32 and math.sin(time * 24 + seed) < -0.55) and 0.45 or 1.0
    local alpha = (0.42 + 0.48 * sp) * pulse * dmgFlicker

    -- Soft outer plasma halo
    lg.setLineWidth(math.max(1.8, lw * 2.4))
    lg.setColor(col[1], col[2], col[3], 0.22 * alpha)
    lg.ellipse("line", cx, cy, rx * 1.03, ry * 1.03)

    -- Main energy bubble membrane rim
    lg.setLineWidth(math.max(1.0, lw * 1.05))
    lg.setColor(col[1], col[2], col[3], 0.62 * alpha)
    lg.ellipse("line", cx, cy, rx, ry)

    -- Upper-left glassy bubble specular sheen arc
    local sheenPts = {}
    for i = 0, 8 do
        local a = -2.55 + (i / 8) * 0.95
        sheenPts[#sheenPts + 1] = cx + math.cos(a) * rx * 0.84
        sheenPts[#sheenPts + 1] = cy + math.sin(a) * ry * 0.84
    end
    lg.setLineWidth(math.max(1.1, lw * 1.15))
    lg.setColor(0.85 + 0.15 * col[1], 0.90 + 0.10 * col[2], 0.95 + 0.05 * col[3], 0.38 * alpha)
    lg.line(sheenPts)

    -- Crackling electric discharge arcs across the bubble surface and perimeter
    local crackleHz = 13 + (1 - sp) * 8
    local tick = math.floor(time * crackleHz + seed * 17)
    local arcCount = 5
    for k = 1, arcCount do
        local s = tick * 31 + k * 97 + seed * 13
        local baseAng = hash01(s) * math.pi * 2
        local span = (0.55 + hash01(s + 1) * 0.75) * (k % 2 == 0 and 1 or -1)
        local isSurfaceBridge = (k <= 2)
        local pts = {}
        local segs = 5
        for j = 0, segs do
            local t = j / segs
            local a = baseAng + span * t
            local radialScale
            if isSurfaceBridge then
                local arch = math.sin(t * math.pi)
                radialScale = 0.98 - arch * (0.28 + 0.18 * hash01(s + j * 7 + 3))
            else
                radialScale = (j == 0 or j == segs) and 1.0 or (0.91 + hash01(s + j * 11 + 5) * 0.18)
            end
            local jitterAng = (j == 0 or j == segs) and 0 or (hash01(s + j * 13 + 9) - 0.5) * 0.14
            pts[#pts + 1] = cx + math.cos(a + jitterAng) * rx * radialScale
            pts[#pts + 1] = cy + math.sin(a + jitterAng) * ry * radialScale
        end

        local arcAlpha = (0.55 + 0.45 * hash01(s + 41)) * alpha
        lg.setLineWidth(math.max(1.6, lw * 2.0))
        lg.setColor(col[1], col[2], col[3], 0.42 * arcAlpha)
        lg.line(pts)

        lg.setLineWidth(math.max(0.8, lw * 0.85))
        lg.setColor(0.88 + 0.12 * col[1], 0.92 + 0.08 * col[2], 1.0, 0.92 * arcAlpha)
        lg.line(pts)

        lg.setColor(1, 1, 1, 0.85 * arcAlpha)
        lg.circle("fill", pts[1], pts[2], math.max(0.8, lw * 0.95))
        lg.circle("fill", pts[#pts - 1], pts[#pts], math.max(0.8, lw * 0.95))
    end

    lg.setLineWidth(1)
end

local function drawNozzlePlumes(cx, cy, frameCenter, scale, exhaustAngle, nozzles, spec, time, thrusting, seed, spriteAlpha, plumeAlpha)
    local lg = love.graphics
    local plumeRot = exhaustAngle - math.pi * 0.5
    local exCos = math.cos(exhaustAngle)
    local exSin = math.sin(exhaustAngle)
    for idx, nz in ipairs(nozzles) do
        local nx = cx + (nz.x - frameCenter) * scale
        local ny = cy + (nz.y - frameCenter) * scale

        lg.push()
        lg.translate(nx, ny)
        lg.rotate(plumeRot)
        drawEpsteinPlume(
            0, 0,
            nz.len * scale,
            nz.halfW * scale,
            spec.outerCol,
            spec.coreCol,
            time,
            nz.phase,
            thrusting,
            plumeAlpha
        )
        lg.pop()

        local pRate = thrusting and 3.4 or 1.8
        local pPhase = (time * pRate + idx * 0.37 + seed * 0.13) % 1.0
        local dist = (4 + pPhase * (thrusting and 22 or 13)) * scale
        local jitter = math.sin(time * 24 + idx * 2.1 + seed) * 1.1 * scale
        local px = nx + exCos * dist - exSin * jitter
        local py = ny + exSin * dist + exCos * jitter
        lg.setColor(spec.coreCol[1], spec.coreCol[2], spec.coreCol[3], (1 - pPhase) * (thrusting and 0.85 or 0.55) * spriteAlpha)
        lg.circle("fill", px, py, math.max(0.8, (1.5 - pPhase * 0.8) * scale))
    end
end

-- Shared renderer for isometric ship sprites (supports single 64x64 or turnaround sprite sheets), engine FX & shield bubble
local function drawSpriteShipWithFX(cx, cy, size, spec, opts)
    local lg = love.graphics
    local effSize = size * (spec.scaleMult or 1.0)
    local scale = effSize / 64
    local lw = math.max(0.9, effSize * 0.015)
    local time = opts.time or 0
    local thrusting = opts.thrusting == true
    local hullPct = opts.hullPct or 1.0
    local shieldsUp = opts.shieldsUp == true
    local shieldPct = opts.shieldPct or 1.0
    local seed = opts.seed or 1.0
    local spriteAlpha = opts.spriteAlpha or 1.0
    local plumeAlpha = (spec.plumeAlpha or 0.92) * spriteAlpha
    local shieldRx = effSize * 0.56
    local shieldRy = effSize * 0.42
    local img = getShipSpriteImage(spec.path)
    local frameCenter = (img and opts.quad) and (opts.frameCenter or spec.frameCenter or 48) or 32
    local exhaustAngle = opts.exhaustAngle or spec.exhaustAngle
    local nozzles = opts.nozzles or spec.nozzles
    local plumesInFront = math.sin(exhaustAngle) > 0.02

    if shieldsUp then
        drawShieldBubbleBack(cx, cy, shieldRx, shieldRy, spec.shieldCol, shieldPct, time, seed)
    end

    if not plumesInFront then
        drawNozzlePlumes(cx, cy, frameCenter, scale, exhaustAngle, nozzles, spec, time, thrusting, seed, spriteAlpha, plumeAlpha)
    end

    -- Draw sprite frame in isometric orientation
    if img and opts.quad then
        lg.setColor(1, 1, 1, spriteAlpha)
        lg.draw(img, opts.quad, cx, cy, 0, scale, scale, frameCenter, frameCenter)
    elseif img then
        lg.setColor(1, 1, 1, spriteAlpha)
        lg.draw(img, cx, cy, 0, scale, scale, 32, 32)
    elseif spec.fallbackPath then
        local fb = getShipSpriteImage(spec.fallbackPath)
        if fb then
            lg.setColor(1, 1, 1, spriteAlpha)
            lg.draw(fb, cx, cy, 0, scale, scale, 32, 32)
        end
    end

    -- Pulsing core glow at visible nozzle mouths
    for idx, nz in ipairs(nozzles) do
        if nz.visible ~= false then
            local nx = cx + (nz.x - frameCenter) * scale
            local ny = cy + (nz.y - frameCenter) * scale
            local glowPulse = 0.72 + 0.28 * math.sin(time * 28 + idx * 1.9 + seed)
            lg.setColor(spec.glowCol[1], spec.glowCol[2], spec.glowCol[3], 0.55 * glowPulse * spriteAlpha)
            lg.circle("fill", nx, ny, math.max(1.0, 2.2 * scale))
            lg.setColor(1, 1, 1, 0.72 * glowPulse * spriteAlpha)
            lg.circle("fill", nx, ny, math.max(0.6, 1.0 * scale))
        end
    end

    if plumesInFront then
        drawNozzlePlumes(cx, cy, frameCenter, scale, exhaustAngle, nozzles, spec, time, thrusting, seed, spriteAlpha, plumeAlpha)
    end

    -- Battle-damage emergency strobe when severely damaged
    if hullPct < 0.55 then
        local dmgBlink = math.sin(time * 10 + seed) > 0
        if hullPct < 0.32 and dmgBlink then
            lg.setColor(1.0, 0.28, 0.18, 0.90)
            lg.circle("fill", cx + (exhaustAngle > -1.5 and -4 or 4) * scale, cy + 2 * scale, math.max(1.2, 2.2 * scale))
        end
    end

    -- Crackling energy bubble shield (front membrane, Fresnel rim & lightning arcs)
    if shieldsUp then
        drawShieldBubbleFront(cx, cy, shieldRx, shieldRy, spec.shieldCol, shieldPct, time, seed, lw)
    end

    lg.setLineWidth(1)
end

-- CSV VANGUARD (12-point isometric turnaround sprite sheet with animated engine FX)
function Sprites.drawPlayerShip(cx, cy, size, heading, shieldsUp, shieldPct, time, opts)
    opts = opts or {}
    local spec = SHIP_SPRITE_SPECS.player
    local drawOpts = {
        time = time,
        thrusting = opts.thrusting == true,
        hullPct = opts.hullPct or 1.0,
        shieldsUp = shieldsUp == true,
        shieldPct = shieldPct or 1.0,
        seed = 1.0,
    }
    applyTurnaroundFrame(spec, heading, math.pi * 0.5, drawOpts)
    drawSpriteShipWithFX(cx, cy, size, spec, drawOpts)
end

-- Hostile Insectoid Warships (Raider / Cruiser / Dreadnought / Stealth Frigate)
function Sprites.drawEnemyShip(cx, cy, size, enemy, time, opts)
    local lg = love.graphics
    opts = opts or {}
    local spec = SHIP_SPRITE_SPECS[enemy.class] or SHIP_SPRITE_SPECS.raider
    local hideBars = opts.hideBars == true
    local drawY = hideBars and cy or (cy - size * 0.04)
    local hullPct = (enemy.maxHull and enemy.maxHull > 0) and clamp01(enemy.hull / enemy.maxHull) or 1.0
    local shieldPct = (enemy.maxShield and enemy.maxShield > 0) and clamp01((enemy.shield or 0) / enemy.maxShield) or 0
    local shieldsUp = (not opts.hideShield) and (enemy.shield and enemy.shield > 0)
    local seed = (enemy.id or 1) * 1.37
    local spriteAlpha = (enemy.class == "stalker") and (0.80 + 0.20 * math.sin(time * 7.2 + seed)) or 1.0

    local drawOpts = {
        time = time,
        thrusting = opts.thrusting == true,
        hullPct = hullPct,
        shieldsUp = shieldsUp,
        shieldPct = shieldPct,
        seed = seed,
        spriteAlpha = spriteAlpha,
    }
    applyTurnaroundFrame(spec, enemy.heading or opts.heading or opts.fallbackHeading, 0, drawOpts)
    drawSpriteShipWithFX(cx, drawY, size, spec, drawOpts)

    if not hideBars then
        -- Compact Shield (cyan) & Hull (crimson/amber) micro-bars below sprite
        local barW = size * 0.66
        local bx = cx - barW * 0.5
        local by = cy + size * 0.34
        local shPct = (enemy.maxShield > 0) and math.max(0, enemy.shield / enemy.maxShield) or 0
        local huPct = (enemy.maxHull > 0) and math.max(0, enemy.hull / enemy.maxHull) or 0

        lg.setColor(0.04, 0.06, 0.10, 0.88)
        lg.rectangle("fill", bx - 1, by - 1, barW + 2, 8)
        lg.setColor(0.24, 0.86, 0.98, 0.95)
        lg.rectangle("fill", bx, by, barW * shPct, 2.5)
        lg.setColor(0.96, 0.28, 0.34, 0.95)
        lg.rectangle("fill", bx, by + 3.5, barW * huPct, 3)
    end
end

local outpostQuads = nil
local function getOutpostQuads()
    if not outpostQuads and love and love.graphics then
        outpostQuads = {}
        for i = 0, 3 do
            outpostQuads[i + 1] = love.graphics.newQuad(i * 64, 0, 64, 64, 256, 64)
        end
    end
    return outpostQuads
end

-- ORBITAL OUTPOST (4-frame spinning 64x64 isometric sprite sheet)
function Sprites.drawOutpost(cx, cy, size, time, underSiege)
    local lg = love.graphics
    local scale = size / 64
    local lw = math.max(1.0, size * 0.015)

    if underSiege then
        local pulse = 0.5 + 0.5 * math.sin(time * 6)
        local rx = size * (0.54 + 0.04 * pulse)
        local ry = rx * 0.62
        lg.setColor(1.0, 0.24, 0.20, 0.14 + 0.14 * pulse)
        lg.ellipse("fill", cx, cy + 2 * scale, rx, ry)
        lg.setColor(1.0, 0.28, 0.22, 0.45 + 0.45 * pulse)
        lg.setLineWidth(lw * 1.55)
        lg.ellipse("line", cx, cy + 2 * scale, rx, ry)
        lg.setLineWidth(1)
    end

    -- Soft reactor core bloom behind central hub
    local corePulse = 0.78 + 0.22 * math.sin(time * 4.2)
    lg.setColor(0.22, 0.90, 0.98, 0.16 * corePulse)
    lg.ellipse("fill", cx, cy - 2 * scale, 10 * scale, 6 * scale)

    local img = getShipSpriteImage("assets/sprites/outpost_sheet.png")
    local quads = getOutpostQuads()
    if img and quads then
        local frameIdx = (math.floor(time * 3.6) % 4) + 1
        lg.setColor(1, 1, 1, 1)
        lg.draw(img, quads[frameIdx], cx, cy, 0, scale, scale, 32, 32)
    end

    -- Subtle blinking spire & siege strobe beacon on top of central tower
    local blink = math.sin(time * 4.5) > 0
    if underSiege then
        lg.setColor(blink and 1.0 or 0.45, 0.20, 0.20, 0.95)
    else
        lg.setColor(0.45, 0.96, 1.0, blink and 0.95 or 0.40)
    end
    lg.circle("fill", cx - 2.0 * scale, cy - 12.5 * scale, math.max(0.9, 1.3 * scale))

    lg.setLineWidth(1)
end

function Sprites.drawStar(cx, cy, size, star, time)
    local lg = love.graphics
    local col = C.STAR_COLORS[star.colorIdx or 1] or C.STAR_COLORS[1]
    local r = size * 0.22 * (star.radius or 1.0)
    local pulse = 0.92 + 0.08 * math.sin(time * 3.2 + (star.id or 1))

    lg.setColor(col[1], col[2], col[3], 0.16)
    lg.circle("fill", cx, cy, r * 1.75 * pulse)
    lg.setColor(col[1], col[2], col[3], 0.35)
    lg.circle("fill", cx, cy, r * 1.25 * pulse)
    lg.setColor(col[1], col[2], col[3], 1)
    lg.circle("fill", cx, cy, r * 0.82)
    lg.setColor(1, 1, 0.94, 0.92)
    lg.circle("fill", cx - r * 0.15, cy - r * 0.15, r * 0.38)
end

local function getPlanetArchetype(planet)
    if planet.habitable then
        local idx = (planet.id or 1) % 3
        if idx == 0 then return PlanetRenderer.ARCHETYPES.terrestrial end
        if idx == 1 then return PlanetRenderer.ARCHETYPES.golden_savanna end
        return PlanetRenderer.ARCHETYPES.violet_alien
    end
    local c = planet.colorIdx or 1
    if c == 1 then return PlanetRenderer.ARCHETYPES.frozen_tundra end
    if c == 2 then return PlanetRenderer.ARCHETYPES.toxic_sulfur end
    if c == 3 then return PlanetRenderer.ARCHETYPES.crimson_waste end
    return PlanetRenderer.ARCHETYPES.violet_alien
end

local function drawPlanetRingHalf(cx, cy, rx, ry, isFront)
    local lg = love.graphics
    local a0 = isFront and 0 or math.pi
    local a1 = isFront and math.pi or (math.pi * 2)
    local pts = {}
    local steps = 20
    for i = 0, steps do
        local a = a0 + (a1 - a0) * (i / steps)
        pts[#pts + 1] = cx + math.cos(a) * rx
        pts[#pts + 1] = cy + math.sin(a) * ry
    end
    lg.setColor(0.84, 0.80, 0.70, isFront and 0.62 or 0.34)
    lg.setLineWidth(1.6)
    lg.line(pts)
    lg.setLineWidth(1)
end

function Sprites.drawPlanet(cx, cy, size, planet, time)
    local lg = love.graphics
    local r = size * 0.34
    local hasRing = (planet.colorIdx or 1) >= 3
    local archetype = getPlanetArchetype(planet)
    local seed = (planet.id or 1) * 17.3

    -- Back half of planetary ring (behind sphere)
    if hasRing then
        drawPlanetRingHalf(cx, cy, r * 1.48, r * 0.42, false)
    end

    -- Smooth 3D Simplex Noise planet shader with bump relief, dual clouds & Rayleigh halo
    PlanetRenderer.draw(cx, cy, r, seed, archetype, time, 0.0)

    -- Front half of planetary ring (in front of sphere)
    if hasRing then
        drawPlanetRingHalf(cx, cy, r * 1.48, r * 0.42, true)
    end

    -- Mineral fuel crystal badge if unmined fuel present
    if planet.hasFuel and not planet.mined then
        local gl = 0.65 + 0.35 * math.sin(time * 4.5)
        local bx, by = cx + r * 0.85, cy - r * 0.85
        lg.setColor(0.24, 0.94, 0.98, gl)
        lg.polygon("fill", bx, by - 5, bx + 4, by, bx, by + 5, bx - 4, by)
    end
end

function Sprites.drawSingularity(cx, cy, size, time)
    local lg = love.graphics
    local r = size * 0.28

    lg.push()
    lg.translate(cx, cy)
    lg.rotate(time * 1.4 + 0.5)

    lg.setColor(0.55, 0.24, 0.92, 0.25)
    lg.circle("fill", 0, 0, r * 1.35)
    lg.setColor(0.75, 0.42, 1.0, 0.72)
    lg.setLineWidth(2)
    lg.arc("line", "open", 0, 0, r * 1.05, 0, math.pi * 1.35)
    lg.arc("line", "open", 0, 0, r * 1.05, math.pi, math.pi * 2.35)
    lg.setColor(0.28, 0.82, 0.98, 0.75)
    lg.arc("line", "open", 0, 0, r * 0.74, 0.6, math.pi * 1.7)
    lg.setLineWidth(1)

    -- Event horizon core
    lg.setColor(0.02, 0.02, 0.05, 1)
    lg.circle("fill", 0, 0, r * 0.52)
    lg.setColor(0.68, 0.35, 1.0, 0.85)
    lg.circle("line", 0, 0, r * 0.52)

    lg.pop()
end

return Sprites
