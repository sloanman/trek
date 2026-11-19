-- LÖVE 11.5 configuration for Vanguard Command

local function hasFlag(flag)
    if type(arg) ~= "table" then
        return false
    end
    for _, v in ipairs(arg) do
        if v == flag then
            return true
        end
    end
    return false
end

function love.conf(t)
    t.identity = "vanguard_command"
    t.version = "11.5"
    t.console = false

    if hasFlag("--test") then
        t.modules.window = false
        t.modules.graphics = false
        t.modules.audio = false
        t.modules.sound = false
        t.modules.joystick = false
        t.modules.touch = false
        t.modules.video = false
        t.modules.physics = false
        t.modules.mouse = false
        t.modules.keyboard = false
    else
        t.window.title = "VANGUARD COMMAND — Tactical Starbridge Simulator"
        t.window.width = 1280
        t.window.height = 720
        t.window.minwidth = 960
        t.window.minheight = 540
        t.window.resizable = true
        t.window.vsync = 1
        t.window.msaa = 4
        t.modules.joystick = false
        t.modules.physics = false
    end
end
