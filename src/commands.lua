-- Classic VGA/EGA Trek command-line parser & autocomplete

local C = require("src.constants")
local Engine = require("src.engine")
local Galaxy = require("src.galaxy")
local Movement = require("src.movement")
local Combat = require("src.combat")

local Commands = {}

local CANONICAL = {
    "MOVE", "IMPULSE", "FTL", "WARP", "BEAM", "PHASER", "TORP", "TORPEDO",
    "SHIELD", "SHIELDS", "DOCK", "SCAN", "LRS", "MINE", "PROBE", "FIX",
    "WAIT", "REPAIR", "AUX", "STATUS", "SAVE", "LOAD", "HELP",
    "PAUSE", "RESUME", "SPEED", "THROTTLE", "STOP", "COURSE", "PLOT", "CLEAR",
    "TARGET", "TGT", "UNTARGET", "BEAMMODE", "AUTOFIRE", "WEAPONS", "ARCS",
}

local function parseToggleArg(arg)
    if not arg then return nil end
    local low = arg:lower()
    if low == "on" or low == "true" or low == "1" or low == "up" or low == "show" or low == "yes" then
        return true
    elseif low == "off" or low == "false" or low == "0" or low == "down" or low == "hide" or low == "no" then
        return false
    end
    return nil
end

local function tokenize(raw)
    local tokens = {}
    if not raw then
        return tokens
    end
    for tok in raw:gmatch("[^%s,]+") do
        tokens[#tokens + 1] = tok
    end
    return tokens
end

function Commands.autocomplete(prefix)
    if not prefix or prefix == "" then
        return nil
    end
    local up = prefix:upper()
    for _, cmd in ipairs(CANONICAL) do
        if cmd:sub(1, #up) == up then
            return cmd .. " "
        end
    end
    return nil
end

function Commands.execute(state, rawInput)
    local tokens = tokenize(rawInput)
    if #tokens == 0 then
        return { ok = false, msg = "Enter a command (type HELP for list).", events = {} }
    end

    local verb = tokens[1]:upper()

    -- HELP / H / ?
    if verb == "HELP" or verb == "H" or verb == "?" then
        return {
            ok = true,
            msg = "Commands: COURSE sx sy [deg] | TARGET [next|clear|sx sy] | BEAMMODE [focused|spread] | AUTOFIRE [beams|torp|all] [on|off] | ARCS | WEAPONS | PAUSE | SPEED | STATUS",
            events = {},
            uiAction = "open_help",
        }
    end

    if verb == "SAVE" then
        return { ok = true, msg = "Saving mission state...", events = {}, uiAction = "save" }
    end

    if verb == "LOAD" then
        return { ok = true, msg = "Loading saved mission...", events = {}, uiAction = "load" }
    end

    if not state then
        return { ok = false, msg = "No active mission.", events = {} }
    end

    -- STATUS / ST
    if verb == "STATUS" or verb == "ST" then
        Engine.ensureRealtimeState(state)
        local p = state.player
        local ws = Engine.getWeaponStatus(state)
        local hostiles = Galaxy.countTotalHostiles(state.galaxy)
        local outposts = Galaxy.countTotalOutposts(state.galaxy)
        local hdgDeg = math.floor((math.deg(p.heading or 0) % 360) + 0.5) % 360
        local tgtTag = ws.primary and string.format("Tgt:%s(%.1fs)", ws.primary.entity.code, ws.primary.geom.rangeSectors) or "Tgt:NONE"
        local msg = string.format(
            "%s Q(%d,%d) S(%d,%d) | Hull:%d/%d E:%d/%d Shd:%s(%d) Torp:%d Prb:%d | Hostiles:%d Cyc:%.1f/%d | %s Hdg:%03d Spd:%d/%d | %s Beam:%s(%d%%) Torp:%d%%",
            state.shipName, p.qx, p.qy, p.sx, p.sy,
            p.hull, p.maxHull, p.energy, p.maxEnergy,
            p.shieldsUp and "UP" or "DN", p.shields,
            p.torpedoes, p.probes, hostiles, state.cycle, state.maxCycles,
            state.paused and "PAUSED" or "LIVE", hdgDeg, math.floor((p.speed or 0) + 0.5), math.floor(p.maxSpeed or 0),
            tgtTag, ws.beams.mode:upper(), math.floor(ws.beams.charge * 100 + 0.5), math.floor(ws.torpedoes.charge * 100 + 0.5)
        )
        Engine.addLog(state, msg, "cyan")
        return { ok = true, msg = msg, events = {} }
    end

    -- TARGET / TGT / UNTARGET
    if verb == "UNTARGET" then
        return Engine.clearTarget(state)
    end
    if verb == "TARGET" or verb == "TGT" then
        Engine.ensureRealtimeState(state)
        local arg1 = tokens[2]
        if not arg1 or arg1:lower() == "next" then
            return Engine.cycleTarget(state, 1)
        elseif arg1:lower() == "prev" or arg1:lower() == "back" then
            return Engine.cycleTarget(state, -1)
        elseif arg1:lower() == "clear" or arg1:lower() == "none" or arg1:lower() == "off" then
            return Engine.clearTarget(state)
        end

        local sx = tonumber(tokens[2])
        local sy = tonumber(tokens[3])
        local quad = Engine.currentQuad(state)
        if sx and sy then
            local ent = Galaxy.getEntityAt(quad, math.floor(sx), math.floor(sy))
            if ent and ent.kind == "enemy" and not ent.cloaked then
                return Engine.setTarget(state, ent.id)
            end
            return { ok = false, msg = string.format("No visible enemy at sector (%d,%d).", math.floor(sx), math.floor(sy)), events = {} }
        end

        local numId = tonumber(arg1)
        local low = arg1:lower()
        for _, e in ipairs(Combat.getVisibleHostiles(quad, state.player.x, state.player.y)) do
            if (numId and e.id == numId)
                or (e.code and e.code:lower() == low)
                or (e.name and e.name:lower():find(low, 1, true)) then
                return Engine.setTarget(state, e.id)
            end
        end
        return { ok = false, msg = "No matching visible enemy '" .. tostring(arg1) .. "'.", events = {} }
    end

    -- BEAMMODE / BMODE [focused|spread]
    if verb == "BEAMMODE" or verb == "BMODE" then
        return Engine.setBeamMode(state, tokens[2])
    end

    -- AUTOFIRE / AUTO [beams|torp|all] [on|off]
    if verb == "AUTOFIRE" or verb == "AUTO" then
        local a1 = tokens[2]
        local onOff = parseToggleArg(a1)
        if onOff ~= nil then
            return Engine.setWeaponAutoFire(state, "all", onOff)
        end
        return Engine.setWeaponAutoFire(state, a1 or "all", parseToggleArg(tokens[3]))
    end

    -- ARCS [on|off]
    if verb == "ARCS" then
        return Engine.setShowFiringArcs(state, parseToggleArg(tokens[2]))
    end

    -- WEAPONS / WPN
    if verb == "WEAPONS" or verb == "WPN" then
        local ws = Engine.getWeaponStatus(state)
        local tgtTxt = "NONE"
        if ws.primary then
            tgtTxt = string.format("%s %.1fs %+04d deg [%s]",
                ws.primary.entity.code,
                ws.primary.geom.rangeSectors,
                math.floor(ws.primary.geom.relBearingDeg + 0.5),
                ws.inBeamArc and "BEAM+TORP ARC" or (ws.inTorpArc and "TORP ARC" or "OUT ARC"))
        end
        local msg = string.format(
            "BEAM: %d%% %s %s (%s) | TORP: %d%% %s ammo:%d/%d (%s) | TGT: %s | ARCS:%s",
            math.floor(ws.beams.charge * 100 + 0.5),
            ws.beams.mode:upper(),
            ws.beams.autoFire and "AUTO" or "HOLD",
            ws.beams.statusText,
            math.floor(ws.torpedoes.charge * 100 + 0.5),
            ws.torpedoes.autoFire and "AUTO" or "MAN",
            ws.torpedoes.ammo,
            ws.torpedoes.maxAmmo,
            ws.torpedoes.statusText,
            tgtTxt,
            state.player.showFiringArcs and "ON" or "OFF"
        )
        Engine.addLog(state, msg, "cyan")
        return { ok = true, status = ws, msg = msg, events = {} }
    end

    -- PAUSE
    if verb == "PAUSE" then
        local res = Engine.setPaused(state, true)
        res.uiAction = "keep_paused"
        return res
    end

    -- RESUME / UNPAUSE / PLAY
    if verb == "RESUME" or verb == "UNPAUSE" or verb == "PLAY" then
        return Engine.setPaused(state, false)
    end

    -- SPEED / THROTTLE <stop|slow|1/3|cruise|2/3|flank|0..1|0..100%>
    if verb == "SPEED" or verb == "THROTTLE" or verb == "SPD" then
        local arg1 = tokens[2]
        if not arg1 then
            return { ok = false, msg = "Usage: SPEED <stop|1/3|2/3|flank|0-100%>", events = {} }
        end
        local low = arg1:lower()
        local ratio
        if low == "stop" or low == "halt" or low == "0" then
            ratio = 0.0
        elseif low == "slow" or low == "1/3" or low == "one-third" then
            ratio = 0.35
        elseif low == "cruise" or low == "2/3" or low == "two-thirds" then
            ratio = 0.70
        elseif low == "flank" or low == "full" or low == "max" then
            ratio = 1.0
        else
            local pctStr = arg1:match("^(%d+%.?%d*)%%$")
            if pctStr then
                ratio = (tonumber(pctStr) or 0) / 100
            else
                local num = tonumber(arg1)
                if not num then
                    return { ok = false, msg = "Usage: SPEED <stop|1/3|2/3|flank|0-100%>", events = {} }
                end
                ratio = (num > 1.0) and (num / 100) or num
            end
        end
        return Engine.setSpeedSetting(state, ratio)
    end

    -- STOP / HALT [ALL|PATH]
    if verb == "STOP" or verb == "HALT" then
        local res = Engine.setSpeedSetting(state, 0)
        if tokens[2] and (tokens[2]:upper() == "ALL" or tokens[2]:upper() == "PATH") then
            Engine.clearPlayerPath(state)
        end
        return res
    end

    -- COURSE / PLOT <sx> <sy> [exitHeadingDeg]
    if verb == "COURSE" or verb == "PLOT" then
        local sx = tonumber(tokens[2])
        local sy = tonumber(tokens[3])
        if not sx or not sy or sx < 1 or sx > C.GRID_SIZE or sy < 1 or sy > C.GRID_SIZE then
            return { ok = false, msg = "Usage: COURSE <sx> <sy> [headingDeg] (sx,sy in 1-8)", events = {} }
        end
        local destX, destY = Movement.sectorToWorld(sx, sy)
        local hdgDeg = tonumber(tokens[4])
        local exitHeading = hdgDeg and math.rad(hdgDeg) or nil
        return Engine.plotPlayerCourse(state, destX, destY, exitHeading, nil)
    end

    -- CLEAR / CANCEL
    if verb == "CLEAR" or verb == "CANCEL" then
        return Engine.clearPlayerPath(state)
    end

    -- MOVE / M / IMP / IMPULSE x y
    if verb == "MOVE" or verb == "MO" or verb == "MOV" or verb == "M" or verb == "IMP" or verb == "IMPULSE" or verb == "I" then
        local tx = tonumber(tokens[2])
        local ty = tonumber(tokens[3])
        if not tx or not ty then
            return { ok = false, msg = "Usage: MOVE <sx> <sy> (1-8)", events = {} }
        end
        return Engine.moveSublight(state, math.floor(tx), math.floor(ty))
    end

    -- FTL / WARP / W qx qy [factor]
    if verb == "FTL" or verb == "WARP" or verb == "WRP" or verb == "W" then
        local qx = tonumber(tokens[2])
        local qy = tonumber(tokens[3])
        local factor = tonumber(tokens[4]) or 5
        if not qx or not qy then
            return { ok = false, msg = "Usage: FTL <qx> <qy> [factor 1-9]", events = {} }
        end
        return Engine.jumpFTL(state, math.floor(qx), math.floor(qy), math.floor(factor))
    end

    -- BEAM / PHASER / P / B [power [sx sy] | focused | spread | auto [on|off]]
    if verb == "BEAM" or verb == "BEAMS" or verb == "B" or verb == "PHASER" or verb == "PHASERS" or verb == "P" then
        if tokens[2] and not tonumber(tokens[2]) then
            local low = tokens[2]:lower()
            if low == "focused" or low == "spread" then
                return Engine.setBeamMode(state, low)
            elseif low == "auto" then
                return Engine.setWeaponAutoFire(state, "beams", parseToggleArg(tokens[3]))
            end
        end
        local power = tonumber(tokens[2]) or 300
        local targetId = nil
        local tx = tonumber(tokens[3])
        local ty = tonumber(tokens[4])
        if tx and ty then
            local ent = Galaxy.getEntityAt(Engine.currentQuad(state), math.floor(tx), math.floor(ty))
            if ent and ent.kind == "enemy" then
                targetId = ent.id
            else
                return { ok = false, msg = string.format("No enemy at sector (%d,%d).", tx, ty), events = {} }
            end
        end
        return Engine.fireBeams(state, power, targetId)
    end

    -- TORP / TORPEDO / T / FPT [sx sy | auto [on|off]]
    if verb == "TORP" or verb == "TORPEDO" or verb == "TORPEDOES" or verb == "T" or verb == "FPT" then
        if tokens[2] and tokens[2]:lower() == "auto" then
            return Engine.setWeaponAutoFire(state, "torpedoes", parseToggleArg(tokens[3]))
        end
        local tx = tonumber(tokens[2])
        local ty = tonumber(tokens[3])
        if not tx or not ty then
            return { ok = false, msg = "Usage: TORP <sx> <sy> (1-8) or TORP AUTO [on|off]", events = {} }
        end
        return Engine.fireTorpedo(state, math.floor(tx), math.floor(ty))
    end

    -- SHIELD / SHIELDS / SH / S [up|down|+delta|-delta|targetAmt]
    if verb == "SHIELD" or verb == "SHIELDS" or verb == "SH" or verb == "S" then
        local arg1 = tokens[2]
        if not arg1 then
            return Engine.toggleShields(state, nil)
        end
        local low = arg1:lower()
        if low == "up" or low == "on" or low == "raise" then
            return Engine.toggleShields(state, true)
        elseif low == "down" or low == "off" or low == "lower" then
            return Engine.toggleShields(state, false)
        elseif arg1:sub(1, 1) == "+" or arg1:sub(1, 1) == "-" then
            local delta = tonumber(arg1)
            if not delta then
                return { ok = false, msg = "Usage: SHIELD [up|down|+amt|-amt]", events = {} }
            end
            return Engine.transferShieldEnergy(state, delta)
        else
            local targetAmt = tonumber(arg1)
            if not targetAmt then
                return { ok = false, msg = "Usage: SHIELD [up|down|+amt|-amt|amt]", events = {} }
            end
            local delta = math.floor(targetAmt) - state.player.shields
            return Engine.transferShieldEnergy(state, delta)
        end
    end

    -- DOCK / D
    if verb == "DOCK" or verb == "D" then
        return Engine.dock(state)
    end

    -- SCAN / LRS / MINE / L
    if verb == "SCAN" or verb == "LRS" or verb == "MINE" or verb == "L" then
        return Engine.activeScan(state)
    end

    -- PROBE qx qy
    if verb == "PROBE" or verb == "PRB" then
        local qx = tonumber(tokens[2])
        local qy = tonumber(tokens[3])
        if not qx or not qy then
            return { ok = false, msg = "Usage: PROBE <qx> <qy> (1-8)", events = {} }
        end
        return Engine.launchProbe(state, math.floor(qx), math.floor(qy))
    end

    -- FIX <subsystem>
    if verb == "FIX" then
        if not tokens[2] then
            return Engine.setRepairPriority(state, nil)
        end
        return Engine.setRepairPriority(state, tokens[2])
    end

    -- WAIT / REPAIR / R
    if verb == "WAIT" or verb == "REPAIR" or verb == "R" then
        return Engine.fieldRepair(state)
    end

    -- AUX
    if verb == "AUX" or verb == "ENERGY" or verb == "EN" then
        return Engine.useAuxReserve(state)
    end

    return { ok = false, msg = "Unknown command '" .. verb .. "'. Type HELP for syntax.", events = {} }
end

return Commands
