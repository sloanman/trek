-- Modal overlays: Tactical Codex (Help), Pause Menu, Mission Debrief, and Service Record

local C = require("src.constants")
local UI = require("src.ui")
local Sprites = require("src.sprites")
local Engine = require("src.engine")
local Storage = require("src.storage")

local Overlays = {}

local activeOverlay = nil -- nil | "help" | "pause" | "debrief" | "records"
local helpTab = "controls" -- "controls" | "enemies" | "hazards"
local debriefScoreInfo = nil
local hitBoxes = {}

function Overlays.getActive()
    return activeOverlay
end

function Overlays.isOpen()
    return activeOverlay ~= nil
end

function Overlays.open(kind, state)
    activeOverlay = kind
    if kind == "debrief" and state then
        debriefScoreInfo = Engine.calculateFinalScore(state)
    end
end

function Overlays.close()
    activeOverlay = nil
end

function Overlays.setHelpTab(tab)
    helpTab = tab
end

local function drawBackdrop()
    local lg = love.graphics
    lg.setColor(0.02, 0.03, 0.06, 0.80)
    lg.rectangle("fill", 0, 0, C.VIRTUAL_W, C.VIRTUAL_H)
end

local function drawHelp(mx, my, time)
    local lg = love.graphics
    local box = { x = 140, y = 56, w = 1000, h = 608 }
    UI.drawPanel(box, "CONCORD TACTICAL CODEX & BRIDGE MANUAL  [F1 / ESC TO CLOSE]", C.COLORS.cyan, time)

    local tabs = {
        { id = "controls", label = "CONTROLS & CLI" },
        { id = "enemies",  label = "HOSTILE FLEET" },
        { id = "hazards",  label = "HAZARDS & TACTICS" },
    }
    for i, t in ipairs(tabs) do
        local tx = box.x + 18 + (i - 1) * 195
        local ty = box.y + 34
        local _, rect = UI.drawButton(tx, ty, 185, 28, t.label, mx, my, {
            active = (helpTab == t.id),
            accent = C.COLORS.cyan,
        })
        hitBoxes[#hitBoxes + 1] = { rect = rect, action = "help_tab", value = t.id }
    end

    local _, closeRect = UI.drawButton(box.x + box.w - 110, box.y + 34, 92, 28, "CLOSE", mx, my, { accent = C.COLORS.amber })
    hitBoxes[#hitBoxes + 1] = { rect = closeRect, action = "close" }

    local cx = box.x + 24
    local cy = box.y + 76
    local cw = box.w - 48

    if helpTab == "controls" then
        -- Left column: Point-and-Click & Hotkeys
        lg.setFont(UI.fonts.md)
        lg.setColor(C.COLORS.cyan)
        lg.print("MODERN BRIDGE CONTROLS (MOUSE + HOTKEYS)", cx, cy)
        local mouseRows = {
            { "Click & Drag Viewport", "Plot curved vector course & drag to set exit heading (or click adjacent Outpost/Crystal Planet to Dock/Mine)." },
            { "Target & Weapons (RTwP)", "Click hostile / TAB: Target  |  Q: Clear  |  F: Beam Focused/Spread  |  G: Torp Auto  |  V: Firing Arcs" },
            { "Tactical Pause & Helm", "SPACE: Pause/Resume  |  +/- (or [/]): Throttle Stop  |  X: All Stop  |  C / Right-Click: Clear Course." },
            { "Left-Click Galactic Starmap", "Jump via FTL (or launch Recon Probe when Probe mode is active). Costs 2x energy if Shields are UP!" },
            { "Hotkeys [1] - [9]", "1:Sublight(I)  2:FTL(W)  3:Beams(P)  4:Torp(T)  5:Shields(S)  6:Probe(K)  7:Scan/Mine(L)  8:Dock(D)  9:Repair(R)" },
            { "Top Utility Keys", "F1:Help  |  F5:Quick Save  |  F9:Quick Load  |  M:Mute Audio  |  F11:Fullscreen  |  ESC:Pause / Cancel" },
        }
        local ry = cy + 24
        for _, r in ipairs(mouseRows) do
            lg.setFont(UI.fonts.sm)
            lg.setColor(C.COLORS.amber)
            lg.print(r[1], cx, ry)
            lg.setFont(UI.fonts.xs)
            lg.setColor(C.COLORS.text)
            lg.printf(r[2], cx + 215, ry + 1, cw - 220, "left")
            ry = ry + 34
        end

        lg.setColor(C.COLORS.border)
        lg.line(cx, ry + 2, cx + cw, ry + 2)
        ry = ry + 10

        lg.setFont(UI.fonts.md)
        lg.setColor(C.COLORS.emerald)
        lg.print("CLASSIC COMMAND-LINE PROMPT (Click bottom bar or press '/' to type, TAB completes)", cx, ry)
        ry = ry + 24

        local cliRows = {
            { "TARGET [next|clear|sx sy]", "Designate, cycle, or clear primary target  |  WEAPONS: Print weapon charge & lock status" },
            { "BEAMMODE | AUTOFIRE | ARCS", "BEAMMODE [focused|spread]  |  AUTOFIRE [beams|torp|all] [on|off]  |  ARCS [on|off]" },
            { "COURSE sx sy [deg]  |  CLEAR", "Plot vector curve to sector (1-8) with optional exit heading   |   Cancel plotted path" },
            { "PAUSE | RESUME | SPEED <val>", "Toggle tactical pause or set throttle (stop, 1/3, 2/3, flank, or 0-100%)" },
            { "MOVE / M <x> <y>  |  FTL <qx> <qy>", "Legacy sublight move or FTL jump to quadrant (1-8,1-8) [factor 1-9]" },
            { "BEAM / P <pwr> [x y] | TORP <x> <y>", "Fire manual beam volley or launch Plasma Torpedo (or BEAM/TORP AUTO [on|off])" },
            { "SHIELD / S [up|down|+n|-n]", "Toggle shields or route energy (e.g. S UP, S +300, S -200)" },
            { "SCAN / L   |   PROBE <qx> <qy>", "Active 3x3 scan + decloak + mine planet   |   Launch remote probe" },
            { "DOCK / D  |  REPAIR / R  |  FIX", "Dock adjacent to Outpost  |  Field repair (+1 cyc)  |  FIX <sys>, AUX, STATUS" },
        }
        for _, r in ipairs(cliRows) do
            lg.setFont(UI.fonts.xs)
            lg.setColor(C.COLORS.cyan)
            lg.print(r[1], cx, ry)
            lg.setColor(C.COLORS.textDim)
            lg.print(r[2], cx + 235, ry)
            ry = ry + 23
        end

    elseif helpTab == "enemies" then
        lg.setFont(UI.fonts.md)
        lg.setColor(C.COLORS.cyan)
        lg.print("HOSTILE SHIP CLASSES & GALACTIC INTEL CODES", cx, cy)
        lg.setFont(UI.fonts.sm)
        lg.setColor(C.COLORS.textDim)
        lg.print("Starmap quadrants show a 3-digit EBS code: [Enemies][Outposts][Stars] (e.g. 213 = 2 Hostiles, 1 Outpost, 3 Stars).", cx, cy + 24)

        local specs = { C.ENEMY_SPECS.raider, C.ENEMY_SPECS.cruiser, C.ENEMY_SPECS.dreadnought, C.ENEMY_SPECS.stalker }
        local notes = {
            raider      = "Fast escort interceptor. Moderate firepower; dangerous in packs.",
            cruiser     = "Armored frontline warship. Balanced deflector shields and hull plating.",
            dreadnought = "Heavy siege capital ship. Can warp between quadrants to besiege Orbital Outposts!",
            stalker     = "Cloaking ambusher. Hidden from Beams until revealed by Active Scan (7) or after firing.",
        }
        local ey = cy + 62
        for idx, sp in ipairs(specs) do
            lg.setColor(0.08, 0.12, 0.22, 0.9)
            lg.rectangle("fill", cx, ey, cw, 92, 4, 4)
            lg.setColor(sp.color)
            lg.rectangle("line", cx, ey, cw, 92, 4, 4)

            -- Tactical silhouette preview frame on right
            local pvS = 84
            local pvX = cx + cw - pvS - 8
            local pvY = ey + 4
            lg.setColor(0.025, 0.038, 0.072, 0.96)
            lg.rectangle("fill", pvX, pvY, pvS, pvS, 3, 3)
            lg.setColor(sp.color[1], sp.color[2], sp.color[3], 0.35)
            lg.line(pvX + pvS * 0.5, pvY + 4, pvX + pvS * 0.5, pvY + pvS - 4)
            lg.line(pvX + 4, pvY + pvS * 0.5, pvX + pvS - 4, pvY + pvS * 0.5)
            lg.setColor(C.COLORS.border)
            lg.rectangle("line", pvX, pvY, pvS, pvS, 3, 3)

            Sprites.drawEnemyShip(pvX + pvS * 0.5, pvY + pvS * 0.5, pvS * 0.78, {
                id = idx,
                class = sp.class,
                hull = sp.maxHull,
                maxHull = sp.maxHull,
                shield = sp.maxShield,
                maxShield = sp.maxShield,
                heading = time * 0.55 + idx * 1.1,
            }, time, {
                hideBars = true,
                thrusting = (sp.class ~= "stalker"),
            })

            lg.setFont(UI.fonts.lg)
            lg.setColor(sp.color)
            lg.print(string.format("[%s] %s", sp.code, sp.name:upper()), cx + 16, ey + 10)
            lg.setFont(UI.fonts.sm)
            lg.setColor(C.COLORS.text)
            lg.print(string.format("Shields: %d   |   Hull: %d   |   Weapon Output: %d-%d   |   Bounty: %d pts",
                sp.maxShield, sp.maxHull, sp.minDmg, sp.maxDmg, sp.score), cx + 16, ey + 38)
            lg.setColor(C.COLORS.textDim)
            lg.print(notes[sp.class], cx + 16, ey + 62)
            ey = ey + 106
        end

    else -- hazards
        lg.setFont(UI.fonts.md)
        lg.setColor(C.COLORS.cyan)
        lg.print("GALACTIC PHENOMENA & COMMAND SURVIVAL TIPS", cx, cy)

        local tips = {
            { "STAR SUPERNOVAS (Tactical Risk / Weapon)", C.COLORS.amber,
              "Firing a Plasma Torpedo into a Star triggers an immediate 3x3 Supernova blast dealing 500 damage to all ships in range (including YOU if adjacent!). Useful to wipe clustered fleets." },
            { "GRAVITATIONAL SINGULARITIES", C.COLORS.violet,
              "Black holes absorb incoming torpedoes. Flying into one with Sublight Thrusters flings your ship to a random quadrant across the galaxy!" },
            { "OUTPOST SIEGES & DOCKING", C.COLORS.emerald,
              "When hostiles besiege an Orbital Outpost, a 5-cycle distress countdown starts. FTL in and eliminate all hostiles in that quadrant to earn +400 Station Saved bonus! Docking restores 100% Hull, Energy, Ammo, and Subsystems." },
            { "ENERGY & SHIELD DISCIPLINE", C.COLORS.cyan,
              "Moving with Shields UP consumes DOUBLE energy. Drop Shields before FTL jumps into safe quadrants, and keep Beam Heat below 100% to avoid emitter damage." },
            { "PLANETARY FUEL HARVESTING", C.COLORS.gold,
              "Planets marked with a cyan crystal diamond contain harvestable reactor fuel. Move adjacent and run Active Scan [7] to mine +250-450 Energy!" },
            { "ION STORMS & SUBSYSTEM DAMAGE", C.COLORS.crimson,
              "Ion Storms cut Beam Cannon output by 28% (Plasma Torpedoes are unaffected). If Life Support hits 0% outside an Outpost, you have 3 cycles to repair it." },
        }
        local ty = cy + 32
        for _, t in ipairs(tips) do
            lg.setFont(UI.fonts.sm)
            lg.setColor(t[2])
            lg.print(t[1], cx, ty)
            lg.setFont(UI.fonts.xs)
            lg.setColor(C.COLORS.text)
            lg.printf(t[3], cx, ty + 18, cw, "left")
            ty = ty + 72
        end
    end
end

local function drawPause(mx, my, prefs, time)
    local box = { x = 440, y = 135, w = 400, h = 450 }
    UI.drawPanel(box, "BRIDGE COMMAND PAUSED", C.COLORS.amber, time)

    local items = {
        { label = "RESUME MISSION",        action = "close",        accent = C.COLORS.emerald },
        { label = "SAVE MISSION  [F5]",    action = "save",         accent = C.COLORS.cyan },
        { label = "LOAD LAST SAVE  [F9]",  action = "load",         accent = C.COLORS.cyan, disabled = not Storage.hasSave() },
        { label = "AUDIO: " .. ((prefs and prefs.muted) and "MUTED" or "ON"), action = "toggle_mute", accent = C.COLORS.amber },
        { label = "CRT SCANLINES: " .. ((prefs and prefs.crt) and "ON" or "OFF"), action = "toggle_crt", accent = C.COLORS.amber },
        { label = "FAST ANIM: " .. ((prefs and prefs.fastAnim) and "ON" or "OFF"), action = "toggle_fast", accent = C.COLORS.amber },
        { label = "RESTART MISSION",       action = "restart",      accent = C.COLORS.crimson },
        { label = "RETURN TO TITLE",       action = "to_title",     accent = C.COLORS.crimson },
        { label = "QUIT TO DESKTOP",       action = "quit",         accent = C.COLORS.textDim },
    }

    local bx = box.x + 40
    local bw = box.w - 80
    for i, it in ipairs(items) do
        local by = box.y + 42 + (i - 1) * 43
        local _, rect = UI.drawButton(bx, by, bw, 35, it.label, mx, my, {
            accent = it.accent,
            disabled = it.disabled,
        })
        hitBoxes[#hitBoxes + 1] = { rect = rect, action = it.action }
    end
end

local function drawDebrief(mx, my, state, time)
    local lg = love.graphics
    local victory = (state.status == "victory")
    local accent = victory and C.COLORS.emerald or C.COLORS.crimson
    local title = victory and "MISSION ACCOMPLISHED — SECTOR SECURED" or "MISSION FAILED — FLEET SIGNAL LOST"
    local box = { x = 310, y = 100, w = 660, h = 520 }
    UI.drawPanel(box, title, accent, time)

    local info = debriefScoreInfo or Engine.calculateFinalScore(state)
    local cx = box.x + 30
    local cw = box.w - 60

    lg.setFont(UI.fonts.xl)
    lg.setColor(accent)
    lg.printf(victory and "VICTORY" or "DEFEAT", cx, box.y + 38, cw, "center")

    lg.setFont(UI.fonts.md)
    lg.setColor(C.COLORS.text)
    lg.printf(state.endReason or "", cx, box.y + 74, cw, "center")

    -- Rank badge
    lg.setColor(0.08, 0.13, 0.22, 0.95)
    lg.rectangle("fill", cx, box.y + 108, cw, 56, 4, 4)
    lg.setColor(C.COLORS.gold)
    lg.rectangle("line", cx, box.y + 108, cw, 56, 4, 4)
    lg.setFont(UI.fonts.sm)
    lg.setColor(C.COLORS.textDim)
    lg.printf("FINAL SERVICE RANK & SCORE", cx, box.y + 114, cw, "center")
    lg.setFont(UI.fonts.lg)
    lg.setColor(C.COLORS.gold)
    lg.printf(string.format("%s  —  %d PTS", info.rank:upper(), info.total), cx, box.y + 134, cw, "center")

    -- Detailed Breakdown
    local st = state.stats
    local rows = {
        { "Hostiles Destroyed", string.format("%d  (RDR:%d  CRS:%d  DRD:%d  STL:%d)",
            st.totalKills, st.killsByClass.raider or 0, st.killsByClass.cruiser or 0,
            st.killsByClass.dreadnought or 0, st.killsByClass.stalker or 0) },
        { "Combat & Rescue Score", string.format("%d pts  (Outposts Saved: %d, Lost: %d)", info.combatScore, st.outpostsSaved, st.outpostsLost) },
        { "Time Efficiency Bonus", string.format("+%d pts  (%.1f / %d cycles used)", info.timeBonus, state.cycle, state.maxCycles) },
        { "Outpost Survival Bonus", string.format("+%d pts", info.outpostBonus) },
        { "Hull Integrity Bonus", string.format("+%d pts  (%d%% hull remaining)", info.hullBonus, math.floor(state.player.hull / state.player.maxHull * 100)) },
        { "Difficulty Multiplier", string.format("x%.2f  (%s, Seed %d)", info.multiplier, C.DIFFICULTIES[state.difficulty].label, state.seed) },
        { "Special Operations", string.format("Supernovas: %d  |  Probes: %d  |  Planets Mined: %d", st.supernovas, st.probesLaunched, st.planetsMined) },
    }

    local ry = box.y + 184
    for _, r in ipairs(rows) do
        lg.setFont(UI.fonts.sm)
        lg.setColor(C.COLORS.textDim)
        lg.print(r[1], cx + 8, ry)
        lg.setColor(C.COLORS.text)
        lg.printf(r[2], cx, ry, cw - 8, "right")
        ry = ry + 30
    end

    local btnY = box.y + box.h - 62
    local _, b1 = UI.drawButton(cx + 30, btnY, 250, 40, "LAUNCH NEW MISSION", mx, my, { accent = C.COLORS.emerald })
    local _, b2 = UI.drawButton(cx + cw - 280, btnY, 250, 40, "TITLE SCREEN", mx, my, { accent = C.COLORS.cyan })
    hitBoxes[#hitBoxes + 1] = { rect = b1, action = "restart" }
    hitBoxes[#hitBoxes + 1] = { rect = b2, action = "to_title" }
end

local function drawRecords(mx, my, time)
    local lg = love.graphics
    local box = { x = 260, y = 90, w = 760, h = 540 }
    UI.drawPanel(box, "CONCORD FLEET SERVICE RECORD (TOP 10 MISSIONS)", C.COLORS.gold, time)

    local scores = Storage.loadScores()
    local cx = box.x + 24
    local cw = box.w - 48

    lg.setFont(UI.fonts.sm)
    lg.setColor(C.COLORS.cyan)
    lg.print("#   RANK / RESULT", cx, box.y + 38)
    lg.print("DIFFICULTY", cx + 290, box.y + 38)
    lg.print("KILLS / CYC", cx + 425, box.y + 38)
    lg.printf("SCORE", cx, box.y + 38, cw - 8, "right")

    lg.setColor(C.COLORS.border)
    lg.line(cx, box.y + 60, cx + cw, box.y + 60)

    if #scores == 0 then
        lg.setFont(UI.fonts.md)
        lg.setColor(C.COLORS.textDim)
        lg.printf("No completed missions recorded yet. Launch a sortie to earn your command rank!", cx, box.y + 180, cw, "center")
    else
        for i, sc in ipairs(scores) do
            local ry = box.y + 72 + (i - 1) * 38
            if i % 2 == 1 then
                lg.setColor(0.08, 0.12, 0.21, 0.55)
                lg.rectangle("fill", cx, ry - 4, cw, 30, 3, 3)
            end
            lg.setFont(UI.fonts.sm)
            lg.setColor(sc.victory and C.COLORS.emerald or C.COLORS.crimson)
            lg.print(string.format("%2d. %s", i, sc.rank or "Commander"), cx + 4, ry)
            lg.setColor(C.COLORS.text)
            lg.print((sc.difficulty or "CAPTAIN"):upper(), cx + 290, ry)
            lg.setColor(C.COLORS.textDim)
            lg.print(string.format("%d kills / %.1f cyc", sc.kills or 0, sc.cycles or 0), cx + 425, ry)
            lg.setColor(C.COLORS.gold)
            lg.printf(tostring(sc.score or 0), cx, ry, cw - 8, "right")
        end
    end

    local _, closeRect = UI.drawButton(box.x + box.w * 0.5 - 100, box.y + box.h - 54, 200, 38, "CLOSE", mx, my, { accent = C.COLORS.cyan })
    hitBoxes[#hitBoxes + 1] = { rect = closeRect, action = "close" }
end

function Overlays.draw(mx, my, state, prefs, time)
    if not activeOverlay then return end
    hitBoxes = {}
    drawBackdrop()
    if activeOverlay == "help" then
        drawHelp(mx, my, time)
    elseif activeOverlay == "pause" then
        drawPause(mx, my, prefs, time)
    elseif activeOverlay == "debrief" and state then
        drawDebrief(mx, my, state, time)
    elseif activeOverlay == "records" then
        drawRecords(mx, my, time)
    end
end

function Overlays.mousepressed(mx, my, button)
    if not activeOverlay or button ~= 1 then
        return nil
    end
    for _, hb in ipairs(hitBoxes) do
        if UI.pointInRect(mx, my, hb.rect) then
            if hb.action == "help_tab" then
                helpTab = hb.value
                return { action = "click" }
            elseif hb.action == "close" then
                activeOverlay = nil
                return { action = "click" }
            else
                return { action = hb.action }
            end
        end
    end
    return { action = "consumed" }
end

return Overlays
