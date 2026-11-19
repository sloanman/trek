-- Entry point for Vanguard Command (LÖVE 11.5)

local C = require("src.constants")
local Storage = require("src.storage")
local Sound = require("src.sound")
local Animations = require("src.animations")
local Engine = require("src.engine")
local UI = require("src.ui")
local Title = require("src.screens.title")
local Game = require("src.screens.game")
local Overlays = require("src.screens.overlays")

local screen = "title" -- "title" | "game"
local prefs = nil
local isTestMode = false
local isSmokeMode = false
local smokeRunner = nil

local function hasArg(flag)
    if type(arg) ~= "table" then return false end
    for _, v in ipairs(arg) do
        if v == flag then return true end
    end
    return false
end

local function computeTransform()
    local ww, wh = love.graphics.getDimensions()
    local scale = math.min(ww / C.VIRTUAL_W, wh / C.VIRTUAL_H)
    local ox = math.floor((ww - C.VIRTUAL_W * scale) * 0.5)
    local oy = math.floor((wh - C.VIRTUAL_H * scale) * 0.5)
    return scale, ox, oy, ww, wh
end

local function screenToVirtual(sx, sy)
    local scale, ox, oy = computeTransform()
    if scale <= 0 then return 0, 0 end
    return (sx - ox) / scale, (sy - oy) / scale
end

local function getVirtualMouse()
    if not (love and love.mouse) then return -1, -1 end
    local sx, sy = love.mouse.getPosition()
    return screenToVirtual(sx, sy)
end

local function applyPrefToggle(action)
    if action == "toggle_mute" then
        prefs.muted = Sound.toggleMute()
        Storage.savePrefs(prefs)
    elseif action == "toggle_crt" then
        prefs.crt = not prefs.crt
        Storage.savePrefs(prefs)
    elseif action == "toggle_fast" then
        prefs.fastAnim = not prefs.fastAnim
        Animations.setFastMode(prefs.fastAnim)
        Storage.savePrefs(prefs)
    end
end

local function startNewMission(difficulty, seed)
    local st = Engine.newGame(difficulty, seed)
    Storage.saveGame(st)
    Game.enter(st)
    screen = "game"
end

function love.load()
    math.randomseed(os.time())
    isTestMode = hasArg("--test")
    isSmokeMode = hasArg("--smoke")

    if isTestMode then
        local Tests = require("src.tests")
        local ok = Tests.runUnitTests()
        io.flush()
        os.exit(ok and 0 or 1)
        return
    end

    prefs = Storage.loadPrefs()
    UI.initFonts()
    Sound.init(prefs)
    Animations.setFastMode(prefs.fastAnim)

    if isSmokeMode then
        local Tests = require("src.tests")
        smokeRunner = Tests.createSmokeRunner({
            Title = Title,
            Game = Game,
            Overlays = Overlays,
            Engine = Engine,
            Animations = Animations,
            setScreen = function(s) screen = s end,
            getScreen = function() return screen end,
            getPrefs = function() return prefs end,
        })
        return
    end

    Title.enter()
    screen = "title"
end

function love.update(dt)
    if isTestMode then return end

    if isSmokeMode and smokeRunner then
        local ok, done, err = xpcall(function()
            return smokeRunner.step(dt)
        end, debug.traceback)
        if not ok then
            io.stderr:write("SMOKE TEST ERROR:\n" .. tostring(done) .. "\n")
            io.stderr:flush()
            os.exit(1)
            return
        end
        if err then
            io.stderr:write("SMOKE TEST FAILED: " .. tostring(err) .. "\n")
            io.stderr:flush()
            os.exit(1)
            return
        end
        if done then
            -- Final exit happens after draw completes
        end
    end

    if screen == "title" then
        Title.update(dt)
    else
        Game.update(dt)
    end
end

function love.draw()
    if isTestMode then return end

    local lg = love.graphics
    local scale, ox, oy, ww, wh = computeTransform()
    local mx, my = getVirtualMouse()

    lg.clear(0.02, 0.03, 0.06, 1)

    lg.push()
    lg.translate(ox, oy)
    lg.scale(scale, scale)
    lg.setScissor(ox, oy, math.floor(C.VIRTUAL_W * scale), math.floor(C.VIRTUAL_H * scale))

    if screen == "title" then
        Title.draw(mx, my, prefs)
    else
        Game.draw(mx, my, prefs)
    end

    if prefs and prefs.crt then
        UI.drawCRTOverlay(C.VIRTUAL_W, C.VIRTUAL_H)
    end

    lg.setScissor()
    lg.pop()

    -- Letterbox frame border
    lg.setColor(0.08, 0.14, 0.24, 0.8)
    lg.rectangle("line", ox, oy, C.VIRTUAL_W * scale, C.VIRTUAL_H * scale)

    if isSmokeMode and smokeRunner and smokeRunner.isFinished() then
        print("SMOKE TEST PASSED")
        io.flush()
        love.event.quit(0)
    end
end

function love.mousepressed(sx, sy, button)
    if isTestMode or isSmokeMode then return end
    local mx, my = screenToVirtual(sx, sy)

    if screen == "title" then
        local res = Title.mousepressed(mx, my, button)
        if res then
            if res.action == "start_new" then
                startNewMission(res.difficulty, res.seed)
            elseif res.action == "continue_save" then
                local saved = Storage.loadGame()
                if saved then
                    Game.enter(saved)
                    screen = "game"
                end
            elseif res.action == "quit" then
                love.event.quit(0)
            end
        end
    else
        local res = Game.mousepressed(mx, my, button, prefs)
        if res then
            if res.action == "toggle_mute" or res.action == "toggle_crt" or res.action == "toggle_fast" then
                applyPrefToggle(res.action)
            elseif res.action == "restart" then
                local st = Game.getState()
                startNewMission(st and st.difficulty or "captain", os.time() % 999999 + 1000)
            elseif res.action == "to_title" then
                Overlays.close()
                Title.enter()
                screen = "title"
            elseif res.action == "quit" then
                love.event.quit(0)
            end
        end
    end
end

function love.mousemoved(sx, sy, dx, dy)
    if isTestMode or isSmokeMode then return end
    if screen == "game" and Game.mousemoved then
        local mx, my = screenToVirtual(sx, sy)
        Game.mousemoved(mx, my)
    end
end

function love.mousereleased(sx, sy, button)
    if isTestMode or isSmokeMode then return end
    if screen == "game" and Game.mousereleased then
        local mx, my = screenToVirtual(sx, sy)
        Game.mousereleased(mx, my, button)
    end
end

function love.wheelmoved(wx, wy)
    if isTestMode or isSmokeMode then return end
    if screen == "game" then
        Game.wheelmoved(wx, wy)
    end
end

function love.keypressed(key)
    if isTestMode or isSmokeMode then return end

    if key == "f11" then
        local fs = love.window.getFullscreen()
        love.window.setFullscreen(not fs, "desktop")
        return
    end

    if screen == "title" then
        if key == "m" and not Overlays.isOpen() then
            -- Title seed field only accepts digits, so M can mute safely
            applyPrefToggle("toggle_mute")
            return
        end
        local res = Title.keypressed(key)
        if res then
            if res.action == "start_new" then
                startNewMission(res.difficulty, res.seed)
            elseif res.action == "quit" then
                love.event.quit(0)
            end
        end
    else
        Game.keypressed(key)
        if key == "m" and not Game.isCliFocused() and not Overlays.isOpen() then
            applyPrefToggle("toggle_mute")
        end
    end
end

function love.textinput(t)
    if isTestMode or isSmokeMode then return end
    if screen == "title" then
        Title.textinput(t)
    else
        Game.textinput(t)
    end
end

function love.quit()
    if not isTestMode and not isSmokeMode and screen == "game" then
        local st = Game.getState()
        if st and st.status == "active" then
            Storage.saveGame(st)
        end
    end
end
