-- Procedural retro-modern synth audio engine (safe under headless mode)

local Sound = {}

local SAMPLE_RATE = 44100
local TWO_PI = math.pi * 2

local sources = {}
local muted = false
local masterVolume = 0.65
local initialized = false

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function makeBuffer(duration, fn)
    local count = math.max(1, math.floor(duration * SAMPLE_RATE))
    local sd = love.sound.newSoundData(count, SAMPLE_RATE, 16, 1)
    for i = 0, count - 1 do
        local t = i / SAMPLE_RATE
        local s = fn(t, duration, i)
        sd:setSample(i, clamp(s, -0.98, 0.98))
    end
    return love.audio.newSource(sd, "static")
end

-- Simple deterministic pseudo-noise for explosions
local function noiseAt(i)
    local x = math.sin(i * 12.9898 + 78.233) * 43758.5453
    return (x - math.floor(x)) * 2 - 1
end

local function buildSounds()
    -- Soft tactile console chirp
    sources.click = makeBuffer(0.045, function(t, dur)
        local env = (1 - t / dur) ^ 2
        local freq = 1180 + (t / dur) * 260
        return math.sin(TWO_PI * freq * t) * 0.25 * env
    end)

    -- Modulated beam laser sweep
    sources.beam = makeBuffer(0.28, function(t, dur)
        local u = t / dur
        local env = math.sin(math.min(1, u * 6) * math.pi * 0.5) * ((1 - u) ^ 0.7)
        local freq = 720 - 380 * u + math.sin(TWO_PI * 38 * t) * 65
        local w1 = math.sin(TWO_PI * freq * t)
        local w2 = math.sin(TWO_PI * freq * 1.5 * t) * 0.4
        return (w1 + w2) * 0.30 * env
    end)

    -- Descending plasma launch pulse
    sources.torpedo = makeBuffer(0.24, function(t, dur)
        local u = t / dur
        local env = (1 - u) ^ 1.4
        local freq = 960 * (0.28 ^ u) + 90
        local saw = 2 * ((t * freq) % 1) - 1
        return (math.sin(TWO_PI * freq * t) * 0.65 + saw * 0.35) * 0.32 * env
    end)

    -- Filtered noise burst + sub thump
    sources.explosion = makeBuffer(0.48, function(t, dur, idx)
        local u = t / dur
        local env = (1 - u) ^ 1.6
        local n = noiseAt(idx) * 0.65 + noiseAt(math.floor(idx / 3)) * 0.35
        local sub = math.sin(TWO_PI * (110 - 75 * u) * t) * 0.55
        return (n * 0.6 + sub) * 0.48 * env
    end)

    -- Deep resonant boom + crackle
    sources.supernova = makeBuffer(0.85, function(t, dur, idx)
        local u = t / dur
        local env = math.sin(math.min(1, u * 8) * math.pi * 0.5) * ((1 - u) ^ 1.2)
        local n = noiseAt(math.floor(idx / 2))
        local rumble = math.sin(TWO_PI * (78 - 44 * u) * t) + math.sin(TWO_PI * 42 * t) * 0.5
        return (n * 0.48 + rumble * 0.45) * 0.52 * env
    end)

    -- Metallic harmonic shield shimmer
    sources.shieldHit = makeBuffer(0.22, function(t, dur)
        local u = t / dur
        local env = (1 - u) ^ 1.5
        local s1 = math.sin(TWO_PI * (520 + 210 * math.sin(TWO_PI * 24 * t)) * t)
        local s2 = math.sin(TWO_PI * 840 * t) * 0.45
        return (s1 + s2) * 0.28 * env
    end)

    -- Low hull warning thud
    sources.hullHit = makeBuffer(0.26, function(t, dur, idx)
        local u = t / dur
        local env = (1 - u) ^ 1.8
        local thud = math.sin(TWO_PI * (145 - 85 * u) * t)
        local crunch = noiseAt(idx) * 0.35 * ((1 - u) ^ 3)
        return (thud * 0.75 + crunch) * 0.46 * env
    end)

    -- Rising sci-fi hyperdrive whoosh
    sources.ftl = makeBuffer(0.55, function(t, dur, idx)
        local u = t / dur
        local env = math.sin(u * math.pi)
        local freq = 180 + 780 * (u ^ 1.7)
        local tone = math.sin(TWO_PI * freq * t) * 0.5 + math.sin(TWO_PI * freq * 0.5 * t) * 0.35
        local air = noiseAt(math.floor(idx / 4)) * 0.18
        return (tone + air) * 0.38 * env
    end)

    -- Short soft impulse thruster hum
    sources.thruster = makeBuffer(0.14, function(t, dur, idx)
        local u = t / dur
        local env = math.sin(u * math.pi)
        local hum = math.sin(TWO_PI * (190 + 60 * u) * t)
        local hiss = noiseAt(math.floor(idx / 3)) * 0.22
        return (hum * 0.55 + hiss) * 0.22 * env
    end)

    -- Warm ascending 3-note chime
    sources.dock = makeBuffer(0.45, function(t, dur)
        local notes = { 440, 554.37, 659.25 }
        local seg = math.min(3, math.floor(t / 0.14) + 1)
        local lt = t - (seg - 1) * 0.14
        local env = math.exp(-lt * 8) * (1 - t / dur * 0.3)
        local f = notes[seg]
        return (math.sin(TWO_PI * f * t) + math.sin(TWO_PI * f * 2 * t) * 0.25) * 0.28 * env
    end)

    -- Sonar-like dual ping
    sources.scan = makeBuffer(0.34, function(t, dur)
        local ping1 = math.exp(-t * 14) * math.sin(TWO_PI * 1046.5 * t)
        local ping2 = 0
        if t > 0.13 then
            ping2 = math.exp(-(t - 0.13) * 12) * math.sin(TWO_PI * 1318.5 * (t - 0.13))
        end
        return (ping1 + ping2) * 0.28
    end)

    -- Subtle two-tone alert pulse
    sources.alert = makeBuffer(0.32, function(t)
        local freq = (t < 0.16) and 680 or 510
        local lt = t % 0.16
        local env = math.sin(math.min(1, lt / 0.02) * math.pi * 0.5) * math.exp(-lt * 6)
        return math.sin(TWO_PI * freq * t) * 0.26 * env
    end)

    -- Clean mechanical repair tick-chime
    sources.repair = makeBuffer(0.24, function(t)
        local f1 = (t < 0.11) and 587.33 or 880.0
        local lt = (t < 0.11) and t or (t - 0.11)
        local env = math.exp(-lt * 16)
        return math.sin(TWO_PI * f1 * t) * 0.26 * env
    end)

    -- Short triumphant arpeggio
    sources.victory = makeBuffer(0.75, function(t, dur)
        local notes = { 523.25, 659.25, 783.99, 1046.5 }
        local idx = math.min(4, math.floor(t / 0.15) + 1)
        local lt = t - (idx - 1) * 0.15
        local env = math.exp(-lt * 5.5) * (1 - (t / dur) * 0.2)
        local f = notes[idx]
        return (math.sin(TWO_PI * f * t) + math.sin(TWO_PI * f * 1.5 * t) * 0.2) * 0.30 * env
    end)

    -- Somber descending chord
    sources.defeat = makeBuffer(0.80, function(t, dur)
        local u = t / dur
        local env = (1 - u) ^ 1.2
        local notes = { 329.63, 293.66, 246.94, 196.0 }
        local idx = math.min(4, math.floor(t / 0.18) + 1)
        local f = notes[idx]
        return (math.sin(TWO_PI * f * t) + math.sin(TWO_PI * (f * 0.5) * t) * 0.5) * 0.28 * env
    end)
end

function Sound.init(prefs)
    if prefs then
        muted = prefs.muted == true
        masterVolume = clamp(prefs.volume or 0.65, 0, 1)
    end
    if initialized then
        return
    end
    if not (love and love.audio and love.sound) then
        return
    end
    local ok = pcall(buildSounds)
    if ok then
        initialized = true
    end
end

function Sound.play(name, volumeScale)
    if muted or not initialized then
        return
    end
    local src = sources[name]
    if not src then
        return
    end
    pcall(function()
        local inst = src:clone()
        inst:setVolume(clamp(masterVolume * (volumeScale or 1.0), 0, 1))
        inst:play()
    end)
end

function Sound.setMuted(m)
    muted = m == true
end

function Sound.isMuted()
    return muted
end

function Sound.toggleMute()
    muted = not muted
    return muted
end

function Sound.setVolume(v)
    masterVolume = clamp(tonumber(v) or 0.65, 0, 1)
end

function Sound.getVolume()
    return masterVolume
end

return Sound
