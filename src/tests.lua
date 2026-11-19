-- Headless unit/integration test suite (--test) & graphical smoke runner (--smoke)

local C = require("src.constants")
local RNG = require("src.rng")
local Storage = require("src.storage")
local Galaxy = require("src.galaxy")
local Movement = require("src.movement")
local Combat = require("src.combat")
local Engine = require("src.engine")
local Commands = require("src.commands")
local TurnaroundData = require("src.turnaround_data")

local Tests = {}

local passed = 0
local failed = 0

local function assertTrue(cond, msg)
    if not cond then
        error("Assertion failed: " .. tostring(msg), 2)
    end
end

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s (expected %s, got %s)", tostring(msg), tostring(expected), tostring(actual)), 2)
    end
end

local function runCase(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print(string.format("[PASS] %s", name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s\n%s", name, tostring(err)))
    end
end

local function clearEntities(quad)
    quad.entities = {}
end

local function makeCleanQuad(state, qx, qy)
    local q = Galaxy.getQuad(state.galaxy, qx, qy)
    clearEntities(q)
    q.ionStorm = false
    q.siege = nil
    return q
end

function Tests.runUnitTests()
    passed = 0
    failed = 0

    -- 1. Deterministic RNG & Galaxy Generation across all 4 difficulties
    runCase("Deterministic RNG & Galaxy Generation", function()
        local r1 = RNG.new(424242)
        local r2 = RNG.new(424242)
        for i = 1, 25 do
            assertEq(r1:int(1, 10000), r2:int(1, 10000), "RNG sequence mismatch at step " .. i)
        end

        for _, diffKey in ipairs(C.DIFFICULTY_ORDER) do
            local diff = C.DIFFICULTIES[diffKey]
            local st = Engine.newGame(diffKey, 777123)
            local expectedEnemies = (diff.enemies.raider or 0) + (diff.enemies.cruiser or 0)
                + (diff.enemies.dreadnought or 0) + (diff.enemies.stalker or 0)
            assertEq(Galaxy.countTotalHostiles(st.galaxy), expectedEnemies, diffKey .. " hostile count")
            assertEq(Galaxy.countTotalOutposts(st.galaxy), diff.outposts, diffKey .. " outpost count")

            local startQuad = Galaxy.getQuad(st.galaxy, st.player.qx, st.player.qy)
            assertEq(#Galaxy.getEnemies(startQuad, true), 0, diffKey .. " start quad must be safe")

            local foundNearOutpost = false
            for qy = 1, C.GRID_SIZE do
                for qx = 1, C.GRID_SIZE do
                    if Galaxy.getOutpost(Galaxy.getQuad(st.galaxy, qx, qy)) then
                        local d = math.abs(qx - st.player.qx) + math.abs(qy - st.player.qy)
                        if d <= 2 then
                            foundNearOutpost = true
                        end
                    end
                end
            end
            assertTrue(foundNearOutpost, diffKey .. " must have an Outpost within Manhattan dist <= 2")
        end
    end)

    -- 2. Shared traceRay, Sublight movement, Obstacle blocking, Singularity slingshot
    runCase("TraceRay, Sublight Movement & Singularity Slingshot", function()
        local st = Engine.newGame("captain", 10101)
        local q = makeCleanQuad(st, 4, 4)
        st.player.sx, st.player.sy = 2, 2
        q.entities[#q.entities + 1] = { id = 9001, kind = "star", x = 5, y = 2, colorIdx = 1, radius = 1 }

        local prev = Engine.previewSublight(st, 7, 2)
        assertTrue(prev.ok, "Sublight preview should succeed stopping before star")
        assertEq(prev.destX, 4, "Should stop at x=4 before star at x=5")
        assertEq(prev.destY, 2, "Should stay on row y=2")
        assertTrue(prev.blockedBy ~= nil and prev.blockedBy.kind == "star", "Should report star blocker")

        local res = Engine.moveSublight(st, 7, 2)
        assertTrue(res.ok, "Sublight move should execute")
        assertEq(st.player.sx, 4, "Player moved to exact preview destX")
        assertEq(st.player.sy, 2, "Player moved to exact preview destY")

        -- Singularity slingshot
        q.entities[#q.entities + 1] = { id = 9002, kind = "singularity", x = 4, y = 6, phase = 0 }
        local sPrev = Engine.previewSublight(st, 4, 6)
        assertTrue(sPrev.ok and sPrev.singularityRisk, "Singularity preview should flag slingshot risk")
        local sRes = Engine.moveSublight(st, 4, 6)
        assertTrue(sRes.ok, "Singularity slingshot move succeeds")
        assertTrue(st.player.qx >= 1 and st.player.qx <= 8 and st.player.qy >= 1 and st.player.qy <= 8, "Slingshot lands in valid quadrant")
    end)

    -- 3. FTL Jump math, 2x Shields penalty, Overstress, 3x3 auto-scan
    runCase("FTL Jump, 2x Shield Penalty, Overstress & Auto-Scan", function()
        local st = Engine.newGame("captain", 20202)
        st.player.qx, st.player.qy = 4, 4
        local pDown = Engine.previewFTL(st, 6, 4, 5)
        assertTrue(pDown.ok, "FTL preview valid")
        st.player.shieldsUp = true
        local pUp = Engine.previewFTL(st, 6, 4, 5)
        assertTrue(pUp.ok and pUp.shieldsPenalty, "FTL preview flags 2x shields penalty")
        assertEq(pUp.energyCost, pDown.energyCost * 2, "Shields UP doubles FTL energy cost")

        -- Overstress risk above Factor 6
        local pOver = Engine.previewFTL(st, 6, 4, 9)
        assertTrue(pOver.overstressRisk > 0, "Factor 9 triggers overstress risk")

        local beforeE = st.player.energy
        local targetQ = Galaxy.getQuad(st.galaxy, 1, 1)
        targetQ.explored = false
        local jumpRes = Engine.jumpFTL(st, 1, 1, 5)
        assertTrue(jumpRes.ok, "FTL jump executes")
        assertEq(st.player.qx, 1)
        assertEq(st.player.qy, 1)
        assertTrue(st.player.energy < beforeE, "Energy deducted")
        assertTrue(Galaxy.getQuad(st.galaxy, 1, 1).explored, "Arrival quad revealed")
        assertTrue(Galaxy.getQuad(st.galaxy, 2, 1).explored, "Neighbor quad auto-scanned")
        assertTrue(Galaxy.getQuad(st.galaxy, 1, 2).explored, "Neighbor quad auto-scanned")
    end)

    -- 4. Beam Cannon combat (spread & focused), falloff, heat, destruction & scoring
    runCase("Beam Cannons: Spread, Focused, Heat, Kill & Scoring", function()
        local st = Engine.newGame("captain", 30303)
        local q = makeCleanQuad(st, 4, 4)
        st.player.sx, st.player.sy = 4, 4
        local e1 = { id = 8001, kind = "enemy", class = "raider", name = "Raider 1", code = "RDR",
            x = 4, y = 5, shield = 60, maxShield = 160, hull = 80, maxHull = 180, minDmg = 10, maxDmg = 20, score = 120, cloaked = false }
        local e2 = { id = 8002, kind = "enemy", class = "raider", name = "Raider 2", code = "RDR",
            x = 7, y = 4, shield = 160, maxShield = 160, hull = 180, maxHull = 180, minDmg = 10, maxDmg = 20, score = 120, cloaked = false }
        q.entities = { e1, e2 }

        local prev = Engine.previewBeams(st, 400, nil)
        assertTrue(prev.ok and #prev.targets == 2, "Spread targets both visible enemies")
        assertTrue(prev.targets[1].estDmg > prev.targets[2].estDmg, "Closer enemy takes more beam dmg than distant enemy")

        local focused = Engine.fireBeams(st, 450, e1.id)
        assertTrue(focused.ok, "Focused beam strike succeeds")
        assertTrue(st.player.beamHeat > 0, "Beam firing generates heat")
        assertTrue(st.stats.totalKills >= 1 and st.score >= 120, "Focused beam kills weak raider and awards score")
    end)

    -- 5. Plasma Torpedo piercing, friendly outpost interlock, Star Supernova
    runCase("Plasma Torpedoes, Outpost Interlock & Star Supernova", function()
        local st = Engine.newGame("captain", 40404)
        local q = makeCleanQuad(st, 4, 4)
        st.player.sx, st.player.sy = 2, 4

        -- Friendly outpost interlock check
        q.entities = {
            { id = 8100, kind = "outpost", name = "Test Base", x = 5, y = 4, hp = 500, maxHp = 500 }
        }
        local opPrev = Engine.previewTorpedo(st, 6, 4)
        assertTrue((not opPrev.ok) and opPrev.friendlyBlocked, "Interlock must block torpedo hitting friendly Outpost")

        -- Piercing enemy hit
        local enemy = { id = 8101, kind = "enemy", class = "cruiser", name = "Cruiser", code = "CRS",
            x = 5, y = 4, shield = 300, maxShield = 300, hull = 340, maxHull = 340, minDmg = 10, maxDmg = 20, score = 240, cloaked = false }
        q.entities = { enemy }
        local tRes = Engine.fireTorpedo(st, 5, 4)
        assertTrue(tRes.ok, "Torpedo fires cleanly")
        assertTrue(enemy.hull < 340, "40% piercing damages hull even with shields remaining")

        -- Star Supernova 3x3 blast
        st.player.sx, st.player.sy = 1, 1
        local star = { id = 8102, kind = "star", x = 5, y = 5, colorIdx = 1, radius = 1 }
        local doomed = { id = 8103, kind = "enemy", class = "cruiser", name = "Doomed", code = "CRS",
            x = 6, y = 5, shield = 200, maxShield = 300, hull = 220, maxHull = 340, minDmg = 10, maxDmg = 20, score = 240, cloaked = false }
        q.entities = { star, doomed }
        local nPrev = Engine.previewTorpedo(st, 5, 5)
        assertTrue(nPrev.ok and nPrev.novaWarning, "Torpedo preview warns of Supernova")
        local nRes = Engine.fireTorpedo(st, 5, 5)
        assertTrue(nRes.ok, "Supernova torpedo executes")
        assertEq(st.stats.supernovas, 1, "Supernova stat incremented")
        assertEq(Galaxy.getEntityById(q, star.id), nil, "Detonated star removed")
        assertEq(Galaxy.getEntityById(q, doomed.id), nil, "Adjacent enemy destroyed by 500-dmg supernova")
    end)

    -- 6. Stealth Frigate cloaking, Active Scan decloak & Planetary mining
    runCase("Stealth Cloak, Active Scan Decloak & Planetary Fuel Mining", function()
        local st = Engine.newGame("captain", 50505)
        local q = makeCleanQuad(st, 4, 4)
        st.player.sx, st.player.sy = 3, 3
        st.player.energy = 1000
        local stalker = { id = 8201, kind = "enemy", class = "stalker", name = "Stealth Frigate", code = "STL",
            x = 6, y = 6, shield = 220, maxShield = 220, hull = 240, maxHull = 240, minDmg = 10, maxDmg = 20, score = 320, cloaked = true, decloakTurns = 0 }
        local planet = { id = 8202, kind = "planet", name = "Cygnus", x = 4, y = 3, hasFuel = true, fuelAmount = 350, mined = false, habitable = false, colorIdx = 1 }
        q.entities = { stalker, planet }

        local bPrev = Engine.previewBeams(st, 200, nil)
        assertTrue(not bPrev.ok, "Cloaked enemy cannot be targeted by beams before scan")

        local scanRes = Engine.activeScan(st)
        assertTrue(scanRes.ok, "Active Scan executes")
        assertTrue(not stalker.cloaked, "Active Scan decloaks stealth frigate")
        assertTrue(planet.mined, "Adjacent fuel planet mined by Active Scan")
        assertTrue(st.player.energy >= 1350, "Mined fuel added to ship energy")
    end)

    -- 7. Recon Probe reveals target + 4 orthogonal neighbors
    runCase("Recon Probe Cross-Section Reveal", function()
        local st = Engine.newGame("captain", 60606)
        for qy = 1, 8 do
            for qx = 1, 8 do
                Galaxy.getQuad(st.galaxy, qx, qy).explored = false
            end
        end
        local beforeProbes = st.player.probes
        local res = Engine.launchProbe(st, 7, 7)
        assertTrue(res.ok, "Probe launches cleanly")
        assertEq(st.player.probes, beforeProbes - 1, "Probe count decremented")
        assertTrue(Galaxy.getQuad(st.galaxy, 7, 7).explored, "Center quad revealed")
        assertTrue(Galaxy.getQuad(st.galaxy, 6, 7).explored, "West quad revealed")
        assertTrue(Galaxy.getQuad(st.galaxy, 8, 7).explored, "East quad revealed")
        assertTrue(Galaxy.getQuad(st.galaxy, 7, 6).explored, "North quad revealed")
        assertTrue(Galaxy.getQuad(st.galaxy, 7, 8).explored, "South quad revealed")
        assertTrue(not Galaxy.getQuad(st.galaxy, 6, 6).explored, "Diagonal quad stays unrevealed by probe")
    end)

    -- 8. Outpost Docking full restore & Siege Clearance Bonus
    runCase("Outpost Docking Restore & Siege Clearance Bonus", function()
        local st = Engine.newGame("captain", 70707)
        local q = makeCleanQuad(st, 4, 4)
        st.player.sx, st.player.sy = 4, 4
        st.player.hull = 350
        st.player.energy = 500
        st.player.torpedoes = 1
        st.player.systems.ftl = 40
        local outpost = { id = 8301, kind = "outpost", name = "Outpost Alpha", x = 5, y = 4, hp = 500, maxHp = 500 }
        local raider = { id = 8302, kind = "enemy", class = "raider", name = "Siege Raider", code = "RDR",
            x = 5, y = 5, shield = 0, maxShield = 160, hull = 100, maxHull = 180, minDmg = 10, maxDmg = 20, score = 120, cloaked = false }
        q.entities = { outpost, raider }
        q.siege = { cyclesLeft = 3.0, maxCycles = 5.0, outpostId = outpost.id }

        local dockRes = Engine.dock(st)
        assertTrue(dockRes.ok, "Docking succeeds when adjacent")
        assertEq(st.player.hull, st.player.maxHull, "Docking restores full hull")
        assertEq(st.player.energy, st.player.maxEnergy, "Docking restores full energy")
        assertEq(st.player.torpedoes, st.player.maxTorpedoes, "Docking restores torpedoes")
        assertEq(st.player.systems.ftl, 100, "Docking repairs subsystems to 100%")
        assertTrue(q.siege == nil, "Outpost turret kill cleared active siege")
        assertEq(st.stats.outpostsSaved, 1, "Outpost saved stat incremented")
        assertTrue(st.score >= 520, "Awarded kill score + 400 Station Saved bonus")
    end)

    -- 9. Field Repair & FIX Priority, Shields toggle/transfer, Aux reserve
    runCase("Field Repair, FIX Priority, Shield Routing & Aux Reserve", function()
        local st = Engine.newGame("captain", 80808)
        makeCleanQuad(st, 4, 4)
        st.player.systems.ftl = 20
        st.player.systems.beams = 20
        Engine.setRepairPriority(st, "ftl")
        local repRes = Engine.fieldRepair(st)
        assertTrue(repRes.ok, "Field repair succeeds")
        assertTrue(st.player.systems.ftl > st.player.systems.beams, "Priority system repaired significantly faster")

        -- Shields toggle & transfer
        local sRes = Engine.toggleShields(st, true)
        assertTrue(sRes.ok and st.player.shieldsUp, "Shields raise")
        local tRes = Engine.transferShieldEnergy(st, 200)
        assertTrue(tRes.ok, "Transfer to shields succeeds")

        -- Aux reserve
        st.player.energy = 1000
        local auxAmt = st.player.auxReserve
        local aRes = Engine.useAuxReserve(st)
        assertTrue(aRes.ok, "Aux discharge succeeds")
        assertEq(st.player.energy, 1000 + auxAmt, "Aux added energy")
        assertEq(st.player.auxReserve, 0, "Aux depleted after full discharge")
    end)

    -- 10. Classic CLI Command Parser
    runCase("Classic CLI Command Parser & Autocomplete", function()
        local st = Engine.newGame("captain", 90909)
        local q = makeCleanQuad(st, 4, 4)
        st.player.sx, st.player.sy = 2, 2
        q.entities = {
            { id = 8401, kind = "enemy", class = "raider", name = "Target", code = "RDR",
              x = 6, y = 2, shield = 100, maxShield = 160, hull = 120, maxHull = 180, minDmg = 5, maxDmg = 10, score = 120, cloaked = false },
            { id = 8402, kind = "outpost", name = "Base", x = 3, y = 2, hp = 500, maxHp = 500 },
        }

        assertEq(Commands.autocomplete("SH"), "SHIELD ", "Autocomplete matches SHIELD")
        assertTrue(Commands.execute(st, "STATUS").ok, "STATUS works")
        assertTrue(Commands.execute(st, "HELP").uiAction == "open_help", "HELP triggers help action")
        assertTrue(Commands.execute(st, "S UP").ok and st.player.shieldsUp, "S UP raises shields")
        assertTrue(Commands.execute(st, "S +100").ok, "S +100 transfers shield energy")
        assertTrue(Commands.execute(st, "M 2 4").ok and st.player.sy == 4, "M 2 4 moves ship")
        assertTrue(Commands.execute(st, "P 200").ok, "P 200 fires beams")
        assertTrue(Commands.execute(st, "T 6 2").ok, "T 6 2 fires torpedo")
        assertTrue(Commands.execute(st, "SCAN").ok, "SCAN runs active scan")
        assertTrue(Commands.execute(st, "PROBE 2 2").ok, "PROBE 2 2 launches probe")
        assertTrue(Commands.execute(st, "FIX ftl").ok and st.player.prioritySystem == "ftl", "FIX ftl assigns priority")
        assertTrue(Commands.execute(st, "WAIT").ok, "WAIT runs field repair")
        assertTrue(Commands.execute(st, "AUX").ok, "AUX discharges reserve")
        st.player.sx, st.player.sy = 2, 2
        assertTrue(Commands.execute(st, "DOCK").ok, "DOCK docks adjacent to outpost")
        assertTrue(Commands.execute(st, "W 5 4 4").ok and st.player.qx == 5, "W 5 4 4 performs FTL jump")
    end)

    -- 11. Full JSON serialization round-trip
    runCase("Storage Encode/Decode Mid-Mission State Round-Trip", function()
        local st = Engine.newGame("commander", 13579)
        Engine.jumpFTL(st, 3, 4, 6)
        Engine.toggleShields(st, true)
        Engine.setRepairPriority(st, "beams")

        local encoded = Storage.encode(st)
        local decoded, err = Storage.decode(encoded)
        assertTrue(decoded ~= nil, "Decode error: " .. tostring(err))
        assertEq(decoded.seed, st.seed, "Seed preserved")
        assertEq(decoded.rngState, st.rngState, "RNG state preserved")
        assertEq(decoded.difficulty, st.difficulty, "Difficulty preserved")
        assertEq(decoded.cycle, st.cycle, "Cycle preserved")
        assertEq(decoded.player.qx, st.player.qx, "Player qx preserved")
        assertEq(decoded.player.shieldsUp, st.player.shieldsUp, "Shield state preserved")
        assertEq(decoded.player.prioritySystem, "beams", "Repair priority preserved")
        assertEq(Galaxy.countTotalHostiles(decoded.galaxy), Galaxy.countTotalHostiles(st.galaxy), "Hostile count preserved")
        assertEq(#decoded.galaxy.quadrants[3][4].entities or #decoded.galaxy.quadrants[4][3].entities,
                 #st.galaxy.quadrants[3][4].entities or #st.galaxy.quadrants[4][3].entities, "Entities preserved")
    end)

    -- 12. Victory & Defeat trigger conditions
    runCase("Victory & Defeat Trigger Conditions", function()
        local stWin = Engine.newGame("ensign", 11111)
        for qy = 1, 8 do
            for qx = 1, 8 do
                local q = Galaxy.getQuad(stWin.galaxy, qx, qy)
                for i = #q.entities, 1, -1 do
                    if q.entities[i].kind == "enemy" then
                        table.remove(q.entities, i)
                    end
                end
            end
        end
        local evW = {}
        Engine.evaluateEndConditions(stWin, evW)
        assertEq(stWin.status, "victory", "Clearing all hostiles triggers victory")

        local stHull = Engine.newGame("ensign", 22222)
        stHull.player.hull = 0
        Engine.evaluateEndConditions(stHull, {})
        assertEq(stHull.status, "defeat", "0 hull triggers defeat")

        local stTime = Engine.newGame("ensign", 33333)
        stTime.cycle = stTime.maxCycles
        Engine.evaluateEndConditions(stTime, {})
        assertEq(stTime.status, "defeat", "Exceeding maxCycles with hostiles remaining triggers defeat")
    end)

    -- 13. Tactical Pause Freeze, Toggle & RTwP Save Round-Trip
    runCase("RTwP Tactical Pause Freeze, Toggle & Save Round-Trip", function()
        local st = Engine.newGame("captain", 141414)
        makeCleanQuad(st, 4, 4)
        assertTrue(st.paused == true, "New game starts in Tactical Pause")
        assertTrue(st.player.x ~= nil and st.player.y ~= nil, "Continuous x, y initialized")
        assertTrue(st.player.maxSpeed > 0 and st.player.turnRate > 0, "Kinematics limits initialized")

        local startX, startY, startHdg = st.player.x, st.player.y, st.player.heading
        Engine.setSpeedSetting(st, 0.7)
        Engine.plotPlayerCourse(st, startX + 200, startY + 120, math.pi * 0.5, 90)
        local stepPaused = Engine.updateRealtime(st, 0.5)
        assertTrue(not stepPaused.stepped, "Simulation does not step while paused")
        assertEq(st.simTime, 0, "simTime stays frozen while paused")
        assertEq(st.player.x, startX, "Player x unchanged while paused")
        assertEq(st.player.y, startY, "Player y unchanged while paused")
        assertEq(st.player.heading, startHdg, "Player heading unchanged while paused")

        local tog = Engine.togglePause(st)
        assertTrue(tog.ok and st.paused == false, "togglePause unpauses simulation")
        local stepLive = Engine.updateRealtime(st, 0.5)
        assertTrue(stepLive.stepped and st.simTime > 0, "Simulation advances when unpaused")
        assertTrue(st.player.speed > 0 and (st.player.x ~= startX or st.player.y ~= startY), "Ship accelerates and moves")

        local encoded = Storage.encode(st)
        local decoded, err = Storage.decode(encoded)
        assertTrue(decoded ~= nil, "Decode RTwP state failed: " .. tostring(err))
        assertEq(decoded.paused, st.paused, "paused persisted in save")
        assertTrue(math.abs(decoded.simTime - st.simTime) < 1e-4, "simTime persisted")
        assertTrue(math.abs(decoded.player.x - st.player.x) < 1e-4, "player.x persisted")
        assertTrue(math.abs(decoded.player.speed - st.player.speed) < 1e-4, "player.speed persisted")
        assertTrue(decoded.player.activePath ~= nil and #decoded.player.activePath.points == #st.player.activePath.points, "activePath persisted")
    end)

    -- 14. Heading & Turn-Rate Steering Bounds + Wrap-Around
    runCase("RTwP Heading & Turn-Rate Steering", function()
        local st = Engine.newGame("captain", 151515)
        makeCleanQuad(st, 4, 4)
        Engine.setPaused(st, false)
        st.player.heading = 0
        st.player.targetHeading = math.pi * 0.9

        local dt = 0.1
        local maxDelta = st.player.turnRate * dt
        Engine.updateRealtime(st, dt)
        local delta = Movement.angleDiff(0, st.player.heading)
        assertTrue(delta > 0 and delta <= maxDelta + 1e-4, "Heading turns positively within turnRate bound")

        -- Shortest-arc wrap across +/-pi boundary
        st.player.heading = 3.0
        st.player.targetHeading = -3.0
        for _ = 1, 3 do
            Engine.updateRealtime(st, 0.1)
        end
        local errAfter = math.abs(Movement.angleDiff(st.player.heading, -3.0))
        assertTrue(errAfter < 0.05, "Shortest-arc steering wraps cleanly across +/-pi")
    end)

    -- 15. Speed, Throttle & Acceleration/Deceleration Kinematics
    runCase("RTwP Speed, Throttle & Accel/Decel", function()
        local st = Engine.newGame("captain", 161616)
        makeCleanQuad(st, 4, 4)
        st.player.x, st.player.y = 150, 400
        st.player.heading = 0
        st.player.speed = 0
        Engine.setPaused(st, false)

        local cmdRes = Commands.execute(st, "SPEED FLANK")
        assertTrue(cmdRes.ok and st.player.speedSetting == 1.0, "SPEED FLANK sets throttle to 1.0")

        Engine.updateRealtime(st, 0.1)
        assertTrue(st.player.speed > 0 and st.player.speed <= st.player.accel * 0.1 + 1e-4, "Speed accelerates within accel limit")
        assertTrue(st.player.x > 150, "Ship advances along heading 0")

        for _ = 1, 90 do
            Engine.updateRealtime(st, 1 / 30)
        end
        assertTrue(math.abs(st.player.speed - st.player.maxSpeed) < 0.5, "Ship reaches maxSpeed at FLANK")

        local stopRes = Commands.execute(st, "SPEED STOP")
        assertTrue(stopRes.ok and st.player.speedSetting == 0, "SPEED STOP sets throttle to 0")
        local speedBefore = st.player.speed
        Engine.updateRealtime(st, 0.1)
        assertTrue(st.player.speed < speedBefore and (speedBefore - st.player.speed) <= st.player.decel * 0.1 + 1e-4, "Decelerates within decel limit")

        for _ = 1, 60 do
            Engine.updateRealtime(st, 1 / 30)
        end
        assertTrue(st.player.speed < 0.01, "Ship comes to complete controlled stop")
    end)

    -- 16. Cubic Bezier Vector Curve Generation, Following & CLI Commands
    runCase("RTwP Vector Curve Generation & Path Following", function()
        local st = Engine.newGame("captain", 171717)
        makeCleanQuad(st, 4, 4)
        st.player.x, st.player.y = 150, 350
        st.player.sx, st.player.sy = Movement.worldToSector(150, 350)
        st.player.heading = 0
        st.player.speed = 0

        local plotRes = Engine.plotPlayerCourse(st, 550, 250, math.pi * 0.5, 140)
        assertTrue(plotRes.ok and st.player.activePath ~= nil, "plotPlayerCourse commits activePath")
        local path = st.player.activePath
        assertEq(path.kind, "bezier", "Curve kind is bezier")
        assertTrue(#path.points >= 16, "Curve has sufficient sample points")
        assertTrue(st.player.speedSetting > 0, "Plotting curve sets non-zero cruise throttle")

        local _, _, sdx, sdy = Movement.evaluateBezier(path.p0, path.p1, path.p2, path.p3, 0)
        assertTrue(math.abs(Movement.angleDiff(math.atan2(sdy, sdx), 0)) < 0.05, "Start tangent matches ship heading")
        local _, _, edx, edy = Movement.evaluateBezier(path.p0, path.p1, path.p2, path.p3, 1)
        assertTrue(math.abs(Movement.angleDiff(math.atan2(edy, edx), math.pi * 0.5)) < 0.05, "End tangent matches exit heading")

        assertTrue(Commands.execute(st, "RESUME").ok and st.paused == false, "CLI RESUME unpauses")
        for _ = 1, 360 do
            Engine.updateRealtime(st, 1 / 30)
            if st.player.activePath == nil then
                break
            end
        end

        assertEq(st.player.activePath, nil, "Ship completes curve within 12 simulated seconds")
        local errDist = math.sqrt((st.player.x - 550) ^ 2 + (st.player.y - 250) ^ 2)
        assertTrue(errDist <= C.PLAYER_MOVEMENT.arrivalRadius + 4, "Ship arrives within arrival radius of destination")
        assertTrue(math.abs(Movement.angleDiff(st.player.heading, math.pi * 0.5)) < 0.1, "Final heading aligns with exit heading")
        assertTrue(st.player.speed < 0.1, "Ship comes to stop at destination")
        local esx, esy = Movement.worldToSector(st.player.x, st.player.y)
        assertEq(st.player.sx, esx, "sx synchronized with world x")
        assertEq(st.player.sy, esy, "sy synchronized with world y")

        assertTrue(Commands.execute(st, "PAUSE").ok and st.paused == true, "CLI PAUSE pauses")
        assertTrue(Commands.execute(st, "COURSE 6 3 90").ok and st.player.activePath ~= nil, "CLI COURSE plots curve")
        assertTrue(Commands.execute(st, "CLEAR").ok and st.player.activePath == nil, "CLI CLEAR removes activePath")
    end)

    -- 17. Turnaround Sprite Metadata Integrity (player + all 4 enemy classes)
    runCase("Turnaround Sprite Metadata Integrity", function()
        local ships = { "player", "raider", "cruiser", "dreadnought", "stalker" }
        for _, key in ipairs(ships) do
            local frames = TurnaroundData[key]
            assertTrue(type(frames) == "table" and #frames == 12, key .. " has 12 turnaround frames")
            for idx, frame in ipairs(frames) do
                assertTrue(type(frame.exhaustAngle) == "number" and frame.exhaustAngle == frame.exhaustAngle,
                    key .. " frame " .. idx .. " has finite exhaustAngle")
                assertTrue(type(frame.nozzles) == "table" and #frame.nozzles > 0,
                    key .. " frame " .. idx .. " has nozzles")
                for nIdx, nz in ipairs(frame.nozzles) do
                    assertTrue(type(nz.x) == "number" and nz.x == nz.x and nz.x >= 0 and nz.x <= 96,
                        key .. " frame " .. idx .. " nozzle " .. nIdx .. " valid x")
                    assertTrue(type(nz.y) == "number" and nz.y == nz.y and nz.y >= 0 and nz.y <= 96,
                        key .. " frame " .. idx .. " nozzle " .. nIdx .. " valid y")
                end
            end
        end
    end)

    -- 18. Phase 2 Target Selection, Cycling & Geometry
    runCase("RTwP Target Selection, Cycling & Geometry", function()
        local st = Engine.newGame("captain", 181818)
        local q = makeCleanQuad(st, 4, 4)
        st.player.x, st.player.y = 350, 350
        st.player.sx, st.player.sy = Movement.worldToSector(350, 350)
        st.player.heading = 0

        local e1 = { id = 8801, kind = "enemy", class = "raider", name = "Corsair Alpha", code = "RDR",
            x = 5, y = 4, shield = 160, maxShield = 160, hull = 180, maxHull = 180, minDmg = 10, maxDmg = 20, score = 120, cloaked = false }
        local e2 = { id = 8802, kind = "enemy", class = "cruiser", name = "Vanguard Beta", code = "CRS",
            x = 6, y = 2, shield = 300, maxShield = 300, hull = 340, maxHull = 340, minDmg = 10, maxDmg = 20, score = 240, cloaked = false }
        local eCloak = { id = 8803, kind = "enemy", class = "stalker", name = "Ghost", code = "STL",
            x = 5, y = 5, shield = 220, maxShield = 220, hull = 240, maxHull = 240, minDmg = 10, maxDmg = 20, score = 320, cloaked = true }
        q.entities = { e1, e2, eCloak }

        local cloakRes = Engine.setTarget(st, eCloak.id)
        assertTrue(not cloakRes.ok, "Cannot designate cloaked hostile")

        assertTrue(Engine.cycleTarget(st, 1).ok and st.player.targetId == e1.id, "First cycle selects nearest visible enemy")
        assertTrue(Engine.cycleTarget(st, 1).ok and st.player.targetId == e2.id, "Second cycle advances to second enemy")
        assertTrue(Engine.cycleTarget(st, 1).ok and st.player.targetId == e1.id, "Cycle wraps back to first enemy")
        assertTrue(Engine.cycleTarget(st, -1).ok and st.player.targetId == e2.id, "Reverse cycle steps backward cleanly")

        assertTrue(Engine.setTarget(st, e1.id).ok, "Direct target set works")
        local ws = Engine.getWeaponStatus(st)
        assertTrue(ws.primary ~= nil and ws.primary.entity.id == e1.id, "Status reports locked primary target")
        assertTrue(math.abs(ws.primary.geom.range - 100) < 1e-3, "Range computed cleanly (100 world u = 1 sector)")
        assertTrue(math.abs(ws.primary.geom.relBearingDeg) < 1e-3, "Relative bearing 0 deg straight ahead")
        assertTrue(ws.inBeamArc and ws.inTorpArc, "Dead-ahead target is in beam and torpedo arcs")

        assertTrue(Commands.execute(st, "TARGET 6 2").ok and st.player.targetId == e2.id, "CLI TARGET sx sy locks enemy at coords")
        assertTrue(Commands.execute(st, "WEAPONS").ok, "CLI WEAPONS prints status")
        assertTrue(Commands.execute(st, "ARCS OFF").ok and st.player.showFiringArcs == false, "CLI ARCS OFF hides cones")
        assertTrue(Commands.execute(st, "ARCS ON").ok and st.player.showFiringArcs == true, "CLI ARCS ON shows cones")
        assertTrue(Commands.execute(st, "TARGET CLEAR").ok and st.player.targetId == nil, "CLI TARGET CLEAR clears lock")
    end)

    -- 19. Phase 2 Firing Arc (180 deg Bow Cone), Range & Curve Coverage
    runCase("Firing Arc (180 deg Front Cone), Range & Curve Coverage", function()
        local bSpec = C.WEAPONS.beams
        local tSpec = C.WEAPONS.torpedoes
        assertTrue(math.abs(bSpec.arcWidth - math.pi) < 1e-6, "Beams use 180 deg front-facing arc")
        assertTrue(math.abs(tSpec.arcWidth - math.pi) < 1e-6, "Torpedoes use 180 deg front-facing arc")

        local sx, sy, hdg = 350, 350, 0
        local g0   = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + 200, sy, 0, bSpec.arcWidth, bSpec.range)
        local g85  = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + math.cos(math.rad(85)) * 200, sy + math.sin(math.rad(85)) * 200, 0, bSpec.arcWidth, bSpec.range)
        local gm85 = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + math.cos(math.rad(-85)) * 200, sy + math.sin(math.rad(-85)) * 200, 0, bSpec.arcWidth, bSpec.range)
        local g95  = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + math.cos(math.rad(95)) * 200, sy + math.sin(math.rad(95)) * 200, 0, bSpec.arcWidth, bSpec.range)
        local gm95 = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + math.cos(math.rad(-95)) * 200, sy + math.sin(math.rad(-95)) * 200, 0, bSpec.arcWidth, bSpec.range)
        local g180 = Combat.evaluateTargetGeometry(sx, sy, hdg, sx - 200, sy, 0, bSpec.arcWidth, bSpec.range)

        assertTrue(g0.inFiringArc and g85.inFiringArc and gm85.inFiringArc, "0 and +/-85 deg targets lie inside 180 deg bow arc")
        assertTrue((not g95.inArc) and (not gm95.inArc) and (not g180.inArc), "+/-95 and 180 deg targets lie outside 180 deg bow arc")

        local gBeamMax = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + 419, sy, 0, bSpec.arcWidth, bSpec.range)
        local gMidTorp = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + 480, sy, 0, bSpec.arcWidth, bSpec.range)
        local tMidTorp = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + 480, sy, 0, tSpec.arcWidth, tSpec.range)
        local tBeyond  = Combat.evaluateTargetGeometry(sx, sy, hdg, sx + 590, sy, 0, tSpec.arcWidth, tSpec.range)
        assertTrue(gBeamMax.inFiringArc and not gMidTorp.inRange, "Beam range limit enforced at 420 u")
        assertTrue(tMidTorp.inFiringArc and not tBeyond.inRange, "Torpedo range limit enforced at 560 u")

        local gFlipped = Combat.evaluateTargetGeometry(sx, sy, math.pi, sx - 200, sy, 0, bSpec.arcWidth, bSpec.range)
        assertTrue(gFlipped.inFiringArc, "Rotating ship heading 180 deg brings aft target into bow arc")

        -- Curve arc coverage evaluation
        local st = Engine.newGame("captain", 191919)
        local q = makeCleanQuad(st, 4, 4)
        local eAft = { id = 8901, kind = "enemy", class = "raider", name = "Pursuer", code = "RDR",
            x = 2, y = 4, shield = 160, maxShield = 160, hull = 180, maxHull = 180, minDmg = 10, maxDmg = 20, score = 120, cloaked = false }
        q.entities = { eAft }
        local curveWest = Movement.buildCurve(350, 350, 0, 280, 440, math.pi, 110)
        local covWest = Combat.evaluateCurveArcCoverage(curveWest, q, eAft.id)
        assertTrue(covWest.byEnemyId[eAft.id].inBeamAtEnd == true, "Turning West puts S(2,4) enemy into bow beam arc at destination")
        assertTrue(covWest.byEnemyId[eAft.id].inBeamAlongCurve == true, "Curve tracks mid-turn/end arc entry")

        local curveEast = Movement.buildCurve(350, 350, 0, 520, 350, 0, 110)
        local covEast = Combat.evaluateCurveArcCoverage(curveEast, q, eAft.id)
        assertTrue(covEast.byEnemyId[eAft.id].inBeamAtEnd == false, "Continuing East leaves S(2,4) enemy outside bow arc")
    end)

    -- 20. Phase 2 Weapon Charging, Tactical Pause Freeze & Save Round-Trip
    runCase("Weapon Charging, Pause Freeze & Save Round-Trip", function()
        local st = Engine.newGame("captain", 202020)
        local q = makeCleanQuad(st, 4, 4)
        st.player.x, st.player.y = 350, 350
        st.player.sx, st.player.sy = Movement.worldToSector(350, 350)
        local e1 = { id = 8911, kind = "enemy", class = "raider", name = "Target", code = "RDR",
            x = 7, y = 7, shield = 160, maxShield = 160, hull = 180, maxHull = 180, minDmg = 5, maxDmg = 10, score = 120, cloaked = false }
        q.entities = { e1 }

        assertEq(st.player.weapons.beams.charge, 0, "Beam charge starts at 0")
        assertEq(st.player.weapons.torpedoes.charge, 0, "Torpedo charge starts at 0")

        Engine.updateRealtime(st, 1.0)
        assertEq(st.player.weapons.beams.charge, 0, "Beam charge frozen while tactically paused")
        assertEq(st.player.weapons.torpedoes.charge, 0, "Torpedo charge frozen while tactically paused")

        Engine.setPaused(st, false)
        for _ = 1, 14 do
            Engine.updateRealtime(st, 0.1)
        end
        local healthyBeamChg = st.player.weapons.beams.charge
        local healthyTorpChg = st.player.weapons.torpedoes.charge
        assertTrue(math.abs(healthyBeamChg - (1.4 / C.WEAPONS.beams.chargeTime)) < 0.01, "Healthy beams charge linearly")
        assertTrue(math.abs(healthyTorpChg - (1.4 / C.WEAPONS.torpedoes.chargeTime)) < 0.01, "Healthy torpedoes charge linearly")

        -- Damaged weapon array charges slower
        st.player.weapons.beams.charge = 0
        st.player.systems.beams = 40
        for _ = 1, 14 do
            Engine.updateRealtime(st, 0.1)
        end
        assertTrue(st.player.weapons.beams.charge < healthyBeamChg, "Damaged Beam Array charges slower than 100%")

        -- Save/Load round-trip
        st.player.targetId = e1.id
        st.player.weapons.beams.mode = "spread"
        st.player.weapons.beams.autoFire = false
        st.player.showFiringArcs = false
        st.projectiles[#st.projectiles + 1] = {
            id = 99, kind = "torpedo", x = 380, y = 350, heading = 0, speed = 320,
            maxRange = 650, traveled = 30, targetId = e1.id, dmgMin = 260, dmgMax = 330, shieldBypass = 0.40,
        }
        local decoded, err = Storage.decode(Storage.encode(st))
        assertTrue(decoded ~= nil, "Decode combat state failed: " .. tostring(err))
        Engine.ensureRealtimeState(decoded)
        assertEq(decoded.player.targetId, e1.id, "targetId persisted")
        assertEq(decoded.player.weapons.beams.mode, "spread", "beam mode persisted")
        assertEq(decoded.player.weapons.beams.autoFire, false, "beam autoFire persisted")
        assertEq(decoded.player.showFiringArcs, false, "showFiringArcs persisted")
        assertEq(#decoded.projectiles, 1, "active projectile persisted")
    end)

    -- 21. Phase 2 Beam Auto-Fire: Focused vs. Spread Mode
    runCase("Beam Auto-Fire: Focused vs. Spread Mode", function()
        local st = Engine.newGame("captain", 212121)
        local q = makeCleanQuad(st, 4, 4)
        st.player.x, st.player.y = 250, 350
        st.player.sx, st.player.sy = Movement.worldToSector(250, 350)
        st.player.heading = 0
        st.player.shieldsUp = true
        st.player.shields = 800

        local e1 = { id = 8921, kind = "enemy", class = "cruiser", name = "Cruiser Fore", code = "CRS",
            x = 4, y = 4, shield = 300, maxShield = 300, hull = 340, maxHull = 340, minDmg = 5, maxDmg = 10, score = 240, cloaked = false }
        local e2 = { id = 8922, kind = "enemy", class = "cruiser", name = "Cruiser Flank", code = "CRS",
            x = 5, y = 3, shield = 300, maxShield = 300, hull = 340, maxHull = 340, minDmg = 5, maxDmg = 10, score = 240, cloaked = false }
        local eBack = { id = 8923, kind = "enemy", class = "raider", name = "Raider Aft", code = "RDR",
            x = 1, y = 4, shield = 160, maxShield = 160, hull = 180, maxHull = 180, minDmg = 5, maxDmg = 10, score = 120, cloaked = false }
        q.entities = { e1, e2, eBack }

        Commands.execute(st, "AUTOFIRE TORP OFF")
        Engine.setPaused(st, false)

        -- Focused on out-of-arc target behind player holds beam fire even when fully charged
        Engine.setTarget(st, eBack.id)
        for _ = 1, 30 do
            Engine.updateRealtime(st, 0.1)
        end
        assertEq(st.player.weapons.beams.charge, 1.0, "Beam charges to full while target is out of arc")
        assertEq(eBack.shield, eBack.maxShield, "Focused beam does NOT fire at out-of-arc target")
        assertEq(e1.shield, e1.maxShield, "Focused beam does NOT fire at undesignated targets")

        -- Lock in-arc e1 -> Focused beam fires immediately on next tick
        Engine.setTarget(st, e1.id)
        local energyBefore = st.player.energy
        local resFocus = Engine.updateRealtime(st, 0.05)
        assertTrue(e1.shield < e1.maxShield, "Focused beam damages designated in-arc primary target")
        assertEq(e2.shield, e2.maxShield, "Focused mode leaves secondary in-arc enemy untouched")
        assertEq(eBack.shield, eBack.maxShield, "Aft enemy remains untouched")
        assertTrue(st.player.energy <= energyBefore - C.WEAPONS.beams.energyCost, "Focused shot deducts beam energy")
        assertTrue(st.player.beamHeat > 0, "Focused shot builds beam heat")
        assertTrue(st.player.weapons.beams.charge < 0.2, "Focused shot resets beam charge")

        local beamEvents = 0
        for _, ev in ipairs(resFocus.events) do
            if ev.kind == "beam" and ev.color ~= "crimson" then beamEvents = beamEvents + 1 end
        end
        assertEq(beamEvents, 1, "Focused volley emits 1 player beam event")

        -- Switch to Spread mode & verify multi-target auto-fire across both in-arc hostiles
        local e1ShdBefore = e1.shield
        Commands.execute(st, "BEAMMODE SPREAD")
        st.player.weapons.beams.charge = 1.0
        local resSpread = Engine.updateRealtime(st, 0.05)
        assertTrue(e1.shield < e1ShdBefore, "Spread mode hits designated primary target")
        assertTrue(e2.shield < e2.maxShield, "Spread mode also hits secondary in-arc target")
        assertEq(eBack.shield, eBack.maxShield, "Spread mode still respects 180 deg bow arc (aft untouched)")

        local spreadBeams = 0
        for _, ev in ipairs(resSpread.events) do
            if ev.kind == "beam" and ev.color == "emerald" then spreadBeams = spreadBeams + 1 end
        end
        assertEq(spreadBeams, 2, "Spread volley emits 2 emerald beam events")
    end)

    -- 22. Phase 2 Torpedo Auto-Fire, Projectile Travel, Impact & Outpost Interlock
    runCase("Torpedo Auto-Fire, Projectile Travel, Impact & Interlock", function()
        local st = Engine.newGame("captain", 222222)
        local q = makeCleanQuad(st, 4, 4)
        st.player.x, st.player.y = 150, 350
        st.player.sx, st.player.sy = Movement.worldToSector(150, 350)
        st.player.heading = 0

        local e1 = { id = 8931, kind = "enemy", class = "dreadnought", name = "Dreadnought Target", code = "DRD",
            x = 6, y = 4, shield = 450, maxShield = 520, hull = 450, maxHull = 580, minDmg = 5, maxDmg = 10, score = 480, cloaked = false }
        q.entities = { e1 }

        Commands.execute(st, "AUTOFIRE BEAMS OFF")
        Engine.setTarget(st, e1.id)

        -- Auto-fire OFF holds torpedo launch
        Commands.execute(st, "TORP AUTO OFF")
        st.player.weapons.torpedoes.charge = 1.0
        local startAmmo = st.player.torpedoes
        Engine.setPaused(st, false)
        Engine.updateRealtime(st, 0.05)
        assertEq(#st.projectiles, 0, "Manual mode holds torpedo launch")
        assertEq(st.player.torpedoes, startAmmo, "Ammo unchanged when auto-fire off")

        -- Auto-fire ON spawns projectile on unpaused tick
        Commands.execute(st, "TORP AUTO ON")
        local launchRes = Engine.updateRealtime(st, 0.05)
        assertEq(#st.projectiles, 1, "Torpedo auto-fire spawns active projectile")
        assertEq(st.player.torpedoes, startAmmo - 1, "Torpedo ammo decremented")
        assertEq(st.player.weapons.torpedoes.charge, 0, "Torpedo charge reset on launch")
        local sawSound = false
        for _, ev in ipairs(launchRes.events) do
            if ev.kind == "sound" and ev.sound == "torpedo" then sawSound = true end
        end
        assertTrue(sawSound, "Torpedo launch emits sound event")

        -- Tactical pause freezes projectile mid-flight
        local midX = st.projectiles[1].x
        Engine.setPaused(st, true)
        Engine.updateRealtime(st, 0.5)
        assertEq(st.projectiles[1].x, midX, "Projectile freezes during tactical pause")

        -- Resume and advance until projectile strikes e1
        Engine.setPaused(st, false)
        for _ = 1, 40 do
            Engine.updateRealtime(st, 0.05)
            if #st.projectiles == 0 then break end
        end
        assertEq(#st.projectiles, 0, "Projectile despawns on impact")
        assertTrue(e1.hull < 450, "Auto-fired torpedo pierces 40% shields and damages hull")
        assertTrue(e1.shield < 450 and e1.shield > 0, "Enemy shields absorb remaining portion cleanly")

        -- Friendly Outpost in line-of-fire engages interlock
        q.entities[#q.entities + 1] = { id = 8932, kind = "outpost", name = "Shield Base", x = 4, y = 4, hp = 500, maxHp = 500 }
        st.player.weapons.torpedoes.charge = 1.0
        local ammoPreInterlock = st.player.torpedoes
        local ws = Engine.getWeaponStatus(st)
        assertEq(ws.torpedoes.statusText, "INTERLOCK", "Weapon status flags INTERLOCK when outpost blocks line of fire")
        Engine.updateRealtime(st, 0.1)
        assertEq(#st.projectiles, 0, "Friendly Outpost interlock prevents torpedo auto-fire")
        assertEq(st.player.torpedoes, ammoPreInterlock, "Ammo preserved during interlock")
    end)

    print(string.format("\nUNIT TEST SUMMARY: %d passed, %d failed", passed, failed))
    if failed == 0 then
        print("ALL TESTS PASSED")
        return true
    else
        return false
    end
end

-- ======================== GRAPHICAL SMOKE RUNNER ========================

function Tests.createSmokeRunner(ctx)
    local frame = 0
    local finished = false
    local smokeState = nil

    return {
        isFinished = function()
            return finished
        end,
        step = function(dt)
            frame = frame + 1
            if frame == 1 then
                ctx.Title.enter()
                ctx.setScreen("title")
            elseif frame == 3 then
                smokeState = ctx.Engine.newGame("captain", 123456)
                ctx.Game.enter(smokeState)
                ctx.setScreen("game")
            elseif frame == 4 then
                local q = ctx.Engine.currentQuad(smokeState)
                local testEnemy = {
                    id = 99001, kind = "enemy", class = "cruiser", name = "Smoke Cruiser", code = "CRS",
                    x = (smokeState.player.sx >= 7) and (smokeState.player.sx - 2) or (smokeState.player.sx + 2), y = smokeState.player.sy,
                    shield = 300, maxShield = 300, hull = 340, maxHull = 340,
                    minDmg = 10, maxDmg = 20, score = 240, cloaked = false,
                }
                q.entities[#q.entities + 1] = testEnemy
                ctx.Game.setMode("sublight")
                ctx.Engine.setTarget(smokeState, testEnemy.id)
                ctx.Engine.setBeamMode(smokeState, "spread")
                ctx.Engine.setShowFiringArcs(smokeState, true)
                ctx.Engine.plotPlayerCourse(smokeState, 540, 260, math.pi * 0.4, 120)
                smokeState.player.weapons.beams.charge = 1.0
                smokeState.player.weapons.torpedoes.charge = 1.0
                ctx.Engine.setPaused(smokeState, false)
            elseif frame == 5 then
                ctx.Engine.updateRealtime(smokeState, 0.25)
                ctx.Engine.setPaused(smokeState, true)
                ctx.Game.setMode("ftl")
                ctx.Animations.pushEvents({
                    { kind = "ftlJump" },
                    { kind = "sound", sound = "ftl" },
                })
            elseif frame == 6 then
                ctx.Game.setMode("beams")
                ctx.Animations.pushEvents({
                    { kind = "beam", x1 = 2, y1 = 2, x2 = 6, y2 = 5, color = "cyan" },
                    { kind = "shieldRipple", x = 6, y = 5, color = "amber" },
                    { kind = "sound", sound = "beam" },
                })
            elseif frame == 7 then
                ctx.Game.setMode("torpedo")
                ctx.Animations.pushEvents({
                    { kind = "torpedo", x1 = 2, y1 = 2, x2 = 6, y2 = 6 },
                    { kind = "explosion", x = 6, y = 6, size = 1.0 },
                    { kind = "sound", sound = "explosion" },
                })
            elseif frame == 8 then
                ctx.Game.setMode("probe")
                ctx.Overlays.open("help")
            elseif frame == 9 then
                smokeState.status = "victory"
                smokeState.endReason = "Smoke test sector secured."
                ctx.Overlays.open("debrief", smokeState)
            elseif frame >= 10 then
                finished = true
                return true
            end
            return false
        end,
    }
end

return Tests
