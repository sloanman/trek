-- Title & Mission Briefing screen for Vanguard Command

local C = require("src.constants")
local UI = require("src.ui")
local Sprites = require("src.sprites")
local Storage = require("src.storage")
local Sound = require("src.sound")
local Overlays = require("src.screens.overlays")

local Title = {}

local selectedDiff = "captain"
local seedText = ""
local seedFocused = false
local hitBoxes = {}
local timeAccum = 0

local function randomSeedString()
    return tostring(math.random(100000, 999999))
end

function Title.enter()
    if seedText == "" then
        seedText = randomSeedString()
    end
    seedFocused = false
end

function Title.update(dt)
    timeAccum = timeAccum + dt
end

function Title.draw(mx, my, prefs)
    local lg = love.graphics
    hitBoxes = {}

    -- Deep space starfield backdrop
    Sprites.drawStarfield(0, 0, C.VIRTUAL_W, C.VIRTUAL_H, timeAccum, 777)

    -- Decorative sweeping Concord starship & orbital grid preview in top-right background
    lg.setColor(0.14, 0.36, 0.56, 0.16)
    for i = 0, 8 do
        lg.line(60 + i * 145, 0, 60 + i * 145, C.VIRTUAL_H)
    end
    Sprites.drawPlayerShip(1156, 88, 114, math.pi * 0.5, true, 0.85, timeAccum, {
        thrusting = true,
        hullPct = 1.0,
    })
    Sprites.drawOutpost(128, 90, 84, timeAccum, false)

    -- Hero title banner
    lg.setFont(UI.fonts.title)
    lg.setColor(0, 0, 0, 0.75)
    lg.printf(C.GAME_TITLE, 0, 48 + 3, C.VIRTUAL_W, "center")
    lg.setColor(C.COLORS.cyan)
    lg.printf(C.GAME_TITLE, 0, 48, C.VIRTUAL_W, "center")

    lg.setFont(UI.fonts.md)
    lg.setColor(C.COLORS.amber)
    lg.printf(C.GAME_SUBTITLE .. "  —  CONCORD FLEET TACTICAL OPS", 0, 98, C.VIRTUAL_W, "center")

    lg.setFont(UI.fonts.sm)
    lg.setColor(C.COLORS.textDim)
    lg.printf("Command the CSV VANGUARD across an 8x8 hostile frontier. Manage energy, shields, FTL jumps, weapons, and outpost rescues.",
        180, 126, C.VIRTUAL_W - 360, "center")

    -- Difficulty Selection Panel
    local diffPanel = { x = 120, y = 164, w = 1040, h = 232 }
    UI.drawPanel(diffPanel, "SELECT COMMAND DIFFICULTY & THREAT PROFILE", C.COLORS.cyan, timeAccum)

    local cardW = 240
    local cardH = 182
    local gap = 14
    local startX = diffPanel.x + 20
    local cardY = diffPanel.y + 36

    for i, key in ipairs(C.DIFFICULTY_ORDER) do
        local d = C.DIFFICULTIES[key]
        local cx = startX + (i - 1) * (cardW + gap)
        local rect = { x = cx, y = cardY, w = cardW, h = cardH }
        local active = (selectedDiff == key)
        local hovered = UI.pointInRect(mx, my, rect)

        local accent = C.COLORS.cyan
        if key == "captain" then accent = C.COLORS.emerald
        elseif key == "commander" then accent = C.COLORS.amber
        elseif key == "admiral" then accent = C.COLORS.crimson end

        lg.setColor(active and { accent[1] * 0.20, accent[2] * 0.20, accent[3] * 0.20, 0.96 }
            or (hovered and { 0.11, 0.17, 0.29, 0.95 } or { 0.07, 0.11, 0.19, 0.92 }))
        lg.rectangle("fill", cx, cardY, cardW, cardH, 4, 4)

        lg.setLineWidth(active and 2.2 or 1)
        lg.setColor(active and accent or (hovered and C.COLORS.borderBright or C.COLORS.border))
        lg.rectangle("line", cx, cardY, cardW, cardH, 4, 4)
        lg.setLineWidth(1)

        lg.setFont(UI.fonts.lg)
        lg.setColor(accent)
        lg.print(d.label, cx + 14, cardY + 12)
        if active then
            lg.setFont(UI.fonts.xs)
            lg.setColor(C.COLORS.gold)
            lg.printf("SELECTED", cx, cardY + 16, cardW - 14, "right")
        end

        lg.setFont(UI.fonts.xs)
        lg.setColor(C.COLORS.text)
        lg.printf(d.desc, cx + 14, cardY + 42, cardW - 28, "left")

        local totalHostiles = (d.enemies.raider or 0) + (d.enemies.cruiser or 0) + (d.enemies.dreadnought or 0) + (d.enemies.stalker or 0)
        local statsY = cardY + 94
        lg.setColor(C.COLORS.textDim)
        lg.print(string.format("Hostile Fleet: %d ships", totalHostiles), cx + 14, statsY)
        lg.print(string.format("Outposts: %d   |   Cycles: %d", d.outposts, d.cycles), cx + 14, statsY + 18)
        lg.print(string.format("Energy: %d   |   Torp: %d", d.maxEnergy, d.maxTorpedoes), cx + 14, statsY + 36)
        lg.setColor(C.COLORS.gold)
        lg.print(string.format("Score Multiplier: x%.2f", d.scoreMult), cx + 14, statsY + 56)

        hitBoxes[#hitBoxes + 1] = { rect = rect, action = "select_diff", value = key }
    end

    -- Mission Seed & Launch Console
    local seedPanel = { x = 120, y = 412, w = 1040, h = 236 }
    UI.drawPanel(seedPanel, "MISSION PARAMETERS & DEPLOYMENT", C.COLORS.emerald, timeAccum)

    local sx = seedPanel.x + 28
    local sy = seedPanel.y + 42
    lg.setFont(UI.fonts.sm)
    lg.setColor(C.COLORS.textDim)
    lg.print("GALACTIC SECTOR SEED (numeric or blank for random):", sx, sy)

    local inputRect = { x = sx, y = sy + 24, w = 240, h = 36 }
    lg.setColor(0.04, 0.06, 0.11, 1)
    lg.rectangle("fill", inputRect.x, inputRect.y, inputRect.w, inputRect.h, 3, 3)
    lg.setColor(seedFocused and C.COLORS.cyan or C.COLORS.border)
    lg.rectangle("line", inputRect.x, inputRect.y, inputRect.w, inputRect.h, 3, 3)
    lg.setFont(UI.fonts.md)
    lg.setColor(C.COLORS.text)
    local cursor = (seedFocused and (math.floor(timeAccum * 2) % 2 == 0)) and "_" or ""
    lg.print(seedText .. cursor, inputRect.x + 12, inputRect.y + 9)
    hitBoxes[#hitBoxes + 1] = { rect = inputRect, action = "focus_seed" }

    local _, randRect = UI.drawButton(sx + 252, sy + 24, 120, 36, "RANDOM", mx, my, { accent = C.COLORS.cyan })
    hitBoxes[#hitBoxes + 1] = { rect = randRect, action = "random_seed" }

    -- Right side info summary
    lg.setFont(UI.fonts.sm)
    lg.setColor(C.COLORS.textDim)
    lg.print("BRIDGE FEATURES:", sx + 430, sy)
    lg.setFont(UI.fonts.xs)
    lg.setColor(C.COLORS.text)
    lg.print("- Full Mouse Point-and-Click + Classic Command-Line Prompt ('/' to type)", sx + 430, sy + 22)
    lg.print("- Deterministic Raycast Sightlines, Nova Warnings & Auto-Save / Quick-Save (F5)", sx + 430, sy + 40)
    lg.print("- 4 Hostile Classes, Cloaked Frigates, Black Holes, Supernovas & Outpost Sieges", sx + 430, sy + 58)

    -- Action buttons row
    local btnY = seedPanel.y + 132
    local hasSave = Storage.hasSave()
    if hasSave then
        local _, rCont = UI.drawButton(sx, btnY, 224, 46, "CONTINUE MISSION", mx, my, { accent = C.COLORS.gold, font = UI.fonts.md, pulse = true, time = timeAccum })
        local _, rNew  = UI.drawButton(sx + 240, btnY, 224, 46, "LAUNCH NEW MISSION", mx, my, { accent = C.COLORS.emerald, font = UI.fonts.md })
        local _, rRec  = UI.drawButton(sx + 480, btnY, 176, 46, "SERVICE RECORD", mx, my, { accent = C.COLORS.cyan })
        local _, rHelp = UI.drawButton(sx + 672, btnY, 176, 46, "HOW TO PLAY [F1]", mx, my, { accent = C.COLORS.amber })
        local _, rQuit = UI.drawButton(sx + 864, btnY, 120, 46, "QUIT", mx, my, { accent = C.COLORS.crimson })
        hitBoxes[#hitBoxes + 1] = { rect = rCont, action = "continue" }
        hitBoxes[#hitBoxes + 1] = { rect = rNew,  action = "new_game" }
        hitBoxes[#hitBoxes + 1] = { rect = rRec,  action = "records" }
        hitBoxes[#hitBoxes + 1] = { rect = rHelp, action = "help" }
        hitBoxes[#hitBoxes + 1] = { rect = rQuit, action = "quit" }
    else
        local _, rNew  = UI.drawButton(sx, btnY, 280, 46, "LAUNCH NEW MISSION", mx, my, { accent = C.COLORS.emerald, font = UI.fonts.md })
        local _, rRec  = UI.drawButton(sx + 298, btnY, 220, 46, "SERVICE RECORD", mx, my, { accent = C.COLORS.cyan })
        local _, rHelp = UI.drawButton(sx + 536, btnY, 220, 46, "HOW TO PLAY [F1]", mx, my, { accent = C.COLORS.amber })
        local _, rQuit = UI.drawButton(sx + 774, btnY, 210, 46, "QUIT", mx, my, { accent = C.COLORS.crimson })
        hitBoxes[#hitBoxes + 1] = { rect = rNew,  action = "new_game" }
        hitBoxes[#hitBoxes + 1] = { rect = rRec,  action = "records" }
        hitBoxes[#hitBoxes + 1] = { rect = rHelp, action = "help" }
        hitBoxes[#hitBoxes + 1] = { rect = rQuit, action = "quit" }
    end

    -- Footer bar
    lg.setFont(UI.fonts.xs)
    lg.setColor(C.COLORS.textMuted)
    lg.printf("Vanguard Command v1.0  |  Inspired by 1992 VGA Trek  |  F1: Help   F11: Fullscreen   M: Mute Audio",
        0, C.VIRTUAL_H - 34, C.VIRTUAL_W, "center")

    if Overlays.isOpen() then
        Overlays.draw(mx, my, nil, prefs, timeAccum)
    end
end

function Title.mousepressed(mx, my, button)
    if Overlays.isOpen() then
        local res = Overlays.mousepressed(mx, my, button)
        if res and res.action == "click" then
            Sound.play("click")
        end
        return nil
    end

    if button ~= 1 then return nil end

    seedFocused = false
    for _, hb in ipairs(hitBoxes) do
        if UI.pointInRect(mx, my, hb.rect) then
            Sound.play("click")
            if hb.action == "select_diff" then
                selectedDiff = hb.value
                return nil
            elseif hb.action == "focus_seed" then
                seedFocused = true
                return nil
            elseif hb.action == "random_seed" then
                seedText = randomSeedString()
                return nil
            elseif hb.action == "new_game" then
                local s = tonumber(seedText) or os.time() % 999999 + 1000
                seedText = tostring(s)
                return { action = "start_new", difficulty = selectedDiff, seed = s }
            elseif hb.action == "continue" then
                return { action = "continue_save" }
            elseif hb.action == "records" then
                Overlays.open("records")
                return nil
            elseif hb.action == "help" then
                Overlays.open("help")
                return nil
            elseif hb.action == "quit" then
                return { action = "quit" }
            end
        end
    end
    return nil
end

function Title.keypressed(key)
    if Overlays.isOpen() then
        if key == "escape" or key == "f1" then
            Overlays.close()
            Sound.play("click")
        end
        return nil
    end

    if seedFocused then
        if key == "backspace" then
            seedText = seedText:sub(1, math.max(0, #seedText - 1))
        elseif key == "return" or key == "kpenter" or key == "escape" then
            seedFocused = false
        end
        return nil
    end

    if key == "f1" then
        Overlays.open("help")
        Sound.play("click")
    elseif key == "return" or key == "kpenter" then
        local s = tonumber(seedText) or os.time() % 999999 + 1000
        return { action = "start_new", difficulty = selectedDiff, seed = s }
    elseif key == "escape" then
        return { action = "quit" }
    end
    return nil
end

function Title.textinput(t)
    if Overlays.isOpen() or not seedFocused then return end
    if t:match("^%d$") and #seedText < 9 then
        seedText = seedText .. t
    end
end

return Title
