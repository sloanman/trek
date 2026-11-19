-- Deterministic Park-Miller LCG PRNG safe for Lua 5.1 / LuaJIT

local RNG = {}
RNG.__index = RNG

local MODULUS = 2147483647 -- 2^31 - 1
local MULTIPLIER = 48271

local function normalizeSeed(seed)
    local s = math.floor(tonumber(seed) or 1)
    s = math.abs(s) % (MODULUS - 1)
    if s < 1 then
        s = 1
    end
    return s
end

function RNG.new(seed)
    local self = setmetatable({}, RNG)
    self.state = normalizeSeed(seed)
    return self
end

function RNG:getSeed()
    return self.state
end

function RNG:setSeed(seed)
    self.state = normalizeSeed(seed)
end

function RNG:next()
    -- Schrage's method avoids 53-bit float precision overflow cleanly in LuaJIT/5.1
    local q = 44488
    local r = 3399
    local hi = math.floor(self.state / q)
    local lo = self.state - hi * q
    local test = MULTIPLIER * lo - r * hi
    if test > 0 then
        self.state = test
    else
        self.state = test + MODULUS
    end
    return (self.state - 1) / (MODULUS - 1)
end

function RNG:int(minVal, maxVal)
    if not maxVal then
        maxVal = minVal
        minVal = 1
    end
    if maxVal <= minVal then
        return minVal
    end
    local span = maxVal - minVal + 1
    return minVal + math.floor(self:next() * span)
end

function RNG:float(minVal, maxVal)
    minVal = minVal or 0
    maxVal = maxVal or 1
    return minVal + self:next() * (maxVal - minVal)
end

function RNG:chance(p)
    return self:next() < p
end

function RNG:pick(list)
    if not list or #list == 0 then
        return nil
    end
    return list[self:int(1, #list)]
end

function RNG:shuffle(list)
    for i = #list, 2, -1 do
        local j = self:int(1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

return RNG
