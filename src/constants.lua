-- Constants, palette, difficulty presets, ship subsystems, and 1280x720 console layout

local function rgb(r, g, b, a)
    return { r / 255, g / 255, b / 255, (a or 255) / 255 }
end

local C = {}

C.VIRTUAL_W = 1280
C.VIRTUAL_H = 720
C.GRID_SIZE = 8
C.TILE_SIZE = 64

C.SECTOR_WORLD_SCALE = 100
C.WORLD_SIZE = C.GRID_SIZE * C.SECTOR_WORLD_SCALE -- 800 x 800 continuous tactical arena
C.WORLD_MARGIN = 30

C.THROTTLE_STOPS = {
    { key = "stop",   label = "STOP",  ratio = 0.00 },
    { key = "slow",   label = "1/3",   ratio = 0.35 },
    { key = "cruise", label = "2/3",   ratio = 0.70 },
    { key = "flank",  label = "FLANK", ratio = 1.00 },
}

C.PLAYER_MOVEMENT = {
    maxSpeed = 140,       -- world units/sec (1.4 sectors/sec at Flank)
    accel = 95,           -- world units/sec^2
    decel = 135,          -- world units/sec^2
    turnRate = 1.85,      -- radians/sec (~106 deg/sec)
    arrivalRadius = 14,   -- world units to consider final waypoint reached
    waypointRadius = 24,  -- distance threshold to advance polyline cursor
    lookaheadDist = 42,   -- pure-pursuit lookahead distance along curve
    obstacleRadius = 34,  -- circular clearance radius around solid sector obstacles
    maxSubstep = 1 / 60,  -- deterministic fixed max substep for simulation stability
}

C.WEAPONS = {
    beams = {
        key = "beams",
        label = "BEAM ARRAY",
        short = "BEAM",
        arcCenter = 0,          -- radians relative to ship heading (0 = straight ahead)
        arcWidth = math.pi,     -- 180 deg front-facing firing cone (+/-90 deg)
        range = 420,            -- 4.2 sectors in continuous world coordinates
        chargeTime = 2.8,       -- seconds at 100% Beam Array health
        energyCost = 90,
        heatPerShot = 14,
        baseDamage = 120,
        spreadTotalMult = 1.35, -- total energy distributed across multiple spread targets
        maxSpreadTargets = 3,
        shieldBypass = 0.0,
    },
    torpedoes = {
        key = "torpedoes",
        label = "TORP TUBES",
        short = "TORP",
        arcCenter = 0,
        arcWidth = math.pi,     -- 180 deg front-facing firing cone (+/-90 deg)
        range = 560,            -- 5.6 sectors in continuous world coordinates
        chargeTime = 5.0,       -- seconds at 100% Missile Tubes health
        energyCost = 25,
        projectileSpeed = 320,  -- world units/sec
        hitRadius = 32,
        minDamage = 260,
        maxDamage = 330,
        shieldBypass = 0.40,
    },
}

C.COMBAT = {
    beamCoolRate = 12.0,        -- heat points dissipated per simulated second
    defaultShowArcs = true,
    targetPickRadiusPx = 28,
    interlockClearance = 42,    -- world units clearance around Outposts & Stars for auto-fire torpedoes
}

C.GAME_TITLE = "VANGUARD COMMAND"
C.GAME_SUBTITLE = "TACTICAL STARBRIDGE SIMULATOR"
C.DEFAULT_SHIP_NAME = "CSV VANGUARD"
C.FACTION_NAME = "Concord Fleet"

C.rgb = rgb

-- VGA-inspired high-contrast retro-modern color palette (0..1 float range)
C.COLORS = {
    bg          = rgb(8, 12, 22),
    panel       = rgb(15, 22, 38),
    panelAlt    = rgb(20, 30, 50),
    panelHeader = rgb(24, 38, 64),
    bevelLight  = rgb(64, 96, 148),
    bevelDark   = rgb(6, 9, 16),
    border      = rgb(44, 68, 108),
    borderBright= rgb(76, 178, 232),
    gridLine    = rgb(28, 46, 76),

    text        = rgb(224, 234, 248),
    textDim     = rgb(138, 158, 188),
    textMuted   = rgb(84, 102, 130),

    cyan        = rgb(62, 220, 248),
    cyanDim     = rgb(28, 112, 140),
    emerald     = rgb(56, 228, 136),
    emeraldDim  = rgb(24, 110, 68),
    amber       = rgb(252, 192, 56),
    amberDim    = rgb(136, 92, 24),
    crimson     = rgb(248, 72, 84),
    crimsonDim  = rgb(128, 30, 42),
    violet      = rgb(186, 108, 255),
    violetDim   = rgb(88, 44, 136),
    gold        = rgb(255, 224, 102),
    blue        = rgb(72, 140, 252),
    white       = rgb(255, 255, 255),
    black       = rgb(0, 0, 0),
}

C.DIFFICULTY_ORDER = { "ensign", "captain", "commander", "admiral" }

C.DIFFICULTIES = {
    ensign = {
        key = "ensign",
        label = "ENSIGN",
        desc = "Cadet patrol: light hostiles, generous energy, minimal station sieges.",
        enemies = { raider = 6, cruiser = 3, dreadnought = 1, stalker = 1 },
        outposts = 5,
        cycles = 42,
        maxHull = 1000,
        maxEnergy = 4500,
        maxShields = 1200,
        maxTorpedoes = 14,
        maxProbes = 6,
        auxReserve = 1200,
        siegeRate = 0.04,
        scoreMult = 0.85,
    },
    captain = {
        key = "captain",
        label = "CAPTAIN",
        desc = "Standard fleet alert: balanced sector threats and tactical logistics.",
        enemies = { raider = 7, cruiser = 5, dreadnought = 2, stalker = 2 },
        outposts = 4,
        cycles = 35,
        maxHull = 1000,
        maxEnergy = 4000,
        maxShields = 1000,
        maxTorpedoes = 12,
        maxProbes = 5,
        auxReserve = 1000,
        siegeRate = 0.08,
        scoreMult = 1.0,
    },
    commander = {
        key = "commander",
        label = "COMMANDER",
        desc = "Deep incursion: heavy armored patrols and active outpost sieges.",
        enemies = { raider = 8, cruiser = 6, dreadnought = 4, stalker = 3 },
        outposts = 4,
        cycles = 32,
        maxHull = 1000,
        maxEnergy = 3600,
        maxShields = 900,
        maxTorpedoes = 10,
        maxProbes = 4,
        auxReserve = 800,
        siegeRate = 0.12,
        scoreMult = 1.35,
    },
    admiral = {
        key = "admiral",
        label = "ADMIRAL",
        desc = "Sector crisis: relentless dreadnoughts, cloaked raiders, tight clock.",
        enemies = { raider = 9, cruiser = 7, dreadnought = 5, stalker = 4 },
        outposts = 3,
        cycles = 30,
        maxHull = 1000,
        maxEnergy = 3400,
        maxShields = 850,
        maxTorpedoes = 9,
        maxProbes = 4,
        auxReserve = 750,
        siegeRate = 0.16,
        scoreMult = 1.75,
    },
}

C.ENEMY_SPECS = {
    raider = {
        class = "raider",
        name = "Corsair Raider",
        code = "RDR",
        maxShield = 160,
        maxHull = 180,
        minDmg = 45,
        maxDmg = 95,
        score = 120,
        canCloak = false,
        canWarp = false,
        color = C.COLORS.amber,
        arcCenter = 0,
        arcWidth = math.pi,
        weaponRange = 380,
        turnRate = 1.05,
        chargeTime = 3.6,
        rtMinDmg = 20,
        rtMaxDmg = 36,
    },
    cruiser = {
        class = "cruiser",
        name = "Vanguard Cruiser",
        code = "CRS",
        maxShield = 300,
        maxHull = 340,
        minDmg = 85,
        maxDmg = 155,
        score = 240,
        canCloak = false,
        canWarp = false,
        color = C.COLORS.crimson,
        arcCenter = 0,
        arcWidth = math.pi,
        weaponRange = 440,
        turnRate = 0.65,
        chargeTime = 4.4,
        rtMinDmg = 34,
        rtMaxDmg = 54,
    },
    dreadnought = {
        class = "dreadnought",
        name = "Siege Dreadnought",
        code = "DRD",
        maxShield = 520,
        maxHull = 580,
        minDmg = 140,
        maxDmg = 240,
        score = 480,
        canCloak = false,
        canWarp = true,
        color = rgb(255, 92, 48),
        arcCenter = 0,
        arcWidth = math.pi,
        weaponRange = 500,
        turnRate = 0.38,
        chargeTime = 5.2,
        rtMinDmg = 52,
        rtMaxDmg = 82,
    },
    stalker = {
        class = "stalker",
        name = "Stealth Frigate",
        code = "STL",
        maxShield = 220,
        maxHull = 240,
        minDmg = 95,
        maxDmg = 175,
        score = 320,
        canCloak = true,
        canWarp = false,
        color = C.COLORS.violet,
        arcCenter = 0,
        arcWidth = math.pi,
        weaponRange = 400,
        turnRate = 1.15,
        chargeTime = 4.0,
        rtMinDmg = 38,
        rtMaxDmg = 62,
    },
}

C.SUBSYSTEMS = {
    { key = "ftl",         label = "FTL Drive",     short = "FTL" },
    { key = "thrusters",   label = "Thrusters",     short = "THR" },
    { key = "beams",       label = "Beam Array",    short = "BEM" },
    { key = "torpedoes",   label = "Missile Tubes", short = "TRP" },
    { key = "shields",     label = "Shield Grid",   short = "SHD" },
    { key = "sensors",     label = "Tactical Sens", short = "SNS" },
    { key = "scanner",     label = "Deep Scanner",  short = "SCN" },
    { key = "computer",    label = "Nav Computer",  short = "CMP" },
    { key = "lifesupport", label = "Life Support",  short = "LIF" },
}

-- Non-overlapping 1280x720 bridge layout rectangles
C.LAYOUT = {
    topBar      = { x = 0,   y = 0,   w = 1280, h = 44  },
    starmap     = { x = 12,  y = 54,  w = 280,  h = 280 },
    vitals      = { x = 12,  y = 344, w = 280,  h = 270 },
    viewport    = { x = 304, y = 54,  w = 560,  h = 560 },
    actionDeck  = { x = 876, y = 54,  w = 392,  h = 240 },
    engineering = { x = 876, y = 304, w = 392,  h = 310 },
    console     = { x = 12,  y = 624, w = 1256, h = 88  },
    consoleLog  = { x = 12,  y = 624, w = 928,  h = 88  },
    consoleHint = { x = 950, y = 624, w = 318,  h = 88  },
}

-- Inner tactical isometric grid inside viewport (centered in 560x560 viewport panel)
C.VIEWPORT_GRID = {
    x = C.LAYOUT.viewport.x + 8,
    y = C.LAYOUT.viewport.y + 30,
    w = C.LAYOUT.viewport.w - 16,
    h = C.LAYOUT.viewport.h - 38,
    size = 512,
    tile = 64,
    isoOriginX = C.LAYOUT.viewport.x + C.LAYOUT.viewport.w * 0.5,
    isoOriginY = C.LAYOUT.viewport.y + 134,
    isoHalfW = 32,
    isoHalfH = 20,
    spriteSize = 52,
}

C.STAR_COLORS = {
    rgb(255, 232, 120), -- G-type yellow
    rgb(160, 215, 255), -- O/B blue-white
    rgb(255, 160, 96),  -- K-type orange
    rgb(255, 110, 110), -- M-type red giant
}

C.PLANET_NAMES = {
    "Aethel", "Boreal", "Cygnus IV", "Draco Prime", "Erebus", "Fomalhaut",
    "Gliese", "Helios", "Icarus", "Jovian", "Kestrel", "Lyra",
    "Meridian", "Nereid", "Ophiuchus", "Polaris", "Quasar", "Rigel",
    "Solis", "Titanus", "Ursa", "Vega", "Weyland", "Xenos", "Yavin", "Zephyr",
}

C.OUTPOST_NAMES = {
    "Outpost Alpha", "Bastion Bravo", "Citadel Gamma", "Relay Delta",
    "Aegis Epsilon", "Forge Zeta",
}

return C
