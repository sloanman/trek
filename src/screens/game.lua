-- Main Starbridge Tactical Console Screen for Vanguard Command

local C = require("src.constants")
local UI = require("src.ui")
local Sprites = require("src.sprites")
local Galaxy = require("src.galaxy")
local Engine = require("src.engine")
local Movement = require("src.movement")
local Combat = require("src.combat")
local Commands = require("src.commands")
local Animations = require("src.animations")
local Sound = require("src.sound")
local Storage = require("src.storage")
local Overlays = require("src.screens.overlays")

local Game = {}

local state = nil
local activeMode = "sublight" -- "sublight" | "ftl" | "beams" | "torpedo" | "probe"
local beamPower = 350
local ftlFactor = 5
local targetQuad = nil        -- { qx, qy } for FTL Engage button / Distress intercept

local cliFocused = false
local cliAutoPaused = false
local cliText = ""
local cliHistory = {}
local cliHistIdx = 0
local logScrollOffset = 0
local timeAccum = 0
local uiTime = 0
local simTime = 0
local scoreRecorded = false

local hoverTile = nil
local hoverQuad = nil
local hitBoxes = {}
local visualHeading = 0
local dragPlot = nil

local function setCliFocused(focused, keepPaused)
    if focused then
        if not cliFocused then
            cliFocused = true
            if state and state.status == "active" and not state.paused then
                state.paused = true
                cliAutoPaused = true
            end
        end
    else
        if cliFocused then
            cliFocused = false
            if cliAutoPaused and not keepPaused and state and state.status == "active" then
                state.paused = false
            end
            cliAutoPaused = false
        end
    end
end

function Game.getState()
    return state
end

function Game.isCliFocused()
    return cliFocused
end

function Game.setMode(mode)
    activeMode = mode
    dragPlot = nil
end

function Game.enter(loadedState)
    state = loadedState
    Engine.ensureRealtimeState(state)
    activeMode = "sublight"
    beamPower = 350
    ftlFactor = 5
    targetQuad = nil
    cliFocused = false
    cliAutoPaused = false
    cliText = ""
    logScrollOffset = 0
    simTime = state.simTime or 0
    scoreRecorded = (state.status ~= "active")
    visualHeading = state.player and state.player.heading or 0
    dragPlot = nil
    Animations.reset()
    Overlays.close()
end

local function recordOutcomeIfNeeded()
    if state and state.status ~= "active" and not scoreRecorded then
        scoreRecorded = true
        local info = Engine.calculateFinalScore(state)
        Storage.addScore({
            score = info.total,
            rank = info.rank,
            victory = (state.status == "victory"),
            difficulty = state.difficulty,
            kills = state.stats.totalKills,
            cycles = state.cycle,
            seed = state.seed,
        })
        Storage.deleteSave()
        Overlays.open("debrief", state)
    elseif state and state.status == "active" then
        Storage.saveGame(state)
    end
end

local function applyActionResult(res)
    if not res then return end
    if res.events and #res.events > 0 then
        Animations.pushEvents(res.events)
    end
    if not res.ok and res.msg then
        Engine.addLog(state, res.msg, "amber")
        Sound.play("alert", 0.5)
    end
    logScrollOffset = 0
    if res.uiAction == "open_help" then
        Overlays.open("help")
    elseif res.uiAction == "save" then
        if Storage.saveGame(state) then
            Engine.addLog(state, "Mission state saved.", "emerald")
            Sound.play("dock", 0.6)
        end
    elseif res.uiAction == "load" then
        local loaded = Storage.loadGame()
        if loaded then
            Game.enter(loaded)
            Engine.addLog(state, "Loaded saved mission state.", "cyan")
            Sound.play("scan", 0.7)
            return
        else
            Engine.addLog(state, "No saved mission found.", "amber")
        end
    end
    recordOutcomeIfNeeded()
end

local function findActiveSieges()
    local list = {}
    if not state then return list end
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            local q = state.galaxy.quadrants[qy][qx]
            if q.siege then
                local op = Galaxy.getOutpost(q)
                list[#list + 1] = {
                    qx = qx,
                    qy = qy,
                    name = op and op.name or string.format("Outpost Q(%d,%d)", qx, qy),
                    cyclesLeft = q.siege.cyclesLeft,
                }
            end
        end
    end
    table.sort(list, function(a, b) return a.cyclesLeft < b.cyclesLeft end)
    return list
end

local function computeLethalBeamPower()
    if not state then return 350 end
    Combat.ensureCombatState(state)
    local quad = Engine.currentQuad(state)
    local p = state.player
    local targets = {}
    if p.weapons.beams.mode == "focused" and p.targetId then
        local e = Galaxy.getEntityById(quad, p.targetId)
        if e and e.kind == "enemy" and not e.cloaked then
            targets[1] = e
        end
    else
        targets = Galaxy.getEnemies(quad, false)
    end
    if #targets == 0 then return 350 end

    local eff = 0.35 + 0.65 * (p.systems.beams / 100)
    local stormMult = quad.ionStorm and 0.72 or 1.0
    local neededMax = 0
    for _, e in ipairs(targets) do
        local dist = math.sqrt((e.x - p.sx) ^ 2 + (e.y - p.sy) ^ 2)
        local falloff = 1 / (0.82 + 0.20 * dist)
        local hp = e.shield + e.hull
        local reqPerTarget = math.ceil((hp / (eff * falloff * stormMult)) * 1.12)
        if reqPerTarget > neededMax then
            neededMax = reqPerTarget
        end
    end
    local total = math.max(50, math.min(p.energy, neededMax * #targets))
    return math.floor(total)
end

-- ======================== UPDATE ========================

function Game.update(dt)
    uiTime = uiTime + dt
    timeAccum = uiTime
    if not state then return end

    if state.status == "active" and not state.paused and not Overlays.isOpen() then
        simTime = simTime + dt
        local rtRes = Engine.updateRealtime(state, dt)
        if rtRes and rtRes.events and #rtRes.events > 0 then
            Animations.pushEvents(rtRes.events)
        end
        Animations.update(dt)
        if state.status ~= "active" then
            recordOutcomeIfNeeded()
        end
    end

    if state.player then
        local target = state.player.heading or 0
        if Animations.isGliding("player") and not Animations.isFastMode() then
            local diff = ((target - visualHeading + math.pi) % (math.pi * 2)) - math.pi
            local maxStep = dt * 10.5
            if math.abs(diff) <= maxStep then
                visualHeading = target
            else
                visualHeading = visualHeading + (diff >= 0 and maxStep or -maxStep)
            end
        else
            visualHeading = target
        end
    end
end

-- ======================== PANEL DRAWING ========================

local function drawTopBar(mx, my, prefs)
    local lg = love.graphics
    local r = C.LAYOUT.topBar
    local p = state.player

    lg.setColor(C.COLORS.panelHeader)
    lg.rectangle("fill", r.x, r.y, r.w, r.h)
    lg.setColor(C.COLORS.border)
    lg.line(0, r.h, r.w, r.h)

    -- Ship Callsign
    lg.setFont(UI.fonts.lg)
    lg.setColor(C.COLORS.cyan)
    lg.print(state.shipName, 14, 11)

    -- Condition Badge
    local cond = Engine.getCondition(state)
    local condCol = C.COLORS.emerald
    if cond == "RED" then condCol = C.COLORS.crimson
    elseif cond == "YELLOW" then condCol = C.COLORS.amber
    elseif cond == "DOCKED" then condCol = C.COLORS.cyan end

    local badgePulse = (cond == "RED") and (0.65 + 0.35 * math.sin(uiTime * 7)) or 1.0
    lg.setColor(condCol[1] * 0.22, condCol[2] * 0.22, condCol[3] * 0.22, 0.95)
    lg.rectangle("fill", 162, 8, 66, 28, 4, 4)
    lg.setColor(condCol[1], condCol[2], condCol[3], badgePulse)
    lg.rectangle("line", 162, 8, 66, 28, 4, 4)
    lg.setFont(UI.fonts.xs)
    lg.printf(cond, 162, 16, 66, "center")

    -- Tactical Pause Toggle Button
    local isPaused = state.paused == true
    local _, pauseBtnRect = UI.drawButton(234, 8, 104, 28, isPaused and "PAUSED [SPC]" or "LIVE [SPC]", mx, my, {
        active = true,
        pulse = isPaused,
        accent = isPaused and C.COLORS.amber or C.COLORS.emerald,
        time = uiTime,
        font = UI.fonts.xs,
    })
    hitBoxes[#hitBoxes + 1] = { rect = pauseBtnRect, action = "toggle_tac_pause" }

    -- Tactical counters
    local hostiles = Galaxy.countTotalHostiles(state.galaxy)
    local outposts = Galaxy.countTotalOutposts(state.galaxy)
    local cycLeft = math.max(0, state.maxCycles - state.cycle)

    lg.setFont(UI.fonts.xs)
    lg.setColor(C.COLORS.text)
    lg.print(string.format("LOC: Q(%d,%d) S(%d,%d)", p.qx, p.qy, p.sx, p.sy), 346, 16)

    lg.setColor(hostiles > 0 and C.COLORS.crimson or C.COLORS.emerald)
    lg.print(string.format("HOSTILES: %d", hostiles), 468, 16)

    lg.setColor(C.COLORS.emerald)
    lg.print(string.format("OUTPOSTS: %d", outposts), 562, 16)

    lg.setColor(cycLeft <= 6 and C.COLORS.crimson or C.COLORS.amber)
    lg.print(string.format("CYC: %.1f/%d", state.cycle, state.maxCycles), 656, 16)

    lg.setColor(C.COLORS.gold)
    lg.print(string.format("SCORE: %d", state.score), 762, 16)

    -- Utility buttons on right
    local utils = {
        { label = (prefs and prefs.muted) and "SFX:OFF" or "SFX:ON", action = "toggle_mute", accent = C.COLORS.amber, w = 64 },
        { label = (prefs and prefs.crt) and "CRT:ON" or "CRT:OFF",   action = "toggle_crt",  accent = C.COLORS.amber, w = 64 },
        { label = (prefs and prefs.fastAnim) and "FAST" or "NORM",   action = "toggle_fast", accent = C.COLORS.cyan,  w = 54 },
        { label = "SAVE", action = "save",  accent = C.COLORS.emerald, w = 52 },
        { label = "HELP", action = "help",  accent = C.COLORS.cyan,    w = 52 },
        { label = "MENU", action = "pause", accent = C.COLORS.textDim, w = 54 },
    }
    local bx = 894
    for _, u in ipairs(utils) do
        local _, rect = UI.drawButton(bx, 8, u.w, 28, u.label, mx, my, { accent = u.accent, font = UI.fonts.xs })
        hitBoxes[#hitBoxes + 1] = { rect = rect, action = u.action }
        bx = bx + u.w + 6
    end
end

local function drawStarmap(mx, my)
    local lg = love.graphics
    local r = C.LAYOUT.starmap
    UI.drawPanel(r, "GALACTIC STARMAP (E-B-S)", C.COLORS.cyan, timeAccum)

    local gx = r.x + 26
    local gy = r.y + 40
    local cw = 30
    local ch = 24
    hoverQuad = nil

    -- Column labels 1..8
    lg.setFont(UI.fonts.xs)
    lg.setColor(C.COLORS.textDim)
    for x = 1, C.GRID_SIZE do
        lg.printf(tostring(x), gx + (x - 1) * cw, gy - 15, cw, "center")
    end
    for y = 1, C.GRID_SIZE do
        lg.print(tostring(y), gx - 16, gy + (y - 1) * ch + 5)
    end

    local p = state.player
    for qy = 1, C.GRID_SIZE do
        for qx = 1, C.GRID_SIZE do
            local quad = state.galaxy.quadrants[qy][qx]
            local x = gx + (qx - 1) * cw
            local y = gy + (qy - 1) * ch
            local cellRect = { x = x, y = y, w = cw - 2, h = ch - 2 }
            local isCurrent = (qx == p.qx and qy == p.qy)
            local isTarget = (targetQuad and targetQuad.qx == qx and targetQuad.qy == qy)
            local hovered = UI.pointInRect(mx, my, cellRect)
            if hovered then
                hoverQuad = { qx = qx, qy = qy, quad = quad }
            end

            -- Cell background
            if isCurrent then
                lg.setColor(0.10, 0.28, 0.42, 0.95)
            elseif quad.explored then
                lg.setColor(0.06, 0.10, 0.18, 0.95)
            else
                lg.setColor(0.03, 0.05, 0.09, 0.95)
            end
            lg.rectangle("fill", cellRect.x, cellRect.y, cellRect.w, cellRect.h, 2, 2)

            -- Siege pulse ring
            if quad.siege then
                local pulse = 0.45 + 0.55 * math.sin(timeAccum * 6)
                lg.setColor(1.0, 0.30, 0.22, pulse)
                lg.setLineWidth(1.8)
                lg.rectangle("line", cellRect.x, cellRect.y, cellRect.w, cellRect.h, 2, 2)
                lg.setLineWidth(1)
            elseif isCurrent then
                lg.setColor(C.COLORS.cyan)
                lg.setLineWidth(1.6)
                lg.rectangle("line", cellRect.x, cellRect.y, cellRect.w, cellRect.h, 2, 2)
                lg.setLineWidth(1)
            elseif isTarget then
                lg.setColor(C.COLORS.gold)
                lg.rectangle("line", cellRect.x, cellRect.y, cellRect.w, cellRect.h, 2, 2)
            elseif hovered then
                lg.setColor(activeMode == "probe" and C.COLORS.violet or C.COLORS.amber)
                lg.rectangle("line", cellRect.x, cellRect.y, cellRect.w, cellRect.h, 2, 2)
            else
                lg.setColor(C.COLORS.gridLine)
                lg.rectangle("line", cellRect.x, cellRect.y, cellRect.w, cellRect.h, 2, 2)
            end

            -- Quadrant EBS code or ???
            lg.setFont(UI.fonts.xs)
            if quad.explored then
                local code, counts = Galaxy.getIntelCode(quad)
                if counts.enemies > 0 then
                    lg.setColor(C.COLORS.crimson)
                elseif counts.outposts > 0 then
                    lg.setColor(C.COLORS.emerald)
                elseif quad.ionStorm then
                    lg.setColor(C.COLORS.amber)
                else
                    lg.setColor(C.COLORS.textDim)
                end
                lg.printf(code, cellRect.x, cellRect.y + 4, cellRect.w, "center")
            else
                lg.setColor(C.COLORS.textMuted)
                lg.printf("???", cellRect.x, cellRect.y + 4, cellRect.w, "center")
            end

            hitBoxes[#hitBoxes + 1] = { rect = cellRect, action = "starmap_cell", qx = qx, qy = qy }
        end
    end

    -- Hover intel footer
    local fy = r.y + r.h - 40
    lg.setColor(C.COLORS.border)
    lg.line(r.x + 10, fy - 4, r.x + r.w - 10, fy - 4)
    lg.setFont(UI.fonts.xs)
    if hoverQuad then
        local q = hoverQuad.quad
        if q.explored then
            local _, c = Galaxy.getIntelCode(q)
            local stormTag = q.ionStorm and " [ION STORM]" or ""
            local siegeTag = q.siege and string.format(" [SIEGE %.1fc]", q.siege.cyclesLeft) or ""
            lg.setColor(C.COLORS.cyan)
            lg.print(string.format("Q(%d,%d): %d Enm, %d Base, %d Star%s%s",
                hoverQuad.qx, hoverQuad.qy, c.enemies, c.outposts, c.stars, stormTag, siegeTag), r.x + 10, fy)
        else
            lg.setColor(C.COLORS.textDim)
            lg.print(string.format("Q(%d,%d): Uncharted — Click to FTL or Probe", hoverQuad.qx, hoverQuad.qy), r.x + 10, fy)
        end
        local prev = Engine.previewFTL(state, hoverQuad.qx, hoverQuad.qy, ftlFactor)
        if prev.ok then
            lg.setColor(prev.shieldsPenalty and C.COLORS.amber or C.COLORS.textDim)
            lg.print(string.format("FTL F%d: %d E%s  |  +%.2f cyc",
                ftlFactor, prev.energyCost, prev.shieldsPenalty and " (2x SHD)" or "", prev.cycleCost), r.x + 10, fy + 16)
        elseif hoverQuad.qx == p.qx and hoverQuad.qy == p.qy then
            lg.setColor(C.COLORS.emerald)
            lg.print("Current ship quadrant.", r.x + 10, fy + 16)
        else
            lg.setColor(C.COLORS.crimson)
            lg.print(prev.reason or "", r.x + 10, fy + 16)
        end
    else
        lg.setColor(C.COLORS.textDim)
        lg.print("E-B-S = Enemies / Bases / Stars", r.x + 10, fy)
        lg.print("Click quadrant to target FTL or Probe.", r.x + 10, fy + 16)
    end
end

local function drawVitals(mx, my)
    local lg = love.graphics
    local r = C.LAYOUT.vitals
    local p = state.player
    UI.drawPanel(r, "SHIP VITALS & POWER GRID", C.COLORS.emerald, timeAccum)

    local x = r.x + 12
    local w = r.w - 24
    local y = r.y + 32

    -- Hull, Energy, Shields
    local hullPct = p.hull / p.maxHull
    local hullCol = hullPct > 0.5 and C.COLORS.emerald or (hullPct > 0.25 and C.COLORS.amber or C.COLORS.crimson)
    UI.drawBar(x, y, w, 19, hullPct, hullCol, "HULL", string.format("%d / %d", p.hull, p.maxHull))

    local engPct = p.energy / p.maxEnergy
    local engCol = engPct > 0.3 and C.COLORS.cyan or C.COLORS.amber
    UI.drawBar(x, y + 25, w, 19, engPct, engCol, "ENERGY", string.format("%d / %d", p.energy, p.maxEnergy))

    local shdPct = p.shields / p.maxShields
    local shdCol = p.shieldsUp and C.COLORS.cyan or C.COLORS.blue
    UI.drawBar(x, y + 50, w, 19, shdPct, shdCol, p.shieldsUp and "SHIELDS [UP]" or "SHIELDS [DN]",
        string.format("%d / %d", p.shields, p.maxShields))

    -- Shield toggle + transfer buttons
    local by = y + 76
    local _, rShdTog = UI.drawButton(x, by, 72, 24, p.shieldsUp and "DROP" or "RAISE", mx, my, {
        active = p.shieldsUp,
        accent = C.COLORS.cyan,
        font = UI.fonts.xs,
    })
    local _, rShdMinus = UI.drawButton(x + 78, by, 56, 24, "-200", mx, my, { accent = C.COLORS.amber, font = UI.fonts.xs })
    local _, rShdPlus  = UI.drawButton(x + 140, by, 56, 24, "+200", mx, my, { accent = C.COLORS.cyan, font = UI.fonts.xs })
    local _, rShdMax   = UI.drawButton(x + 202, by, 54, 24, "MAX", mx, my, { accent = C.COLORS.cyan, font = UI.fonts.xs })
    hitBoxes[#hitBoxes + 1] = { rect = rShdTog, action = "toggle_shields" }
    hitBoxes[#hitBoxes + 1] = { rect = rShdMinus, action = "shield_delta", delta = -200 }
    hitBoxes[#hitBoxes + 1] = { rect = rShdPlus, action = "shield_delta", delta = 200 }
    hitBoxes[#hitBoxes + 1] = { rect = rShdMax, action = "shield_delta", delta = p.maxShields }

    -- Aux Reserve + Ammo counters
    local ay = by + 32
    local _, rAux = UI.drawButton(x, ay, 118, 26, string.format("AUX BATT (%d)", p.auxReserve), mx, my, {
        disabled = p.auxReserve <= 0 or p.energy >= p.maxEnergy,
        accent = C.COLORS.emerald,
        font = UI.fonts.xs,
    })
    hitBoxes[#hitBoxes + 1] = { rect = rAux, action = "use_aux" }

    lg.setFont(UI.fonts.xs)
    lg.setColor(C.COLORS.amber)
    lg.print(string.format("TORP: %d/%d", p.torpedoes, p.maxTorpedoes), x + 128, ay + 6)
    lg.setColor(C.COLORS.violet)
    lg.print(string.format("PRB: %d/%d", p.probes, p.maxProbes), x + 202, ay + 6)

    -- Beam Heat bar
    local hy = ay + 34
    local heatPct = math.floor((p.beamHeat or 0) + 0.5)
    local heatCol = heatPct >= 80 and C.COLORS.crimson or (heatPct >= 50 and C.COLORS.amber or C.COLORS.emerald)
    UI.drawBar(x, hy, w, 17, heatPct / 100, heatCol, "BEAM HEAT", string.format("%d%%", heatPct))

    -- Warnings / Quick Tactical Readout
    local wy = hy + 26
    lg.setFont(UI.fonts.xs)
    if p.shieldsUp then
        lg.setColor(C.COLORS.amber)
        lg.print("! Shields UP: FTL/Thruster E cost x2", x, wy)
        wy = wy + 16
    end
    local quad = Engine.currentQuad(state)
    if quad.ionStorm then
        lg.setColor(C.COLORS.amber)
        lg.print("! Ion Storm: Beam damage -28%", x, wy)
        wy = wy + 16
    end
    if p.systems.lifesupport <= 0 and not p.docked then
        lg.setColor(C.COLORS.crimson)
        lg.print(string.format("! LIFE SUPPORT OFFLINE (%.1f cyc left)", math.max(0, p.lifeSupportTimer)), x, wy)
        wy = wy + 16
    end
    if Engine.canDock(state) and not p.docked then
        lg.setColor(C.COLORS.emerald)
        lg.print("* Adjacent to Outpost: Click DOCK [8]", x, wy)
    elseif Engine.getAdjacentMineablePlanet(state) then
        lg.setColor(C.COLORS.cyan)
        lg.print("* Fuel planet adjacent: Run SCAN [7]", x, wy)
    end
end

local function isoToScreen(u, v, g)
    return g.isoOriginX + (u - v) * g.isoHalfW, g.isoOriginY + (u + v) * g.isoHalfH
end

local function isoTileCenter(tx, ty, g)
    return isoToScreen(tx - 0.5, ty - 0.5, g)
end

local function screenToIsoFloat(mx, my, g)
    local dx = (mx - g.isoOriginX) / g.isoHalfW
    local dy = (my - g.isoOriginY) / g.isoHalfH
    return (dx + dy) * 0.5, (dy - dx) * 0.5
end

local function screenToWorld(mx, my, g)
    local u, v = screenToIsoFloat(mx, my, g)
    local inBounds = (u >= 0 and u <= C.GRID_SIZE and v >= 0 and v <= C.GRID_SIZE)
    local wx = Movement.clamp(u * C.SECTOR_WORLD_SCALE, C.WORLD_MARGIN, C.WORLD_SIZE - C.WORLD_MARGIN)
    local wy = Movement.clamp(v * C.SECTOR_WORLD_SCALE, C.WORLD_MARGIN, C.WORLD_SIZE - C.WORLD_MARGIN)
    return wx, wy, inBounds
end

local function worldToScreen(wx, wy, g)
    return isoToScreen(wx / C.SECTOR_WORLD_SCALE, wy / C.SECTOR_WORLD_SCALE, g)
end

local function screenToIsoTile(mx, my, g)
    local u, v = screenToIsoFloat(mx, my, g)
    local tx = math.floor(u) + 1
    local ty = math.floor(v) + 1
    if tx >= 1 and tx <= C.GRID_SIZE and ty >= 1 and ty <= C.GRID_SIZE then
        return tx, ty
    end
    return nil
end

local function drawHeadingArrow(wx, wy, angle, g, col, lenWorld)
    local lg = love.graphics
    local bx, by = worldToScreen(wx, wy, g)
    local tipX, tipY = worldToScreen(wx + math.cos(angle) * lenWorld, wy + math.sin(angle) * lenWorld, g)
    local dx, dy = tipX - bx, tipY - by
    local slen = math.sqrt(dx * dx + dy * dy)
    if slen < 2 then return end
    local ux, uy = dx / slen, dy / slen
    local px, py = -uy, ux

    lg.setLineWidth(2.4)
    lg.setColor(col[1], col[2], col[3], 0.95)
    lg.line(bx, by, tipX, tipY)
    lg.setLineWidth(1)

    local headLen = math.min(10, slen * 0.45)
    local headW = 4.8
    lg.polygon("fill",
        tipX + ux * 2, tipY + uy * 2,
        tipX - ux * headLen + px * headW, tipY - uy * headLen + py * headW,
        tipX - ux * headLen - px * headW, tipY - uy * headLen - py * headW
    )
end

local function drawVectorPath(curve, shipX, shipY, g, col, isPreview, coverage)
    if not curve then return end
    local lg = love.graphics
    local isoRatio = g.isoHalfH / g.isoHalfW
    local alphaMult = isPreview and 1.0 or 0.86

    if curve.kind == "turn" then
        local sx, sy = worldToScreen(shipX, shipY, g)
        local inArc = coverage and coverage.segmentInBeam and coverage.segmentInBeam[1]
        local turnCol = inArc and C.COLORS.emerald or col
        lg.setColor(turnCol[1], turnCol[2], turnCol[3], 0.55 * alphaMult)
        lg.setLineWidth(1.8)
        lg.ellipse("line", sx, sy, 22, 22 * isoRatio)
        lg.setLineWidth(1)
        drawHeadingArrow(shipX, shipY, curve.endHeading, g, turnCol, 56)
        return
    end

    local pts = curve.points
    if not pts or #pts < 2 then return end

    local screenPts = {}
    local startX, startY = worldToScreen(shipX, shipY, g)
    screenPts[1] = startX
    screenPts[2] = startY

    local startIdx = isPreview and 2 or math.max(2, curve.cursor or 2)
    for i = startIdx, #pts do
        local sx, sy = worldToScreen(pts[i].x, pts[i].y, g)
        screenPts[#screenPts + 1] = sx
        screenPts[#screenPts + 1] = sy
    end

    if #screenPts >= 4 then
        lg.setLineWidth(4.0)
        lg.setColor(col[1], col[2], col[3], 0.24 * alphaMult)
        lg.line(screenPts)
        if coverage and coverage.segmentInBeam then
            lg.setLineWidth(2.2)
            local px, py = startX, startY
            for i = startIdx, #pts do
                local sx, sy = worldToScreen(pts[i].x, pts[i].y, g)
                local sc = coverage.segmentInBeam[i] and C.COLORS.emerald or col
                lg.setColor(sc[1], sc[2], sc[3], 0.94 * alphaMult)
                lg.line(px, py, sx, sy)
                px, py = sx, sy
            end
        else
            lg.setLineWidth(1.8)
            lg.setColor(col[1], col[2], col[3], 0.92 * alphaMult)
            lg.line(screenPts)
        end
        lg.setLineWidth(1)
    end

    for i = startIdx, #pts - 1, 4 do
        local wx, wy = worldToScreen(pts[i].x, pts[i].y, g)
        local dc = (coverage and coverage.segmentInBeam and coverage.segmentInBeam[i]) and C.COLORS.emerald or col
        lg.setColor(dc[1], dc[2], dc[3], 0.78 * alphaMult)
        lg.circle("fill", wx, wy, 1.9)
    end

    local endInArc = coverage and coverage.segmentInBeam and coverage.segmentInBeam[#pts]
    local endCol = endInArc and C.COLORS.emerald or col
    local ex, ey = worldToScreen(curve.p3.x, curve.p3.y, g)
    lg.setColor(endCol[1], endCol[2], endCol[3], 0.22 * alphaMult)
    lg.ellipse("fill", ex, ey, 11, 11 * isoRatio)
    lg.setColor(endCol[1], endCol[2], endCol[3], 0.95 * alphaMult)
    lg.setLineWidth(1.6)
    lg.ellipse("line", ex, ey, 11, 11 * isoRatio)
    lg.setLineWidth(1)
    lg.circle("fill", ex, ey, 2.5)

    drawHeadingArrow(curve.p3.x, curve.p3.y, curve.endHeading, g, endCol, 52)
end

-- Sutherland-Hodgman clip against tactical arena bounds [0, WORLD_SIZE]^2
local function clipEdge(poly, insideFn, intersectFn)
    local out = {}
    local n = #poly
    if n == 0 then return out end
    local prev = poly[n]
    local prevIn = insideFn(prev)
    for i = 1, n do
        local cur = poly[i]
        local curIn = insideFn(cur)
        if curIn then
            if not prevIn then
                out[#out + 1] = intersectFn(prev, cur)
            end
            out[#out + 1] = cur
        elseif prevIn then
            out[#out + 1] = intersectFn(prev, cur)
        end
        prev = cur
        prevIn = curIn
    end
    return out
end

local function clipPolyToWorld(pts)
    local maxW = C.WORLD_SIZE
    local p = clipEdge(pts, function(v) return v.x >= 0 end, function(a, b)
        local dx = b.x - a.x
        local t = (math.abs(dx) > 1e-8) and (-a.x / dx) or 0
        return { x = 0, y = a.y + (b.y - a.y) * t }
    end)
    p = clipEdge(p, function(v) return v.x <= maxW end, function(a, b)
        local dx = b.x - a.x
        local t = (math.abs(dx) > 1e-8) and ((maxW - a.x) / dx) or 0
        return { x = maxW, y = a.y + (b.y - a.y) * t }
    end)
    p = clipEdge(p, function(v) return v.y >= 0 end, function(a, b)
        local dy = b.y - a.y
        local t = (math.abs(dy) > 1e-8) and (-a.y / dy) or 0
        return { x = a.x + (b.x - a.x) * t, y = 0 }
    end)
    p = clipEdge(p, function(v) return v.y <= maxW end, function(a, b)
        local dy = b.y - a.y
        local t = (math.abs(dy) > 1e-8) and ((maxW - a.y) / dy) or 0
        return { x = a.x + (b.x - a.x) * t, y = maxW }
    end)

    local dedup = {}
    for _, v in ipairs(p) do
        local last = dedup[#dedup]
        if not last or math.abs(v.x - last.x) > 0.25 or math.abs(v.y - last.y) > 0.25 then
            dedup[#dedup + 1] = v
        end
    end
    if #dedup >= 2 then
        local first, last = dedup[1], dedup[#dedup]
        if math.abs(first.x - last.x) <= 0.25 and math.abs(first.y - last.y) <= 0.25 then
            dedup[#dedup] = nil
        end
    end
    return dedup
end

local function drawFiringCone(wx, wy, heading, arcCenter, arcWidth, range, g, fillCol, rimCol)
    local lg = love.graphics
    local ox = Movement.clamp(wx, 0, C.WORLD_SIZE)
    local oy = Movement.clamp(wy, 0, C.WORLD_SIZE)
    local axis = (heading or 0) + (arcCenter or 0)
    local halfArc = (arcWidth or math.pi) * 0.5
    local steps = 28

    local poly = { { x = ox, y = oy } }
    for i = 0, steps do
        local a = (axis - halfArc) + (i / steps) * (halfArc * 2)
        poly[#poly + 1] = {
            x = ox + math.cos(a) * range,
            y = oy + math.sin(a) * range,
        }
    end

    local clipped = clipPolyToWorld(poly)
    if #clipped < 3 then return end

    local verts = {}
    for _, pt in ipairs(clipped) do
        local sx, sy = worldToScreen(pt.x, pt.y, g)
        verts[#verts + 1] = sx
        verts[#verts + 1] = sy
    end

    if #verts >= 6 then
        lg.setColor(fillCol)
        lg.polygon("fill", verts)
        lg.setLineWidth(1.3)
        lg.setColor(rimCol)
        lg.polygon("line", verts)
        lg.setLineWidth(1)
    end
end

local function drawBadgeText(x, y, text, col, bgAlpha)
    local lg = love.graphics
    local f = UI.fonts.xs
    lg.setFont(f)
    local tw = f:getWidth(text) + 8
    local bx = x - tw * 0.5
    lg.setColor(0.03, 0.05, 0.10, bgAlpha or 0.88)
    lg.rectangle("fill", bx, y, tw, 14, 2, 2)
    lg.setColor(col)
    lg.rectangle("line", bx, y, tw, 14, 2, 2)
    lg.printf(text, bx, y + 1, tw, "center")
end

local function drawTargetReticles(g, p, quad, status, dragCoverage)
    local lg = love.graphics
    local isoRatio = g.isoHalfH / g.isoHalfW

    -- Secondary Spread Targets (if spread active)
    if status and status.beams.mode == "spread" then
        for _, entry in ipairs(status.beams.inArcTargets) do
            local e = entry.entity
            if e.id ~= p.targetId then
                local vx, vy = Animations.getEntityVisualPos(e.id, e.x, e.y)
                local ex, ey = isoToScreen(vx - 0.5, vy - 0.5, g)
                local pulse = 0.55 + 0.35 * math.sin(uiTime * 5 + e.id)
                local rx, ry = g.isoHalfW * 0.64, g.isoHalfW * 0.64 * isoRatio
                lg.setColor(C.COLORS.emerald[1], C.COLORS.emerald[2], C.COLORS.emerald[3], pulse)
                lg.setLineWidth(1.5)
                lg.polygon("line", ex, ey - ry - 4, ex + rx + 4, ey, ex, ey + ry + 4, ex - rx - 4, ey)
                lg.setLineWidth(1)
            end
        end
    end

    -- Primary Target Bracket Reticle
    if status and status.primary then
        local e = status.primary.entity
        local vx, vy = Animations.getEntityVisualPos(e.id, e.x, e.y)
        local ex, ey = isoToScreen(vx - 0.5, vy - 0.5, g)
        local rCol = status.inBeamArc and C.COLORS.emerald or (status.inTorpArc and C.COLORS.amber or C.COLORS.crimson)
        local pulse = 0.72 + 0.28 * math.sin(uiTime * 7)
        local hw, hh = 21, 16

        lg.setColor(rCol[1], rCol[2], rCol[3], 0.16 * pulse)
        lg.ellipse("fill", ex, ey, hw, hh * 0.9)
        lg.setColor(rCol[1], rCol[2], rCol[3], pulse)
        lg.setLineWidth(2.0)
        local arm = 7
        -- Four tactical corner brackets
        lg.line(ex - hw, ey - hh + arm, ex - hw, ey - hh, ex - hw + arm, ey - hh)
        lg.line(ex + hw - arm, ey - hh, ex + hw, ey - hh, ex + hw, ey - hh + arm)
        lg.line(ex - hw, ey + hh - arm, ex - hw, ey + hh, ex - hw + arm, ey + hh)
        lg.line(ex + hw - arm, ey + hh, ex + hw, ey + hh, ex + hw, ey + hh - arm)
        lg.setLineWidth(1)
    end

    -- Projected curve-drag target-in-arc highlights
    if dragCoverage and dragCoverage.byEnemyId then
        for _, info in pairs(dragCoverage.byEnemyId) do
            local e = info.entity
            local vx, vy = Animations.getEntityVisualPos(e.id, e.x, e.y)
            local ex, ey = isoToScreen(vx - 0.5, vy - 0.5, g)
            if info.inBeamAtEnd then
                lg.setColor(C.COLORS.emerald[1], C.COLORS.emerald[2], C.COLORS.emerald[3], 0.85)
                lg.setLineWidth(1.8)
                lg.ellipse("line", ex, ey, 24, 24 * isoRatio)
                lg.setLineWidth(1)
                drawBadgeText(ex, ey - 36, "ARC LOCK", C.COLORS.emerald)
            elseif info.inTorpAtEnd then
                lg.setColor(C.COLORS.amber[1], C.COLORS.amber[2], C.COLORS.amber[3], 0.75)
                lg.setLineWidth(1.5)
                lg.ellipse("line", ex, ey, 23, 23 * isoRatio)
                lg.setLineWidth(1)
                drawBadgeText(ex, ey - 36, "TORP ARC", C.COLORS.amber)
            elseif info.inBeamAlongCurve then
                lg.setColor(C.COLORS.cyan[1], C.COLORS.cyan[2], C.COLORS.cyan[3], 0.55)
                lg.ellipse("line", ex, ey, 21, 21 * isoRatio)
                drawBadgeText(ex, ey - 36, "PASS ARC", C.COLORS.cyan)
            elseif e.id == p.targetId then
                drawBadgeText(ex, ey - 36, "OUT OF ARC", C.COLORS.crimson)
            end
        end
    end
end

local function drawProjectiles(stateRef, g)
    if not stateRef or not stateRef.projectiles then return end
    local lg = love.graphics
    for _, proj in ipairs(stateRef.projectiles) do
        local px, py = worldToScreen(proj.x, proj.y, g)
        local tailX, tailY = worldToScreen(
            proj.x - math.cos(proj.heading) * 26,
            proj.y - math.sin(proj.heading) * 26,
            g
        )
        lg.setLineWidth(4.5)
        lg.setColor(1.0, 0.45, 0.12, 0.45)
        lg.line(tailX, tailY, px, py)
        lg.setLineWidth(2.0)
        lg.setColor(1.0, 0.86, 0.35, 0.92)
        lg.line(tailX, tailY, px, py)
        lg.setLineWidth(1)
        lg.setColor(1.0, 0.62, 0.16, 0.65)
        lg.circle("fill", px, py, 6)
        lg.setColor(1.0, 0.96, 0.78, 1.0)
        lg.circle("fill", px, py, 3)
    end
end

local function pickEnemyAtScreen(mx, my, quad, g)
    if not quad or not quad.entities then return nil end
    local best, bestDistSq = nil, C.COMBAT.targetPickRadiusPx ^ 2
    for _, e in ipairs(quad.entities) do
        if e.kind == "enemy" and not e.cloaked then
            local vx, vy = Animations.getEntityVisualPos(e.id, e.x, e.y)
            local ex, ey = isoToScreen(vx - 0.5, vy - 0.5, g)
            local dx, dy = mx - ex, my - ey
            local dSq = dx * dx + dy * dy
            if dSq <= bestDistSq then
                best = e
                bestDistSq = dSq
            end
        end
    end
    return best
end

local function drawViewportCombatHUD(mx, my, g, status)
    local lg = love.graphics
    local cardY = g.y + g.h - 74
    local cardH = 68

    -- Left card: Primary Target Telemetry
    local lx, lw = g.x + 6, 256
    lg.setColor(0.04, 0.07, 0.13, 0.90)
    lg.rectangle("fill", lx, cardY, lw, cardH, 3, 3)
    lg.setColor(status.primary and (status.inBeamArc and C.COLORS.emerald or C.COLORS.amber) or C.COLORS.border)
    lg.rectangle("line", lx, cardY, lw, cardH, 3, 3)

    lg.setFont(UI.fonts.xs)
    lg.setColor(C.COLORS.cyan)
    lg.print("TARGET TELEMETRY", lx + 8, cardY + 5)

    local _, nextRect = UI.drawButton(lx + 164, cardY + 4, 48, 18, "NEXT", mx, my, {
        accent = C.COLORS.cyan,
        font = UI.fonts.xs,
    })
    local _, clrTgtRect = UI.drawButton(lx + 216, cardY + 4, 34, 18, "CLR", mx, my, {
        disabled = (status.primary == nil),
        accent = C.COLORS.amber,
        font = UI.fonts.xs,
    })
    hitBoxes[#hitBoxes + 1] = { rect = nextRect, action = "cycle_target", dir = 1 }
    hitBoxes[#hitBoxes + 1] = { rect = clrTgtRect, action = "clear_target" }

    if status.primary then
        local tgt = status.primary.entity
        local gm = status.primary.geom
        local arcLabel = status.inBeamArc and "IN ARC" or (status.inTorpArc and "TORP ARC" or "OUT ARC")
        local arcCol = status.inBeamArc and C.COLORS.emerald or (status.inTorpArc and C.COLORS.amber or C.COLORS.crimson)
        if status.inTorpArc and status.torpInterlock then
            arcLabel = "INTRLK"
        end
        lg.setColor(C.COLORS.text)
        lg.print(string.format("[%s] %s", tgt.code, tgt.name), lx + 8, cardY + 26)
        lg.setColor(arcCol)
        lg.printf(arcLabel, lx + 164, cardY + 26, 86, "right")
        lg.setColor(C.COLORS.textDim)
        lg.print(string.format("R:%.1fs  BRG:%+04d°  SHD:%d  HL:%d",
            gm.rangeSectors, math.floor(gm.relBearingDeg + 0.5), math.floor(tgt.shield), math.floor(tgt.hull)),
            lx + 8, cardY + 46)
    else
        lg.setColor(C.COLORS.textDim)
        lg.print("NO PRIMARY TARGET DESIGNATED", lx + 8, cardY + 27)
        lg.setColor(C.COLORS.textMuted)
        lg.print("Click hostile ship or press [TAB] to lock.", lx + 8, cardY + 46)
    end

    -- Right card: Weapons Charge & Auto-Fire Controls
    local rx, rw = g.x + g.w - 276, 270
    lg.setColor(0.04, 0.07, 0.13, 0.90)
    lg.rectangle("fill", rx, cardY, rw, cardH, 3, 3)
    lg.setColor(C.COLORS.border)
    lg.rectangle("line", rx, cardY, rw, cardH, 3, 3)

    local b = status.beams
    local bCol = b.ready and C.COLORS.emerald or ((b.statusText == "OVERHEAT" or b.statusText == "OFFLINE") and C.COLORS.crimson or C.COLORS.cyan)
    UI.drawBar(rx + 6, cardY + 6, 102, 17, b.charge, bCol, "BEAM", string.format("%d%%", math.floor(b.charge * 100 + 0.5)))

    local _, bModeRect = UI.drawButton(rx + 111, cardY + 6, 36, 17, b.mode == "spread" and "SPR" or "FOC", mx, my, {
        active = true,
        accent = b.mode == "spread" and C.COLORS.emerald or C.COLORS.cyan,
        font = UI.fonts.xs,
    })
    local _, bAutoRect = UI.drawButton(rx + 150, cardY + 6, 44, 17, b.autoFire and "AUTO" or "HOLD", mx, my, {
        active = b.autoFire,
        accent = b.autoFire and C.COLORS.cyan or C.COLORS.amber,
        font = UI.fonts.xs,
    })
    hitBoxes[#hitBoxes + 1] = { rect = bModeRect, action = "toggle_beam_mode" }
    hitBoxes[#hitBoxes + 1] = { rect = bAutoRect, action = "toggle_beam_auto" }

    lg.setFont(UI.fonts.xs)
    lg.setColor(b.ready and C.COLORS.emerald or ((b.statusText == "CHARGING") and C.COLORS.textDim or C.COLORS.amber))
    lg.printf(b.statusText, rx + 196, cardY + 8, 68, "right")

    local t = status.torpedoes
    local tCol = t.ready and C.COLORS.emerald or ((t.statusText == "EMPTY" or t.statusText == "OFFLINE") and C.COLORS.crimson or C.COLORS.amber)
    UI.drawBar(rx + 6, cardY + 28, 102, 17, t.charge, tCol, "TORP", string.format("%d%%", math.floor(t.charge * 100 + 0.5)))

    lg.setColor(0.06, 0.09, 0.16, 0.95)
    lg.rectangle("fill", rx + 111, cardY + 28, 36, 17, 2, 2)
    lg.setColor(C.COLORS.border)
    lg.rectangle("line", rx + 111, cardY + 28, 36, 17, 2, 2)
    lg.setFont(UI.fonts.xs)
    lg.setColor(t.ammo > 0 and C.COLORS.amber or C.COLORS.crimson)
    lg.printf(string.format("%d/%d", t.ammo, t.maxAmmo), rx + 111, cardY + 30, 36, "center")

    local _, tAutoRect = UI.drawButton(rx + 150, cardY + 28, 44, 17, t.autoFire and "AUTO" or "MAN", mx, my, {
        active = t.autoFire,
        accent = t.autoFire and C.COLORS.amber or C.COLORS.textDim,
        font = UI.fonts.xs,
    })
    hitBoxes[#hitBoxes + 1] = { rect = tAutoRect, action = "toggle_torp_auto" }

    lg.setColor(t.ready and C.COLORS.emerald or ((t.statusText == "CHARGING") and C.COLORS.textDim or C.COLORS.amber))
    lg.printf(t.statusText, rx + 196, cardY + 30, 68, "right")

    lg.setColor(C.COLORS.textMuted)
    lg.print("[F] Beam Mode   [G] Torp Auto   [V] Arcs", rx + 8, cardY + 50)
end

local function drawIsoCell(tx, ty, g, mode, inset)
    inset = inset or 0
    local u0, v0 = tx - 1 + inset, ty - 1 + inset
    local u1, v1 = tx - inset, ty - inset
    local x1, y1 = isoToScreen(u0, v0, g)
    local x2, y2 = isoToScreen(u1, v0, g)
    local x3, y3 = isoToScreen(u1, v1, g)
    local x4, y4 = isoToScreen(u0, v1, g)
    love.graphics.polygon(mode, x1, y1, x2, y2, x3, y3, x4, y4)
end

local function drawTacticalViewport(mx, my)
    local lg = love.graphics
    local r = C.LAYOUT.viewport
    local g = C.VIEWPORT_GRID
    local p = state.player
    local quad = Engine.currentQuad(state)
    local isoRatio = g.isoHalfH / g.isoHalfW
    local spriteSize = g.spriteSize or 52

    local statusTag = state.paused and "  [PAUSED]" or "  [REAL-TIME]"
    local title = string.format("TACTICAL SECTOR VIEW  Q(%d,%d)%s%s", p.qx, p.qy, statusTag, quad.ionStorm and "  [ION STORM]" or "")
    UI.drawPanel(r, title, Engine.getCondition(state) == "RED" and C.COLORS.crimson or C.COLORS.cyan, uiTime)

    -- Shake inside viewport
    local sxOff, syOff = Animations.getShakeOffset()
    lg.push()
    lg.translate(sxOff, syOff)

    -- Starfield inside tactical viewport
    Sprites.drawStarfield(g.x, g.y, g.w, g.h, simTime, p.qx * 31 + p.qy * 97 + state.seed)

    -- Isometric grid corners (0,0)=top, (N,0)=right, (N,N)=bottom, (0,N)=left
    local topX, topY = isoToScreen(0, 0, g)
    local rightX, rightY = isoToScreen(C.GRID_SIZE, 0, g)
    local botX, botY = isoToScreen(C.GRID_SIZE, C.GRID_SIZE, g)
    local leftX, leftY = isoToScreen(0, C.GRID_SIZE, g)

    -- Subtle 3D holo-deck slab & translucent grid floor
    local depth = 8
    lg.setColor(0.03, 0.08, 0.16, 0.58)
    lg.polygon("fill", topX, topY, rightX, rightY, botX, botY, leftX, leftY)
    lg.setColor(0.06, 0.16, 0.28, 0.65)
    lg.polygon("fill", leftX, leftY, botX, botY, botX, botY + depth, leftX, leftY + depth)
    lg.setColor(0.04, 0.11, 0.20, 0.65)
    lg.polygon("fill", botX, botY, rightX, rightY, rightX, rightY + depth, botX, botY + depth)

    -- Isometric grid lines
    lg.setColor(C.COLORS.gridLine[1], C.COLORS.gridLine[2], C.COLORS.gridLine[3], 0.80)
    for i = 0, C.GRID_SIZE do
        local ax, ay = isoToScreen(i, 0, g)
        local bx, by = isoToScreen(i, C.GRID_SIZE, g)
        lg.line(ax, ay, bx, by)
        local cx, cy = isoToScreen(0, i, g)
        local dx, dy = isoToScreen(C.GRID_SIZE, i, g)
        lg.line(cx, cy, dx, dy)
    end

    -- Axis labels 1..8 along top-right (+X) and top-left (+Y) edges
    lg.setFont(UI.fonts.xs)
    lg.setColor(C.COLORS.textDim)
    for i = 1, C.GRID_SIZE do
        local lx, ly = isoToScreen(i - 0.5, 0, g)
        lg.printf(tostring(i), lx + 4, ly - 15, 18, "center")
        local rx, ry = isoToScreen(0, i - 0.5, g)
        lg.printf(tostring(i), rx - 22, ry - 15, 18, "center")
    end

    -- Docking zone halo around friendly outposts
    local outpost = Galaxy.getOutpost(quad)
    if outpost then
        local u0 = math.max(1, outpost.x - 1) - 1
        local v0 = math.max(1, outpost.y - 1) - 1
        local u1 = math.min(C.GRID_SIZE, outpost.x + 1)
        local v1 = math.min(C.GRID_SIZE, outpost.y + 1)
        local p1x, p1y = isoToScreen(u0, v0, g)
        local p2x, p2y = isoToScreen(u1, v0, g)
        local p3x, p3y = isoToScreen(u1, v1, g)
        local p4x, p4y = isoToScreen(u0, v1, g)
        lg.setColor(0.22, 0.88, 0.55, 0.10)
        lg.polygon("fill", p1x, p1y, p2x, p2y, p3x, p3y, p4x, p4y)
        lg.setColor(0.22, 0.88, 0.55, 0.42)
        lg.polygon("line", p1x, p1y, p2x, p2y, p3x, p3y, p4x, p4y)
    end

    -- Determine hovered isometric tile
    hoverTile = nil
    local htx, hty = screenToIsoTile(mx, my, g)
    if htx and hty then
        hoverTile = { x = htx, y = hty }
    end

    -- Subtle hover tile highlight
    if hoverTile and not Overlays.isOpen() and not (dragPlot and dragPlot.active) then
        lg.setColor(C.COLORS.cyan[1], C.COLORS.cyan[2], C.COLORS.cyan[3], 0.10)
        drawIsoCell(hoverTile.x, hoverTile.y, g, "fill", 0.03)
        lg.setColor(C.COLORS.cyan[1], C.COLORS.cyan[2], C.COLORS.cyan[3], 0.35)
        drawIsoCell(hoverTile.x, hoverTile.y, g, "line", 0.03)
    end

    Combat.ensureCombatState(state)
    local status = Combat.getWeaponStatus(state, quad)
    local isDragging = (activeMode == "sublight" and dragPlot and dragPlot.active and not Overlays.isOpen())
    local previewCurve = isDragging
        and Movement.buildCurve(p.x, p.y, p.heading, dragPlot.destX, dragPlot.destY, dragPlot.exitHeading, dragPlot.exitHandleLen)
        or nil
    local dragCoverage = previewCurve and Combat.evaluateCurveArcCoverage(previewCurve, quad, p.targetId) or nil

    -- 180 deg front-facing firing arc cones
    if p.showFiringArcs then
        local bSpec = C.WEAPONS.beams
        local tSpec = C.WEAPONS.torpedoes
        drawFiringCone(p.x, p.y, p.heading, tSpec.arcCenter, tSpec.arcWidth, tSpec.range, g,
            { 1.0, 0.68, 0.22, 0.045 }, { 1.0, 0.72, 0.26, 0.24 })

        local isSpread = (status.beams.mode == "spread")
        local bFill = isSpread and { 0.18, 0.88, 0.56, 0.085 } or { 0.18, 0.80, 1.0, 0.085 }
        local bRim  = isSpread and { 0.26, 0.94, 0.64, 0.42 }  or { 0.28, 0.88, 1.0, 0.42 }
        drawFiringCone(p.x, p.y, p.heading, bSpec.arcCenter, bSpec.arcWidth, bSpec.range, g, bFill, bRim)

        if p.activePath and not isDragging then
            drawFiringCone(p.activePath.p3.x, p.activePath.p3.y, p.activePath.endHeading, bSpec.arcCenter, bSpec.arcWidth, bSpec.range, g,
                { 0.24, 0.82, 1.0, 0.035 }, { 0.28, 0.86, 1.0, 0.16 })
        end
    end

    if isDragging then
        local bSpec = C.WEAPONS.beams
        local tSpec = C.WEAPONS.torpedoes
        drawFiringCone(dragPlot.destX, dragPlot.destY, dragPlot.exitHeading, tSpec.arcCenter, tSpec.arcWidth, tSpec.range, g,
            { 1.0, 0.76, 0.28, 0.035 }, { 1.0, 0.78, 0.30, 0.18 })

        local destHasLock = false
        if dragCoverage and dragCoverage.byEnemyId then
            if p.targetId and dragCoverage.byEnemyId[p.targetId] then
                destHasLock = dragCoverage.byEnemyId[p.targetId].inBeamAtEnd
            else
                for _, info in pairs(dragCoverage.byEnemyId) do
                    if info.inBeamAtEnd then
                        destHasLock = true
                        break
                    end
                end
            end
        end
        local gFill = destHasLock and { 0.25, 0.95, 0.58, 0.10 } or { 1.0, 0.82, 0.24, 0.075 }
        local gRim  = destHasLock and { 0.30, 1.0, 0.65, 0.48 }  or { 1.0, 0.86, 0.32, 0.36 }
        drawFiringCone(dragPlot.destX, dragPlot.destY, dragPlot.exitHeading, bSpec.arcCenter, bSpec.arcWidth, bSpec.range, g, gFill, gRim)
    end

    -- Active committed vector curve on tactical grid
    if p.activePath then
        local activeCov = Combat.evaluateCurveArcCoverage(p.activePath, quad, p.targetId)
        drawVectorPath(p.activePath, p.x, p.y, g, C.COLORS.cyan, false, activeCov)
    end

    -- WYSIWYG targeting / movement previews
    if isDragging then
        if previewCurve then
            drawVectorPath(previewCurve, p.x, p.y, g, C.COLORS.gold, true, dragCoverage)
        else
            local ex, ey = worldToScreen(dragPlot.destX, dragPlot.destY, g)
            lg.setColor(C.COLORS.gold)
            lg.ellipse("line", ex, ey, 11, 11 * isoRatio)
        end
        if dragPlot.dragDistPx >= 8 then
            local ax, ay = worldToScreen(dragPlot.destX, dragPlot.destY, g)
            lg.setColor(C.COLORS.amber[1], C.COLORS.amber[2], C.COLORS.amber[3], 0.45)
            lg.line(ax, ay, dragPlot.dragScreenX, dragPlot.dragScreenY)
        end
    elseif hoverTile and not Overlays.isOpen() then
        if activeMode == "sublight" then
            local ent = Galaxy.getEntityAt(quad, hoverTile.x, hoverTile.y)
            local adj = math.abs(hoverTile.x - p.sx) <= 1 and math.abs(hoverTile.y - p.sy) <= 1
            if ent and ent.kind == "outpost" and adj then
                lg.setColor(C.COLORS.emerald)
                lg.setLineWidth(2)
                drawIsoCell(hoverTile.x, hoverTile.y, g, "line", 0.08)
                lg.setLineWidth(1)
            elseif ent and ent.kind == "planet" and ent.hasFuel and not ent.mined and adj then
                lg.setColor(C.COLORS.cyan)
                lg.setLineWidth(2)
                drawIsoCell(hoverTile.x, hoverTile.y, g, "line", 0.08)
                lg.setLineWidth(1)
            elseif ent and ent.kind == "enemy" and not ent.cloaked then
                lg.setColor(C.COLORS.crimson)
                lg.setLineWidth(1.8)
                drawIsoCell(hoverTile.x, hoverTile.y, g, "line", 0.06)
                lg.setLineWidth(1)
            else
                local hwx, hwy = screenToWorld(mx, my, g)
                local hx, hy = worldToScreen(hwx, hwy, g)
                lg.setColor(C.COLORS.cyan[1], C.COLORS.cyan[2], C.COLORS.cyan[3], 0.55)
                lg.ellipse("line", hx, hy, 8, 8 * isoRatio)
            end
        elseif activeMode == "torpedo" then
            local prev = Engine.previewTorpedo(state, hoverTile.x, hoverTile.y)
            if prev.path then
                for _, cell in ipairs(prev.path) do
                    lg.setColor(prev.friendlyBlocked and { 0.96, 0.28, 0.32, 0.24 } or { 1.0, 0.65, 0.20, 0.18 })
                    drawIsoCell(cell.x, cell.y, g, "fill", 0.10)
                end
                local endC = prev.hitCell or prev.path[#prev.path]
                if endC then
                    local cx1, cy1 = isoTileCenter(p.sx, p.sy, g)
                    local cx2, cy2 = isoTileCenter(endC.x, endC.y, g)
                    lg.setColor(prev.friendlyBlocked and C.COLORS.crimson or C.COLORS.amber)
                    lg.setLineWidth(2)
                    lg.line(cx1, cy1, cx2, cy2)
                    lg.ellipse("line", cx2, cy2, 16, 16 * isoRatio)
                    lg.setLineWidth(1)

                    if prev.novaWarning then
                        -- 3x3 Nova blast zone warning
                        for ny = math.max(1, endC.y - 1), math.min(C.GRID_SIZE, endC.y + 1) do
                            for nx = math.max(1, endC.x - 1), math.min(C.GRID_SIZE, endC.x + 1) do
                                lg.setColor(1.0, 0.38, 0.15, 0.26)
                                drawIsoCell(nx, ny, g, "fill", 0.05)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Beam mode target highlights
    if activeMode == "beams" then
        local enemies = Galaxy.getEnemies(quad, false)
        local spreadAll = (status.beams.mode == "spread" or not p.targetId)
        for _, e in ipairs(enemies) do
            if spreadAll or p.targetId == e.id then
                local ex, ey = isoTileCenter(e.x, e.y, g)
                local pulse = 0.65 + 0.35 * math.sin(timeAccum * 6)
                lg.setColor(C.COLORS.cyan[1], C.COLORS.cyan[2], C.COLORS.cyan[3], pulse)
                lg.setLineWidth(2)
                lg.ellipse("line", ex, ey, g.isoHalfW * 0.78, g.isoHalfH * 0.78)
                lg.setLineWidth(1)
            end
        end
    end

    -- Target reticles & curve-drag projected arc lock badges
    drawTargetReticles(g, p, quad, status, dragCoverage)

    -- Depth-sorted entities & Player Ship (painter's order by isometric depth)
    local gliding = Animations.isGliding("player")
    local pu, pv
    if gliding then
        local gvx, gvy = Animations.getEntityVisualPos("player", p.sx, p.sy)
        pu, pv = gvx - 0.5, gvy - 0.5
    else
        pu = (p.x or 350) / C.SECTOR_WORLD_SCALE
        pv = (p.y or 350) / C.SECTOR_WORLD_SCALE
    end
    local drawList = {}

    drawList[#drawList + 1] = {
        kind = "player",
        u = pu,
        v = pv,
        depth = pu + pv + 1.0,
    }

    for _, e in ipairs(quad.entities) do
        if e.kind ~= "enemy" or not e.cloaked then
            local vx, vy = Animations.getEntityVisualPos(e.id, e.x, e.y)
            drawList[#drawList + 1] = {
                kind = e.kind,
                entity = e,
                u = vx - 0.5,
                v = vy - 0.5,
                depth = vx + vy,
            }
        end
    end

    table.sort(drawList, function(a, b)
        if a.depth ~= b.depth then return a.depth < b.depth end
        if a.v ~= b.v then return a.v < b.v end
        return a.kind ~= "player" and b.kind == "player"
    end)

    for _, item in ipairs(drawList) do
        local cx, cy = isoToScreen(item.u, item.v, g)
        if item.kind == "player" then
            local thrusting = (not state.paused and (p.speed or 0) > (p.maxSpeed or 140) * 0.12) or gliding
            Sprites.drawPlayerShip(cx, cy, spriteSize, visualHeading, p.shieldsUp, p.shields / p.maxShields, simTime, {
                hullPct = p.hull / p.maxHull,
                thrusting = thrusting,
            })
        else
            local e = item.entity
            if e.kind == "star" then
                Sprites.drawStar(cx, cy, spriteSize, e, simTime)
            elseif e.kind == "planet" then
                Sprites.drawPlanet(cx, cy, spriteSize, e, simTime)
            elseif e.kind == "singularity" then
                Sprites.drawSingularity(cx, cy, spriteSize, simTime)
            elseif e.kind == "outpost" then
                Sprites.drawOutpost(cx, cy, spriteSize, simTime, quad.siege ~= nil)
            elseif e.kind == "enemy" then
                Sprites.drawEnemyShip(cx, cy, spriteSize, e, simTime, {
                    thrusting = (not state.paused) and Animations.isGliding(e.id),
                    fallbackHeading = math.atan2(pv - item.v, pu - item.u),
                })
            end
        end
    end

    -- Live torpedo projectiles in isometric continuous coordinates
    drawProjectiles(state, g)

    -- Sensor static overlay if Tactical Sensors are offline
    if p.systems.sensors <= 0 then
        lg.setColor(0.75, 0.85, 1.0, 0.08)
        for i = 1, 55 do
            local sy = g.y + ((i * 37 + math.floor(timeAccum * 60) * 19) % g.h)
            lg.line(g.x, sy, g.x + g.w, sy)
        end
        lg.setFont(UI.fonts.sm)
        lg.setColor(C.COLORS.crimson)
        lg.printf("TACTICAL SENSORS OFFLINE", g.x, g.y + 8, g.w, "center")
    end

    -- Combat & Jump animations projected into isometric space
    Animations.drawViewportEffects(g.x, g.y, g.tile, C.GRID_SIZE, UI.fonts.xs, {
        originX = g.isoOriginX,
        originY = g.isoOriginY,
        halfW = g.isoHalfW,
        halfH = g.isoHalfH,
        areaX = g.x,
        areaY = g.y,
        areaW = g.w,
        areaH = g.h,
    })

    -- Bright border around outer 8x8 isometric diamond
    lg.setColor(C.COLORS.borderBright)
    lg.polygon("line", topX, topY, rightX, rightY, botX, botY, leftX, leftY)

    lg.pop()

    -- Top-left Viewport Helm Telemetry Readout
    local hdgDeg = math.floor((math.deg(p.heading or 0) % 360) + 0.5) % 360
    lg.setFont(UI.fonts.xs)
    lg.setColor(state.paused and C.COLORS.amber or C.COLORS.emerald)
    local modeLabel = state.paused and "PAUSED" or "REAL-TIME"
    if cliAutoPaused then
        modeLabel = modeLabel .. " [CLI]"
    end
    lg.print(modeLabel, g.x + 8, g.y + 6)
    lg.setColor(C.COLORS.text)
    lg.print(string.format("HDG %03d°  |  SPD %d/%d", hdgDeg, math.floor((p.speed or 0) + 0.5), math.floor(p.maxSpeed or 140)), g.x + 8, g.y + 21)
    lg.setColor(C.COLORS.cyan)
    lg.print(string.format("THR %s%s", Movement.getThrottleLabel(p.speedSetting), p.activePath and "  |  CURVE ACTIVE" or ""), g.x + 8, g.y + 36)

    -- Top-right ARCS & CLR PATH buttons (registered BEFORE viewport_click hitBox)
    local _, arcsRect = UI.drawButton(g.x + g.w - 82, g.y + 6, 74, 22,
        p.showFiringArcs and "ARCS:ON" or "ARCS:OFF", mx, my, {
            active = p.showFiringArcs,
            accent = p.showFiringArcs and C.COLORS.cyan or C.COLORS.textDim,
            font = UI.fonts.xs,
        })
    hitBoxes[#hitBoxes + 1] = { rect = arcsRect, action = "toggle_arcs" }

    if p.activePath then
        local _, clrRect = UI.drawButton(g.x + g.w - 166, g.y + 6, 78, 22, "CLR PATH", mx, my, {
            accent = C.COLORS.amber,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = clrRect, action = "clear_path" }
    end

    -- Bottom Tactical Viewport Cards: Target Telemetry & Weapons Charge/Auto-Fire
    drawViewportCombatHUD(mx, my, g, status)

    if hoverTile then
        hitBoxes[#hitBoxes + 1] = {
            rect = { x = g.x, y = g.y, w = g.w, h = g.h },
            action = "viewport_click",
            tx = hoverTile.x,
            ty = hoverTile.y,
        }
    end
end

local function drawActionDeck(mx, my)
    local lg = love.graphics
    local r = C.LAYOUT.actionDeck
    local p = state.player
    UI.drawPanel(r, "TACTICAL ACTION DECK", C.COLORS.amber, timeAccum)

    local canDock = Engine.canDock(state)
    local buttons = {
        { id = "sublight", hk = "1", label = "SUBLIGHT", active = (activeMode == "sublight"), accent = C.COLORS.cyan, action = "mode", mode = "sublight" },
        { id = "ftl",      hk = "2", label = "FTL JUMP", active = (activeMode == "ftl"),      accent = C.COLORS.cyan, action = "mode", mode = "ftl" },
        { id = "beams",    hk = "3", label = "BEAMS",    active = (activeMode == "beams"),    accent = C.COLORS.crimson, action = "mode", mode = "beams" },
        { id = "torpedo",  hk = "4", label = "TORPEDO",  active = (activeMode == "torpedo"),  accent = C.COLORS.amber, action = "mode", mode = "torpedo" },
        { id = "shields",  hk = "5", label = p.shieldsUp and "SHD: UP" or "SHD: DN", active = p.shieldsUp, accent = C.COLORS.cyan, action = "toggle_shields" },
        { id = "probe",    hk = "6", label = "PROBE",    active = (activeMode == "probe"),    accent = C.COLORS.violet, action = "mode", mode = "probe" },
        { id = "scan",     hk = "7", label = "SCAN/MINE",active = false,                      accent = C.COLORS.cyan, action = "active_scan" },
        { id = "dock",     hk = "8", label = "DOCK",     active = false, disabled = not canDock, pulse = canDock and not p.docked, accent = C.COLORS.emerald, action = "dock" },
        { id = "repair",   hk = "9", label = "REPAIR",   active = false,                      accent = C.COLORS.emerald, action = "field_repair" },
    }

    local bx0 = r.x + 11
    local by0 = r.y + 30
    local bw = 118
    local bh = 30
    local gap = 8

    for idx, b in ipairs(buttons) do
        local col = (idx - 1) % 3
        local row = math.floor((idx - 1) / 3)
        local bx = bx0 + col * (bw + gap)
        local by = by0 + row * (bh + 6)
        local _, rect = UI.drawButton(bx, by, bw, bh, b.label, mx, my, {
            hotkey = b.hk,
            active = b.active,
            disabled = b.disabled,
            pulse = b.pulse,
            accent = b.accent,
            time = timeAccum,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = rect, action = b.action, mode = b.mode }
    end

    -- Dynamic context sub-panel below buttons
    local subY = by0 + 110
    local subH = r.y + r.h - subY - 8
    lg.setColor(0.04, 0.06, 0.11, 0.92)
    lg.rectangle("fill", bx0, subY, r.w - 22, subH, 3, 3)
    lg.setColor(C.COLORS.border)
    lg.rectangle("line", bx0, subY, r.w - 22, subH, 3, 3)

    local sx = bx0 + 8
    local sw = r.w - 38

    if activeMode == "beams" then
        Combat.ensureCombatState(state)
        local bMode = p.weapons.beams.mode
        local effTargetId = (bMode == "focused") and p.targetId or nil
        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.cyan)
        lg.print(string.format("BEAM ALLOC: %d E  (%s | %d%% CHG)", beamPower, bMode:upper(), math.floor(p.weapons.beams.charge * 100 + 0.5)), sx, subY + 6)

        local presets = { 200, 400, 600, "LETHAL" }
        for i, pr in ipairs(presets) do
            local px = sx + (i - 1) * 68
            local val = (pr == "LETHAL") and computeLethalBeamPower() or pr
            local _, prRect = UI.drawButton(px, subY + 25, 62, 22, tostring(pr), mx, my, {
                active = (beamPower == val),
                accent = C.COLORS.amber,
                font = UI.fonts.xs,
            })
            hitBoxes[#hitBoxes + 1] = { rect = prRect, action = "set_beam_power", power = val }
        end

        local _, spRect = UI.drawButton(sx + 272, subY + 25, 82, 22, bMode == "spread" and "SPREAD" or "FOCUSED", mx, my, {
            active = true,
            accent = (bMode == "spread") and C.COLORS.emerald or C.COLORS.cyan,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = spRect, action = "toggle_beam_mode" }

        local prev = Engine.previewBeams(state, beamPower, effTargetId)
        local _, fireRect = UI.drawButton(sx, subY + 54, sw, 26,
            prev.ok and string.format("FIRE VOLLEY (%d E, +%d%% HEAT)", prev.energyCost, prev.heatDelta) or (prev.reason or "CANNOT FIRE"),
            mx, my, {
                disabled = not prev.ok,
                accent = C.COLORS.crimson,
                font = UI.fonts.xs,
            })
        hitBoxes[#hitBoxes + 1] = { rect = fireRect, action = "fire_beams" }

    elseif activeMode == "ftl" then
        lg.setFont(UI.fonts.xs)
        local maxSafe = math.max(1, math.floor(6 * (p.systems.ftl / 100)))
        lg.setColor(C.COLORS.cyan)
        lg.print(string.format("FTL FACTOR: %d  (Max Safe: %d)  Click Starmap or:", ftlFactor, maxSafe), sx, subY + 6)

        for f = 1, 9 do
            local fx = sx + (f - 1) * 39
            local _, fRect = UI.drawButton(fx, subY + 24, 34, 22, tostring(f), mx, my, {
                active = (ftlFactor == f),
                accent = (f > maxSafe) and C.COLORS.amber or C.COLORS.cyan,
                font = UI.fonts.xs,
            })
            hitBoxes[#hitBoxes + 1] = { rect = fRect, action = "set_ftl_factor", factor = f }
        end

        local btnLabel = "SELECT QUADRANT ON STARMAP"
        local canJump = false
        if targetQuad then
            local prev = Engine.previewFTL(state, targetQuad.qx, targetQuad.qy, ftlFactor)
            canJump = prev.ok
            if prev.ok then
                btnLabel = string.format("ENGAGE FTL -> Q(%d,%d) [%d E / %.2f CYC]", targetQuad.qx, targetQuad.qy, prev.energyCost, prev.cycleCost)
            else
                btnLabel = prev.reason or "CANNOT JUMP"
            end
        end
        local _, jumpRect = UI.drawButton(sx, subY + 54, sw, 26, btnLabel, mx, my, {
            disabled = not canJump,
            accent = C.COLORS.cyan,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = jumpRect, action = "engage_ftl" }

    elseif activeMode == "torpedo" then
        Combat.ensureCombatState(state)
        local tAuto = p.weapons.torpedoes.autoFire
        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.amber)
        lg.print(string.format("TORPEDOES: %d/%d READY (%d%% CHG)", p.torpedoes, p.maxTorpedoes, math.floor(p.weapons.torpedoes.charge * 100 + 0.5)), sx, subY + 8)
        local _, taRect = UI.drawButton(sx + 242, subY + 4, 112, 20, tAuto and "AUTO: ON" or "AUTO: MAN", mx, my, {
            active = tAuto,
            accent = tAuto and C.COLORS.amber or C.COLORS.textDim,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = taRect, action = "toggle_torp_auto" }
        lg.setColor(C.COLORS.text)
        lg.printf("Click Tactical Map to fire manual ray (pierces 40% shields; detonates stars into 3x3 Supernovas!).", sx, subY + 30, sw, "left")

    elseif activeMode == "probe" then
        lg.setFont(UI.fonts.sm)
        lg.setColor(C.COLORS.violet)
        lg.print(string.format("RECON PROBES: %d READY", p.probes), sx, subY + 8)
        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.text)
        lg.printf("Click any quadrant on the Galactic Starmap to launch a probe, revealing that quadrant and its 4 orthogonal neighbors.", sx, subY + 30, sw, "left")

    else -- sublight
        local hdgDeg = math.floor((math.deg(p.heading or 0) % 360) + 0.5) % 360
        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.cyan)
        lg.print(string.format("HELM: HDG %03d°  |  SPD %d/%d  |  %s",
            hdgDeg, math.floor((p.speed or 0) + 0.5), math.floor(p.maxSpeed or 140), Movement.getThrottleLabel(p.speedSetting)),
            sx, subY + 6)

        for i, stop in ipairs(C.THROTTLE_STOPS) do
            local bx = sx + (i - 1) * 68
            local isAct = math.abs((p.speedSetting or 0) - stop.ratio) < 0.05
            local _, tRect = UI.drawButton(bx, subY + 24, 62, 24, stop.label, mx, my, {
                active = isAct,
                accent = (stop.ratio == 0) and C.COLORS.amber or C.COLORS.cyan,
                font = UI.fonts.xs,
            })
            hitBoxes[#hitBoxes + 1] = { rect = tRect, action = "set_throttle", ratio = stop.ratio }
        end

        local _, pRect = UI.drawButton(sx + 276, subY + 24, 80, 24, state.paused and "RESUME" or "PAUSE", mx, my, {
            active = true,
            accent = state.paused and C.COLORS.emerald or C.COLORS.amber,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = pRect, action = "toggle_tac_pause" }

        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.textDim)
        lg.print("Drag map: curve & exit hdg  |  Click hostile: lock target", sx, subY + 53)
        lg.setColor(C.COLORS.textMuted)
        lg.print("[TAB] Target  [+/-] Thr  [X] Stop  [F] Beam Mode", sx, subY + 69)
    end
end

local function drawEngineering(mx, my)
    local lg = love.graphics
    local r = C.LAYOUT.engineering
    local p = state.player
    UI.drawPanel(r, "ENGINEERING & DISTRESS MONITOR", C.COLORS.emerald, timeAccum)

    local sx = r.x + 12
    local sy = r.y + 30
    local rowH = 22

    for i, sub in ipairs(C.SUBSYSTEMS) do
        local ry = sy + (i - 1) * rowH
        local pct = p.systems[sub.key]
        local isPri = (p.prioritySystem == sub.key)
        local barCol = pct >= 70 and C.COLORS.emerald or (pct >= 30 and C.COLORS.amber or C.COLORS.crimson)

        lg.setFont(UI.fonts.xs)
        lg.setColor(isPri and C.COLORS.cyan or C.COLORS.text)
        lg.print(sub.label, sx, ry + 3)

        UI.drawBar(sx + 106, ry + 2, 200, 16, pct / 100, barCol, nil, string.format("%d%%", pct))

        local _, fixRect = UI.drawButton(sx + 314, ry + 1, 54, 18, isPri and "FIX*" or "FIX", mx, my, {
            active = isPri,
            accent = C.COLORS.cyan,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = fixRect, action = "set_priority", sys = sub.key }
    end

    -- Distress Beacon or Nominal Readout at bottom
    local dy = sy + 9 * rowH + 6
    local dh = r.y + r.h - dy - 10
    local sieges = findActiveSieges()

    if #sieges > 0 then
        local s = sieges[1]
        local pulse = 0.55 + 0.45 * math.sin(timeAccum * 6)
        lg.setColor(0.22, 0.06, 0.08, 0.92)
        lg.rectangle("fill", sx, dy, r.w - 24, dh, 4, 4)
        lg.setColor(1.0, 0.34, 0.28, pulse)
        lg.setLineWidth(1.6)
        lg.rectangle("line", sx, dy, r.w - 24, dh, 4, 4)
        lg.setLineWidth(1)

        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.crimson)
        lg.print(string.format("DISTRESS: %s Q(%d,%d)", s.name:upper(), s.qx, s.qy), sx + 10, dy + 8)
        lg.setColor(C.COLORS.amber)
        lg.print(string.format("Falls in %.1f cyc! Clear sector (+400).", math.max(0, s.cyclesLeft)), sx + 10, dy + 28)

        local _, intRect = UI.drawButton(sx + 236, dy + 16, 124, 30, "PLOT INTERCEPT", mx, my, {
            accent = C.COLORS.amber,
            pulse = true,
            time = timeAccum,
            font = UI.fonts.xs,
        })
        hitBoxes[#hitBoxes + 1] = { rect = intRect, action = "plot_intercept", qx = s.qx, qy = s.qy }
    else
        lg.setColor(0.05, 0.09, 0.16, 0.88)
        lg.rectangle("fill", sx, dy, r.w - 24, dh, 4, 4)
        lg.setColor(C.COLORS.border)
        lg.rectangle("line", sx, dy, r.w - 24, dh, 4, 4)
        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.emerald)
        lg.print("ALL ORBITAL OUTPOSTS SECURE", sx + 10, dy + 10)
        lg.setColor(C.COLORS.textDim)
        local priTxt = p.prioritySystem and ("Priority repair: " .. p.prioritySystem:upper()) or "Click FIX on a subsystem for 3x repair speed."
        lg.print(priTxt, sx + 10, dy + 30)
    end
end

local function drawConsoleAndHints(mx, my)
    local lg = love.graphics
    local logRect = C.LAYOUT.consoleLog
    local hintRect = C.LAYOUT.consoleHint

    -- Left: Bridge Log + Classic COMMAND> prompt
    UI.drawPanel(logRect, nil, C.COLORS.cyan, timeAccum)
    local total = #state.log
    local maxVisible = 3
    local startIdx = math.max(1, total - maxVisible + 1 - logScrollOffset)
    local endIdx = math.min(total, startIdx + maxVisible - 1)

    lg.setFont(UI.fonts.xs)
    local ly = logRect.y + 6
    for i = startIdx, endIdx do
        local entry = state.log[i]
        local col = C.COLORS.text
        if entry.level == "cyan" then col = C.COLORS.cyan
        elseif entry.level == "emerald" then col = C.COLORS.emerald
        elseif entry.level == "amber" then col = C.COLORS.amber
        elseif entry.level == "crimson" then col = C.COLORS.crimson
        elseif entry.level == "violet" then col = C.COLORS.violet end

        lg.setColor(C.COLORS.textMuted)
        lg.print(string.format("[%04.1f]", entry.cycle), logRect.x + 10, ly)
        lg.setColor(col)
        local maxTextW = logRect.w - 68
        local txt = entry.text
        if UI.fonts.xs:getWidth(txt) > maxTextW then
            while #txt > 4 and UI.fonts.xs:getWidth(txt .. "...") > maxTextW do
                txt = txt:sub(1, -2)
            end
            txt = txt .. "..."
        end
        lg.print(txt, logRect.x + 56, ly)
        ly = ly + 17
    end

    -- CLI bar
    local cliBox = { x = logRect.x + 8, y = logRect.y + 58, w = logRect.w - 16, h = 24 }
    lg.setColor(0.03, 0.05, 0.09, 1)
    lg.rectangle("fill", cliBox.x, cliBox.y, cliBox.w, cliBox.h, 2, 2)
    lg.setColor(cliFocused and C.COLORS.cyan or C.COLORS.border)
    lg.rectangle("line", cliBox.x, cliBox.y, cliBox.w, cliBox.h, 2, 2)

    lg.setFont(UI.fonts.sm)
    lg.setColor(cliFocused and C.COLORS.cyan or C.COLORS.amber)
    lg.print("COMMAND>", cliBox.x + 8, cliBox.y + 4)

    local cursor = (cliFocused and (math.floor(timeAccum * 2) % 2 == 0)) and "_" or ""
    if cliText == "" and not cliFocused then
        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.textMuted)
        lg.print("Click here or press '/' to enter commands (e.g. M 4 6, W 5 3 6, P 400, T 7 2, S UP, HELP)", cliBox.x + 90, cliBox.y + 5)
    else
        lg.setFont(UI.fonts.sm)
        lg.setColor(C.COLORS.text)
        lg.print(cliText .. cursor, cliBox.x + 90, cliBox.y + 4)
    end
    hitBoxes[#hitBoxes + 1] = { rect = cliBox, action = "focus_cli" }

    -- Right: Contextual Hint / Live Cost Box
    UI.drawPanel(hintRect, nil, C.COLORS.amber, timeAccum)
    lg.setFont(UI.fonts.xs)
    local hx = hintRect.x + 10
    local hy = hintRect.y + 8
    local hw = hintRect.w - 20

    if dragPlot and dragPlot.active then
        local p = state.player
        local quad = Engine.currentQuad(state)
        local dsx, dsy = Movement.worldToSector(dragPlot.destX, dragPlot.destY)
        local exDeg = math.floor((math.deg(dragPlot.exitHeading or 0) % 360) + 0.5) % 360
        lg.setColor(C.COLORS.gold)
        lg.print("PLOTTING VECTOR CURVE", hx, hy)
        lg.setColor(C.COLORS.text)
        lg.print(string.format("Dest: S(%d,%d)  |  Exit Heading: %03d°", dsx, dsy, exDeg), hx, hy + 18)

        local previewCurve = Movement.buildCurve(p.x, p.y, p.heading, dragPlot.destX, dragPlot.destY, dragPlot.exitHeading, dragPlot.exitHandleLen)
        local cov = previewCurve and Combat.evaluateCurveArcCoverage(previewCurve, quad, p.targetId) or nil
        if p.targetId and cov and cov.byEnemyId[p.targetId] then
            local info = cov.byEnemyId[p.targetId]
            if info.inBeamAtEnd then
                lg.setColor(C.COLORS.emerald)
                lg.print(string.format("ARC: %s IN BEAM CONE AT END (R:%.1fs)", info.entity.code, info.destRange / C.SECTOR_WORLD_SCALE), hx, hy + 36)
            elseif info.inTorpAtEnd then
                lg.setColor(C.COLORS.amber)
                lg.print(string.format("ARC: %s IN TORP CONE ONLY AT END", info.entity.code), hx, hy + 36)
            elseif info.inBeamAlongCurve then
                lg.setColor(C.COLORS.cyan)
                lg.print(string.format("ARC: %s IN BEAM CONE MID-MANEUVER", info.entity.code), hx, hy + 36)
            else
                lg.setColor(C.COLORS.crimson)
                lg.print(string.format("ARC: %s OUTSIDE 180° BOW CONE", info.entity.code), hx, hy + 36)
            end
        else
            lg.setColor(C.COLORS.textDim)
            lg.print("Drag to set exit heading. Release commits; Right-click cancels.", hx, hy + 36)
        end
    elseif hoverTile and not Overlays.isOpen() then
        local quad = Engine.currentQuad(state)
        local ent = Galaxy.getEntityAt(quad, hoverTile.x, hoverTile.y)
        if hoverTile.x == state.player.sx and hoverTile.y == state.player.sy then
            lg.setColor(C.COLORS.cyan)
            lg.print(string.format("S(%d,%d) — %s", hoverTile.x, hoverTile.y, state.shipName), hx, hy)
            lg.setColor(C.COLORS.textDim)
            lg.print(string.format("Hull %d/%d | Energy %d | Shd %s", state.player.hull, state.player.maxHull, state.player.energy, state.player.shieldsUp and "UP" or "DN"), hx, hy + 18)
        elseif activeMode == "sublight" then
            local adj = math.abs(hoverTile.x - state.player.sx) <= 1 and math.abs(hoverTile.y - state.player.sy) <= 1
            if ent and ent.kind == "outpost" and adj then
                lg.setColor(C.COLORS.emerald)
                lg.print(string.format("DOCK -> %s S(%d,%d)", ent.name, hoverTile.x, hoverTile.y), hx, hy)
                lg.setColor(C.COLORS.text)
                lg.print("Click to dock for full repair & resupply.", hx, hy + 18)
            elseif ent and ent.kind == "planet" and ent.hasFuel and not ent.mined and adj then
                lg.setColor(C.COLORS.cyan)
                lg.print(string.format("MINE -> %s S(%d,%d)", ent.name, hoverTile.x, hoverTile.y), hx, hy)
                lg.setColor(C.COLORS.text)
                lg.print(string.format("Click to scan & harvest +%d Fuel Energy.", ent.fuelAmount), hx, hy + 18)
            elseif ent and ent.kind == "enemy" and not ent.cloaked then
                lg.setColor(C.COLORS.crimson)
                lg.print(string.format("TARGET -> %s [%s] S(%d,%d)", ent.name, ent.code, hoverTile.x, hoverTile.y), hx, hy)
                lg.setColor(C.COLORS.text)
                lg.print("Click to designate primary target (drag plots curve).", hx, hy + 18)
                lg.setColor(C.COLORS.textDim)
                lg.print("[TAB] Cycle Targets  |  [F] Beam Mode  |  [V] Arcs", hx, hy + 36)
            else
                lg.setColor(C.COLORS.cyan)
                lg.print(string.format("COURSE PLOT -> S(%d,%d)", hoverTile.x, hoverTile.y), hx, hy)
                lg.setColor(C.COLORS.text)
                lg.print("Click & drag to shape vector curve & exit heading.", hx, hy + 18)
                lg.setColor(C.COLORS.textDim)
                lg.print("[SPC] Pause/Resume  |  [+/-] Throttle  |  [C] Clear Path", hx, hy + 36)
            end
        elseif activeMode == "torpedo" then
            local prev = Engine.previewTorpedo(state, hoverTile.x, hoverTile.y)
            lg.setColor(prev.ok and C.COLORS.amber or C.COLORS.crimson)
            lg.print(string.format("TORPEDO VECTOR -> S(%d,%d)", hoverTile.x, hoverTile.y), hx, hy)
            if not prev.ok then
                lg.setColor(C.COLORS.crimson)
                lg.printf(prev.reason or "", hx, hy + 18, hw, "left")
            elseif prev.novaWarning then
                lg.setColor(C.COLORS.crimson)
                lg.print("WARNING: Star impact triggers SUPERNOVA (3x3)!", hx, hy + 18)
            elseif prev.habitableWarning then
                lg.setColor(C.COLORS.crimson)
                lg.print("WARNING: Inhabited world in firing line (-250)!", hx, hy + 18)
            elseif prev.hitEntity and prev.hitEntity.kind == "enemy" then
                lg.setColor(C.COLORS.emerald)
                lg.print(string.format("LOCK: %s (~340-420 piercing dmg)", prev.hitEntity.name), hx, hy + 18)
            else
                lg.setColor(C.COLORS.textDim)
                lg.print("25 Energy, 1 Torpedo, +0.25 Cycles", hx, hy + 18)
            end
        elseif ent and not ent.cloaked then
            lg.setColor(C.COLORS.cyan)
            lg.print(string.format("S(%d,%d): %s", hoverTile.x, hoverTile.y, ent.name or ent.kind:upper()), hx, hy)
            lg.setColor(C.COLORS.textDim)
            lg.print("Click in Beams/Torp mode or switch mode [1-9].", hx, hy + 18)
        else
            lg.setColor(C.COLORS.textDim)
            lg.print(string.format("Empty Space S(%d,%d)", hoverTile.x, hoverTile.y), hx, hy)
        end
    else
        lg.setColor(C.COLORS.cyan)
        lg.print("BRIDGE TELEMETRY READY", hx, hy)
        lg.setColor(C.COLORS.textDim)
        lg.printf("Mode: " .. activeMode:upper() .. "  |  Hover sector or starmap for exact cost & hazard preview.", hx, hy + 18, hw, "left")
    end
end

local function drawHoverTooltip(mx, my)
    if Overlays.isOpen() or not hoverTile or (dragPlot and dragPlot.active) then return end
    local quad = Engine.currentQuad(state)
    local p = state.player
    local ent = Galaxy.getEntityAt(quad, hoverTile.x, hoverTile.y)
    local sensorsOk = p.systems.sensors > 0

    if hoverTile.x == p.sx and hoverTile.y == p.sy then
        UI.drawTooltip(mx, my, {
            { text = state.shipName .. string.format("  S(%d,%d)", p.sx, p.sy), color = C.COLORS.cyan },
            { text = string.format("Hull: %d/%d  |  Energy: %d", p.hull, p.maxHull, p.energy) },
            { text = string.format("Shields: %s (%d/%d)", p.shieldsUp and "UP" or "DOWN", p.shields, p.maxShields) },
        }, C.COLORS.cyan)
        return
    end

    if not ent or ent.cloaked then return end

    if ent.kind == "enemy" then
        local lines = {
            { text = string.format("%s [%s]  S(%d,%d)", ent.name, ent.code, ent.x, ent.y), color = C.COLORS.crimson },
        }
        if sensorsOk then
            local ex, ey = Combat.getEntityWorldPos(ent)
            local bGeom = Combat.evaluateTargetGeometry(p.x, p.y, p.heading, ex, ey, C.WEAPONS.beams.arcCenter, C.WEAPONS.beams.arcWidth, C.WEAPONS.beams.range)
            local tGeom = Combat.evaluateTargetGeometry(p.x, p.y, p.heading, ex, ey, C.WEAPONS.torpedoes.arcCenter, C.WEAPONS.torpedoes.arcWidth, C.WEAPONS.torpedoes.range)
            local arcStr = bGeom.inFiringArc and "IN BEAM+TORP ARC" or (tGeom.inFiringArc and "TORP ARC ONLY" or "OUT OF ARC")
            local arcCol = bGeom.inFiringArc and C.COLORS.emerald or (tGeom.inFiringArc and C.COLORS.amber or C.COLORS.textDim)
            lines[#lines + 1] = { text = string.format("Shields: %d/%d  |  Hull: %d/%d", ent.shield, ent.maxShield, ent.hull, ent.maxHull) }
            lines[#lines + 1] = { text = string.format("Range: %.1fs  |  BRG: %+04d°", bGeom.rangeSectors, math.floor(bGeom.relBearingDeg + 0.5)) }
            lines[#lines + 1] = { text = arcStr .. "  |  Click to Designate Target", color = arcCol }
        else
            lines[#lines + 1] = { text = "Telemetry jammed (Sensors offline)", color = C.COLORS.amber }
        end
        UI.drawTooltip(mx, my, lines, C.COLORS.crimson)
    elseif ent.kind == "outpost" then
        local adj = (math.abs(ent.x - p.sx) <= 1 and math.abs(ent.y - p.sy) <= 1)
        UI.drawTooltip(mx, my, {
            { text = ent.name .. string.format("  S(%d,%d)", ent.x, ent.y), color = C.COLORS.emerald },
            { text = string.format("Integrity: %d/%d", ent.hp, ent.maxHp) },
            { text = adj and "Click to DOCK & restore 100%!" or "Fly adjacent (green zone) to Dock.", color = C.COLORS.cyan },
        }, C.COLORS.emerald)
    elseif ent.kind == "star" then
        UI.drawTooltip(mx, my, {
            { text = string.format("Main Sequence Star  S(%d,%d)", ent.x, ent.y), color = C.COLORS.gold },
            { text = "Impassable hazard. Torpedo hit triggers 3x3 Supernova!" },
        }, C.COLORS.gold)
    elseif ent.kind == "planet" then
        local lines = {
            { text = string.format("Planet %s  S(%d,%d)", ent.name, ent.x, ent.y), color = C.COLORS.cyan },
        }
        if ent.hasFuel and not ent.mined then
            lines[#lines + 1] = { text = string.format("Unmined Mineral Fuel: +%d E (Fly adjacent & Scan)", ent.fuelAmount), color = C.COLORS.emerald }
        elseif ent.habitable then
            lines[#lines + 1] = { text = "Inhabited Colony World — Do NOT torpedo!", color = C.COLORS.amber }
        else
            lines[#lines + 1] = { text = ent.mined and "Mineral reserves depleted." or "Barren rocky world." }
        end
        UI.drawTooltip(mx, my, lines, C.COLORS.cyan)
    elseif ent.kind == "singularity" then
        UI.drawTooltip(mx, my, {
            { text = string.format("Gravitational Singularity  S(%d,%d)", ent.x, ent.y), color = C.COLORS.violet },
            { text = "Absorbs torpedoes. Flying into it flings ship to random quadrant!" },
        }, C.COLORS.violet)
    end
end

function Game.draw(mx, my, prefs)
    if not state then return end
    hitBoxes = {}

    drawTopBar(mx, my, prefs)
    drawStarmap(mx, my)
    drawVitals(mx, my)
    drawTacticalViewport(mx, my)
    drawActionDeck(mx, my)
    drawEngineering(mx, my)
    drawConsoleAndHints(mx, my)
    drawHoverTooltip(mx, my)

    if Overlays.isOpen() then
        Overlays.draw(mx, my, state, prefs, timeAccum)
    end
end

-- ======================== INPUT HANDLERS ========================

local function handleViewportClick(tx, ty)
    local p = state.player
    local quad = Engine.currentQuad(state)
    local ent = Galaxy.getEntityAt(quad, tx, ty)

    if activeMode == "beams" then
        Combat.ensureCombatState(state)
        if ent and ent.kind == "enemy" and not ent.cloaked then
            applyActionResult(Engine.setTarget(state, ent.id))
            applyActionResult(Engine.fireBeams(state, beamPower, ent.id))
        else
            local effTgt = (p.weapons.beams.mode == "focused") and p.targetId or nil
            applyActionResult(Engine.fireBeams(state, beamPower, effTgt))
        end
    elseif activeMode == "torpedo" then
        applyActionResult(Engine.fireTorpedo(state, tx, ty))
    else
        -- Smart contextual click in sublight/ftl/probe mode:
        -- Clicking adjacent Outpost docks; clicking adjacent mineable planet scans/mines; otherwise sublight move
        if ent and ent.kind == "outpost" and math.abs(ent.x - p.sx) <= 1 and math.abs(ent.y - p.sy) <= 1 then
            applyActionResult(Engine.dock(state))
        elseif ent and ent.kind == "planet" and ent.hasFuel and not ent.mined and math.abs(ent.x - p.sx) <= 1 and math.abs(ent.y - p.sy) <= 1 then
            applyActionResult(Engine.activeScan(state))
        else
            applyActionResult(Engine.moveSublight(state, tx, ty))
        end
    end
end

local function handleStarmapClick(qx, qy)
    if activeMode == "probe" then
        applyActionResult(Engine.launchProbe(state, qx, qy))
        activeMode = "sublight"
    elseif activeMode == "ftl" then
        targetQuad = { qx = qx, qy = qy }
        applyActionResult(Engine.jumpFTL(state, qx, qy, ftlFactor))
    else
        activeMode = "ftl"
        targetQuad = { qx = qx, qy = qy }
        Sound.play("click")
    end
end

local function updateDragPlot(mx, my)
    if not (dragPlot and dragPlot.active and state and state.player) then return end
    local g = C.VIEWPORT_GRID
    dragPlot.dragScreenX = mx
    dragPlot.dragScreenY = my
    local sdx = mx - dragPlot.anchorScreenX
    local sdy = my - dragPlot.anchorScreenY
    dragPlot.dragDistPx = math.sqrt(sdx * sdx + sdy * sdy)

    if dragPlot.dragDistPx >= 8 then
        local dwx, dwy = screenToWorld(mx, my, g)
        local vx = dwx - dragPlot.destX
        local vy = dwy - dragPlot.destY
        local vlen = math.sqrt(vx * vx + vy * vy)
        if vlen > 1e-3 then
            dragPlot.exitHeading = math.atan2(vy, vx)
            dragPlot.exitHandleLen = vlen
        end
    else
        local p = state.player
        dragPlot.exitHeading = math.atan2(dragPlot.destY - p.y, dragPlot.destX - p.x)
        dragPlot.exitHandleLen = nil
    end
end

local function stepThrottleStop(deltaIdx)
    if not state or not state.player then return end
    local cur = state.player.speedSetting or 0
    local bestIdx = 1
    local bestDist = 999
    for i, stop in ipairs(C.THROTTLE_STOPS) do
        local d = math.abs(cur - stop.ratio)
        if d < bestDist then
            bestDist = d
            bestIdx = i
        end
    end
    local nextIdx = Movement.clamp(bestIdx + deltaIdx, 1, #C.THROTTLE_STOPS)
    applyActionResult(Engine.setSpeedSetting(state, C.THROTTLE_STOPS[nextIdx].ratio))
end

function Game.mousepressed(mx, my, button, prefs)
    if Overlays.isOpen() then
        dragPlot = nil
        local res = Overlays.mousepressed(mx, my, button)
        if not res then return nil end
        if res.action == "click" then
            Sound.play("click")
        elseif res.action == "save" then
            applyActionResult({ ok = true, events = {}, uiAction = "save" })
        elseif res.action == "load" then
            applyActionResult({ ok = true, events = {}, uiAction = "load" })
        elseif res.action == "toggle_mute" or res.action == "toggle_crt" or res.action == "toggle_fast" or res.action == "restart" or res.action == "to_title" or res.action == "quit" then
            return res
        end
        return nil
    end

    if button == 2 then
        if dragPlot and dragPlot.active then
            dragPlot = nil
            Sound.play("click")
            return nil
        end
        if activeMode == "sublight" and state and state.player and state.player.activePath then
            applyActionResult(Engine.clearPlayerPath(state))
            Sound.play("click")
            return nil
        end
        -- Right-click cancels weapon/probe targeting back to sublight
        activeMode = "sublight"
        setCliFocused(false, false)
        Sound.play("click")
        return nil
    end

    if button ~= 1 then return nil end

    local clickedFocusCli = false
    for _, hb in ipairs(hitBoxes) do
        if UI.pointInRect(mx, my, hb.rect) then
            local a = hb.action
            if a == "focus_cli" then
                clickedFocusCli = true
                setCliFocused(true)
                Sound.play("click")
                return nil
            end
        end
    end
    if not clickedFocusCli then
        setCliFocused(false, false)
    end

    for _, hb in ipairs(hitBoxes) do
        if UI.pointInRect(mx, my, hb.rect) then
            local a = hb.action
            if a == "toggle_tac_pause" then
                cliAutoPaused = false
                Engine.togglePause(state)
                Sound.play("click")
            elseif a == "set_throttle" then
                applyActionResult(Engine.setSpeedSetting(state, hb.ratio))
            elseif a == "clear_path" then
                dragPlot = nil
                applyActionResult(Engine.clearPlayerPath(state))
                Sound.play("click")
            elseif a == "viewport_click" then
                if activeMode == "sublight" and state and state.status == "active" then
                    local wx, wy = screenToWorld(mx, my, C.VIEWPORT_GRID)
                    local p = state.player
                    dragPlot = {
                        active = true,
                        anchorScreenX = mx,
                        anchorScreenY = my,
                        destX = wx,
                        destY = wy,
                        dragScreenX = mx,
                        dragScreenY = my,
                        dragDistPx = 0,
                        exitHeading = math.atan2(wy - p.y, wx - p.x),
                        exitHandleLen = nil,
                        tx = hb.tx,
                        ty = hb.ty,
                    }
                else
                    handleViewportClick(hb.tx, hb.ty)
                end
            elseif a == "starmap_cell" then
                handleStarmapClick(hb.qx, hb.qy)
            elseif a == "mode" then
                activeMode = hb.mode
                dragPlot = nil
                Sound.play("click")
            elseif a == "toggle_shields" then
                applyActionResult(Engine.toggleShields(state, nil))
            elseif a == "shield_delta" then
                applyActionResult(Engine.transferShieldEnergy(state, hb.delta))
            elseif a == "use_aux" then
                applyActionResult(Engine.useAuxReserve(state))
            elseif a == "active_scan" then
                applyActionResult(Engine.activeScan(state))
            elseif a == "dock" then
                applyActionResult(Engine.dock(state))
            elseif a == "field_repair" then
                applyActionResult(Engine.fieldRepair(state))
            elseif a == "toggle_arcs" then
                applyActionResult(Engine.setShowFiringArcs(state, nil))
            elseif a == "cycle_target" then
                applyActionResult(Engine.cycleTarget(state, hb.dir or 1))
            elseif a == "clear_target" then
                applyActionResult(Engine.clearTarget(state))
            elseif a == "toggle_beam_mode" then
                applyActionResult(Engine.setBeamMode(state, nil))
            elseif a == "toggle_beam_auto" then
                applyActionResult(Engine.setWeaponAutoFire(state, "beams", nil))
            elseif a == "toggle_torp_auto" then
                applyActionResult(Engine.setWeaponAutoFire(state, "torpedoes", nil))
            elseif a == "set_beam_power" then
                beamPower = hb.power
                Sound.play("click")
            elseif a == "fire_beams" then
                Combat.ensureCombatState(state)
                local effTgt = (state.player.weapons.beams.mode == "focused") and state.player.targetId or nil
                applyActionResult(Engine.fireBeams(state, beamPower, effTgt))
            elseif a == "set_ftl_factor" then
                ftlFactor = hb.factor
                Sound.play("click")
            elseif a == "engage_ftl" then
                if targetQuad then
                    applyActionResult(Engine.jumpFTL(state, targetQuad.qx, targetQuad.qy, ftlFactor))
                end
            elseif a == "set_priority" then
                applyActionResult(Engine.setRepairPriority(state, hb.sys))
            elseif a == "plot_intercept" then
                activeMode = "ftl"
                dragPlot = nil
                targetQuad = { qx = hb.qx, qy = hb.qy }
                Sound.play("click")
            elseif a == "save" then
                applyActionResult({ ok = true, events = {}, uiAction = "save" })
            elseif a == "help" then
                dragPlot = nil
                Overlays.open("help")
                Sound.play("click")
            elseif a == "pause" then
                dragPlot = nil
                Overlays.open("pause")
                Sound.play("click")
            elseif a == "toggle_mute" or a == "toggle_crt" or a == "toggle_fast" then
                return { action = a }
            end
            return nil
        end
    end
    return nil
end

function Game.mousemoved(mx, my)
    if Overlays.isOpen() then
        dragPlot = nil
        return
    end
    updateDragPlot(mx, my)
end

function Game.mousereleased(mx, my, button)
    if button ~= 1 or not (dragPlot and dragPlot.active) then
        return
    end
    updateDragPlot(mx, my)
    local dp = dragPlot
    dragPlot = nil
    if not state or state.status ~= "active" or Overlays.isOpen() then
        return
    end

    local p = state.player
    if dp.dragDistPx < 8 and dp.tx and dp.ty then
        local quad = Engine.currentQuad(state)
        local ent = Galaxy.getEntityAt(quad, dp.tx, dp.ty)
        local adj = math.abs(dp.tx - p.sx) <= 1 and math.abs(dp.ty - p.sy) <= 1
        if ent and ent.kind == "outpost" and adj then
            applyActionResult(Engine.dock(state))
            return
        elseif ent and ent.kind == "planet" and ent.hasFuel and not ent.mined and adj then
            applyActionResult(Engine.activeScan(state))
            return
        end

        local pickedEnemy = pickEnemyAtScreen(dp.dragScreenX or mx, dp.dragScreenY or my, quad, C.VIEWPORT_GRID)
            or (ent and ent.kind == "enemy" and not ent.cloaked and ent or nil)
        if pickedEnemy then
            applyActionResult(Engine.setTarget(state, pickedEnemy.id))
            return
        end
    end

    local chord = math.sqrt((dp.destX - p.x) ^ 2 + (dp.destY - p.y) ^ 2)
    if chord < 18 and dp.dragDistPx < 8 then
        return
    end
    applyActionResult(Engine.plotPlayerCourse(state, dp.destX, dp.destY, dp.exitHeading, dp.exitHandleLen))
end

function Game.wheelmoved(wx, wy)
    if not state then return end
    if wy > 0 then
        logScrollOffset = math.min(math.max(0, #state.log - 3), logScrollOffset + 1)
    elseif wy < 0 then
        logScrollOffset = math.max(0, logScrollOffset - 1)
    end
end

function Game.keypressed(key)
    if Overlays.isOpen() then
        dragPlot = nil
        if key == "escape" or (key == "f1" and Overlays.getActive() == "help") then
            if state.status == "active" then
                Overlays.close()
                Sound.play("click")
            end
        end
        return nil
    end

    if cliFocused then
        if key == "escape" then
            setCliFocused(false, false)
        elseif key == "backspace" then
            cliText = cliText:sub(1, math.max(0, #cliText - 1))
        elseif key == "return" or key == "kpenter" then
            local cmd = cliText
            local keepPaused = false
            if cmd ~= "" then
                cliHistory[#cliHistory + 1] = cmd
                cliHistIdx = #cliHistory + 1
                cliText = ""
                local res = Commands.execute(state, cmd)
                keepPaused = (res and res.uiAction == "keep_paused") or false
                applyActionResult(res)
            end
            setCliFocused(false, keepPaused)
        elseif key == "tab" then
            local comp = Commands.autocomplete(cliText)
            if comp then
                cliText = comp
            end
        elseif key == "up" then
            if #cliHistory > 0 then
                cliHistIdx = math.max(1, cliHistIdx - 1)
                cliText = cliHistory[cliHistIdx] or ""
            end
        elseif key == "down" then
            if #cliHistory > 0 then
                cliHistIdx = math.min(#cliHistory + 1, cliHistIdx + 1)
                cliText = cliHistory[cliHistIdx] or ""
            end
        end
        return nil
    end

    -- Global & mode hotkeys when CLI is unfocused
    if key == "space" then
        cliAutoPaused = false
        Engine.togglePause(state)
        Sound.play("click")
    elseif key == "=" or key == "kp+" or key == "]" then
        stepThrottleStop(1)
    elseif key == "-" or key == "kp-" or key == "[" then
        stepThrottleStop(-1)
    elseif key == "x" then
        applyActionResult(Engine.setSpeedSetting(state, 0))
    elseif key == "c" then
        dragPlot = nil
        applyActionResult(Engine.clearPlayerPath(state))
        Sound.play("click")
    elseif key == "tab" then
        local shift = love and love.keyboard and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift"))
        applyActionResult(Engine.cycleTarget(state, shift and -1 or 1))
    elseif key == "q" then
        applyActionResult(Engine.clearTarget(state))
    elseif key == "f" then
        applyActionResult(Engine.setBeamMode(state, nil))
    elseif key == "g" then
        applyActionResult(Engine.setWeaponAutoFire(state, "torpedoes", nil))
    elseif key == "v" then
        applyActionResult(Engine.setShowFiringArcs(state, nil))
    elseif key == "/" or key == "kp/" then
        cliText = ""
        setCliFocused(true)
        Sound.play("click")
    elseif key == "f1" then
        dragPlot = nil
        Overlays.open("help")
        Sound.play("click")
    elseif key == "f5" then
        applyActionResult({ ok = true, events = {}, uiAction = "save" })
    elseif key == "f9" then
        applyActionResult({ ok = true, events = {}, uiAction = "load" })
    elseif key == "escape" then
        if dragPlot and dragPlot.active then
            dragPlot = nil
            Sound.play("click")
        elseif activeMode ~= "sublight" then
            activeMode = "sublight"
            Sound.play("click")
        else
            Overlays.open("pause")
            Sound.play("click")
        end
    elseif key == "1" or key == "i" then
        activeMode = "sublight"
        Sound.play("click")
    elseif key == "2" or key == "w" then
        activeMode = "ftl"
        dragPlot = nil
        Sound.play("click")
    elseif key == "3" or key == "p" or key == "b" then
        activeMode = "beams"
        dragPlot = nil
        Sound.play("click")
    elseif key == "4" or key == "t" then
        activeMode = "torpedo"
        dragPlot = nil
        Sound.play("click")
    elseif key == "5" or key == "s" then
        applyActionResult(Engine.toggleShields(state, nil))
    elseif key == "6" or key == "k" then
        activeMode = "probe"
        dragPlot = nil
        Sound.play("click")
    elseif key == "7" or key == "l" then
        applyActionResult(Engine.activeScan(state))
    elseif key == "8" or key == "d" then
        applyActionResult(Engine.dock(state))
    elseif key == "9" or key == "r" then
        applyActionResult(Engine.fieldRepair(state))
    end
    return nil
end

function Game.textinput(t)
    if Overlays.isOpen() or not cliFocused then return end
    if t == "/" and cliText == "" then
        return
    end
    if #cliText < 68 then
        cliText = cliText .. t
    end
end

return Game
