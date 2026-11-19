-- Pure-Lua JSON encoder/decoder and persistent save/scores/preferences storage

local Storage = {}

local SAVE_FILE = "savegame.json"
local SCORES_FILE = "scores.json"
local PREFS_FILE = "prefs.json"

local function isArray(tbl)
    local maxIdx = 0
    local count = 0
    for k, _ in pairs(tbl) do
        if type(k) == "number" and k >= 1 and math.floor(k) == k then
            if k > maxIdx then
                maxIdx = k
            end
            count = count + 1
        else
            return false, 0
        end
    end
    if count == 0 then
        return false, 0
    end
    -- Treat dense 1..n tables as JSON arrays
    if maxIdx == count then
        return true, count
    end
    return false, 0
end

local ESCAPE_MAP = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function encodeString(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(ch)
        if ESCAPE_MAP[ch] then
            return ESCAPE_MAP[ch]
        end
        return string.format("\\u%04x", string.byte(ch))
    end) .. '"'
end

local function encodeValue(val, buf, seen)
    local t = type(val)
    if val == nil then
        buf[#buf + 1] = "null"
    elseif t == "boolean" then
        buf[#buf + 1] = val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            buf[#buf + 1] = "null"
        else
            buf[#buf + 1] = tostring(val)
        end
    elseif t == "string" then
        buf[#buf + 1] = encodeString(val)
    elseif t == "table" then
        if seen[val] then
            error("Circular table reference in Storage.encode")
        end
        seen[val] = true
        local arr, len = isArray(val)
        if arr then
            buf[#buf + 1] = "["
            for i = 1, len do
                if i > 1 then
                    buf[#buf + 1] = ","
                end
                encodeValue(val[i], buf, seen)
            end
            buf[#buf + 1] = "]"
        else
            buf[#buf + 1] = "{"
            local keys = {}
            for k, v in pairs(val) do
                if v ~= nil and (type(k) == "string" or type(k) == "number") then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for i, k in ipairs(keys) do
                if i > 1 then
                    buf[#buf + 1] = ","
                end
                buf[#buf + 1] = encodeString(tostring(k))
                buf[#buf + 1] = ":"
                encodeValue(val[k], buf, seen)
            end
            buf[#buf + 1] = "}"
        end
        seen[val] = nil
    else
        error("Unsupported type in Storage.encode: " .. t)
    end
end

function Storage.encode(val)
    local buf = {}
    encodeValue(val, buf, {})
    return table.concat(buf)
end

-- JSON parser
local function parseError(str, pos, msg)
    error(string.format("JSON parse error at pos %d: %s", pos, msg))
end

local function skipWs(str, pos)
    local _, nextPos = str:find("^[ \t\r\n]*", pos)
    return (nextPos or (pos - 1)) + 1
end

local parseValue

local UNESCAPE = {
    ['"']  = '"',
    ['\\'] = '\\',
    ['/']  = '/',
    ['b']  = '\b',
    ['f']  = '\f',
    ['n']  = '\n',
    ['r']  = '\r',
    ['t']  = '\t',
}

local function utf8FromCodePoint(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 64),
            0x80 + (cp % 64)
        )
    else
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + (math.floor(cp / 64) % 64),
            0x80 + (cp % 64)
        )
    end
end

local function parseString(str, pos)
    pos = pos + 1 -- skip opening quote
    local out = {}
    local len = #str
    while pos <= len do
        local ch = str:sub(pos, pos)
        if ch == '"' then
            return table.concat(out), pos + 1
        elseif ch == "\\" then
            local esc = str:sub(pos + 1, pos + 1)
            if UNESCAPE[esc] then
                out[#out + 1] = UNESCAPE[esc]
                pos = pos + 2
            elseif esc == "u" then
                local hex = str:sub(pos + 2, pos + 5)
                local cp = tonumber(hex, 16)
                if not cp then
                    parseError(str, pos, "Invalid \\u escape")
                end
                out[#out + 1] = utf8FromCodePoint(cp)
                pos = pos + 6
            else
                parseError(str, pos, "Invalid escape sequence \\" .. esc)
            end
        else
            local nextSpecial = str:find('[\\"]', pos)
            if not nextSpecial then
                parseError(str, pos, "Unterminated string")
            end
            out[#out + 1] = str:sub(pos, nextSpecial - 1)
            pos = nextSpecial
        end
    end
    parseError(str, pos, "Unterminated string")
end

local function parseNumber(str, pos)
    local numStr = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    local val = tonumber(numStr)
    if not val then
        parseError(str, pos, "Invalid number")
    end
    return val, pos + #numStr
end

local function parseArray(str, pos)
    pos = skipWs(str, pos + 1)
    local arr = {}
    if str:sub(pos, pos) == "]" then
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = parseValue(str, pos)
        arr[#arr + 1] = val
        pos = skipWs(str, pos)
        local ch = str:sub(pos, pos)
        if ch == "]" then
            return arr, pos + 1
        elseif ch == "," then
            pos = skipWs(str, pos + 1)
        else
            parseError(str, pos, "Expected ',' or ']' in array")
        end
    end
end

local function parseObject(str, pos)
    pos = skipWs(str, pos + 1)
    local obj = {}
    if str:sub(pos, pos) == "}" then
        return obj, pos + 1
    end
    while true do
        if str:sub(pos, pos) ~= '"' then
            parseError(str, pos, "Expected string key in object")
        end
        local key
        key, pos = parseString(str, pos)
        pos = skipWs(str, pos)
        if str:sub(pos, pos) ~= ":" then
            parseError(str, pos, "Expected ':' after key")
        end
        pos = skipWs(str, pos + 1)
        local val
        val, pos = parseValue(str, pos)
        obj[key] = val
        pos = skipWs(str, pos)
        local ch = str:sub(pos, pos)
        if ch == "}" then
            return obj, pos + 1
        elseif ch == "," then
            pos = skipWs(str, pos + 1)
        else
            parseError(str, pos, "Expected ',' or '}' in object")
        end
    end
end

parseValue = function(str, pos)
    pos = skipWs(str, pos)
    local ch = str:sub(pos, pos)
    if ch == '"' then
        return parseString(str, pos)
    elseif ch == "{" then
        return parseObject(str, pos)
    elseif ch == "[" then
        return parseArray(str, pos)
    elseif ch == "-" or (ch >= "0" and ch <= "9") then
        return parseNumber(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    else
        parseError(str, pos, "Unexpected token '" .. ch .. "'")
    end
end

function Storage.decode(str)
    if type(str) ~= "string" or str == "" then
        return nil, "Empty input"
    end
    local ok, val, nextPos = pcall(parseValue, str, 1)
    if not ok then
        return nil, val
    end
    nextPos = skipWs(str, nextPos)
    if nextPos <= #str then
        return nil, "Trailing characters after JSON payload"
    end
    return val
end

local function writeJsonFile(filename, data)
    if not (love and love.filesystem) then
        return false, "love.filesystem unavailable"
    end
    local ok, encoded = pcall(Storage.encode, data)
    if not ok then
        return false, encoded
    end
    local success, err = love.filesystem.write(filename, encoded)
    return success, err
end

local function readJsonFile(filename)
    if not (love and love.filesystem and love.filesystem.getInfo) then
        return nil
    end
    if not love.filesystem.getInfo(filename) then
        return nil
    end
    local contents = love.filesystem.read(filename)
    if not contents then
        return nil
    end
    local data, err = Storage.decode(contents)
    if err then
        return nil
    end
    return data
end

function Storage.hasSave()
    return love and love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo(SAVE_FILE) ~= nil
end

function Storage.saveGame(state)
    return writeJsonFile(SAVE_FILE, state)
end

function Storage.loadGame()
    return readJsonFile(SAVE_FILE)
end

function Storage.deleteSave()
    if love and love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo(SAVE_FILE) then
        return love.filesystem.remove(SAVE_FILE)
    end
    return true
end

function Storage.loadScores()
    local list = readJsonFile(SCORES_FILE)
    if type(list) ~= "table" then
        return {}
    end
    return list
end

function Storage.addScore(entry)
    local scores = Storage.loadScores()
    scores[#scores + 1] = entry
    table.sort(scores, function(a, b)
        return (a.score or 0) > (b.score or 0)
    end)
    while #scores > 10 do
        table.remove(scores)
    end
    writeJsonFile(SCORES_FILE, scores)
    return scores
end

function Storage.defaultPrefs()
    return {
        muted = false,
        volume = 0.65,
        crt = true,
        fastAnim = false,
    }
end

function Storage.loadPrefs()
    local defaults = Storage.defaultPrefs()
    local saved = readJsonFile(PREFS_FILE)
    if type(saved) ~= "table" then
        return defaults
    end
    for k, v in pairs(defaults) do
        if saved[k] == nil then
            saved[k] = v
        end
    end
    return saved
end

function Storage.savePrefs(prefs)
    return writeJsonFile(PREFS_FILE, prefs)
end

return Storage
