-- Starbridge Console UI widget library for Vanguard Command

local C = require("src.constants")

local UI = {}

UI.fonts = {}

function UI.initFonts()
    if not (love and love.graphics) then return end
    UI.fonts.xs = love.graphics.newFont(11)
    UI.fonts.sm = love.graphics.newFont(12)
    UI.fonts.md = love.graphics.newFont(14)
    UI.fonts.lg = love.graphics.newFont(18)
    UI.fonts.xl = love.graphics.newFont(26)
    UI.fonts.title = love.graphics.newFont(38)
end

function UI.pointInRect(px, py, r)
    if not r then return false end
    return px >= r.x and px <= (r.x + r.w) and py >= r.y and py <= (r.y + r.h)
end

function UI.drawPanel(rect, title, accentColor, time)
    local lg = love.graphics
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    local accent = accentColor or C.COLORS.borderBright

    -- Outer console housing
    lg.setColor(C.COLORS.panel)
    lg.rectangle("fill", x, y, w, h, 4, 4)

    -- Subtle inner VGA bevel
    lg.setColor(C.COLORS.bevelLight[1], C.COLORS.bevelLight[2], C.COLORS.bevelLight[3], 0.38)
    lg.line(x + 2, y + 1, x + w - 2, y + 1)
    lg.line(x + 1, y + 2, x + 1, y + h - 2)
    lg.setColor(C.COLORS.bevelDark[1], C.COLORS.bevelDark[2], C.COLORS.bevelDark[3], 0.9)
    lg.line(x + 2, y + h - 1, x + w - 2, y + h - 1)
    lg.line(x + w - 1, y + 2, x + w - 1, y + h - 2)

    -- Border
    lg.setColor(C.COLORS.border)
    lg.rectangle("line", x, y, w, h, 4, 4)

    -- Header strip
    if title and title ~= "" then
        local hh = 22
        lg.setColor(C.COLORS.panelHeader)
        lg.rectangle("fill", x + 1, y + 1, w - 2, hh, 3, 3)
        lg.setColor(accent[1], accent[2], accent[3], 0.9)
        lg.rectangle("fill", x + 6, y + 5, 4, hh - 10, 1, 1)
        lg.setColor(C.COLORS.border)
        lg.line(x + 1, y + hh + 1, x + w - 1, y + hh + 1)

        lg.setFont(UI.fonts.sm)
        lg.setColor(C.COLORS.text)
        lg.print(title, x + 15, y + 4)
    end
end

function UI.drawBar(x, y, w, h, ratio, color, label, valueText)
    local lg = love.graphics
    local r = math.max(0, math.min(1, ratio or 0))
    local col = color or C.COLORS.cyan

    lg.setColor(C.COLORS.bevelDark)
    lg.rectangle("fill", x, y, w, h, 2, 2)

    if r > 0 then
        lg.setColor(col[1], col[2], col[3], 0.85)
        lg.rectangle("fill", x + 1, y + 1, (w - 2) * r, h - 2, 2, 2)
        -- Top highlight glint
        lg.setColor(1, 1, 1, 0.20)
        lg.rectangle("fill", x + 1, y + 1, (w - 2) * r, math.max(1, (h - 2) * 0.35), 1, 1)
    end

    lg.setColor(C.COLORS.border)
    lg.rectangle("line", x, y, w, h, 2, 2)

    if label or valueText then
        lg.setFont(UI.fonts.xs)
        local ty = y + math.floor((h - UI.fonts.xs:getHeight()) * 0.5)
        if label then
            lg.setColor(0, 0, 0, 0.75)
            lg.print(label, x + 6, ty + 1)
            lg.setColor(C.COLORS.text)
            lg.print(label, x + 5, ty)
        end
        if valueText then
            lg.setColor(0, 0, 0, 0.75)
            lg.printf(valueText, x, ty + 1, w - 5, "right")
            lg.setColor(C.COLORS.text)
            lg.printf(valueText, x, ty, w - 6, "right")
        end
    end
end

function UI.drawButton(x, y, w, h, label, mx, my, opts)
    local lg = love.graphics
    opts = opts or {}
    local rect = { x = x, y = y, w = w, h = h }
    local hovered = (not opts.disabled) and UI.pointInRect(mx or -1, my or -1, rect)
    local accent = opts.accent or C.COLORS.cyan

    if opts.disabled then
        lg.setColor(0.08, 0.11, 0.17, 0.85)
    elseif opts.active then
        lg.setColor(accent[1] * 0.28, accent[2] * 0.28, accent[3] * 0.28, 0.95)
    elseif hovered then
        lg.setColor(0.14, 0.22, 0.36, 1)
    else
        lg.setColor(0.09, 0.14, 0.24, 1)
    end
    lg.rectangle("fill", x, y, w, h, 3, 3)

    -- Pulse outline if urgent
    local pulseAlpha = 1
    if opts.pulse and not opts.disabled then
        pulseAlpha = 0.55 + 0.45 * math.sin((opts.time or 0) * 6)
    end

    if opts.disabled then
        lg.setColor(C.COLORS.textMuted[1], C.COLORS.textMuted[2], C.COLORS.textMuted[3], 0.4)
    elseif opts.active or hovered or opts.pulse then
        lg.setColor(accent[1], accent[2], accent[3], pulseAlpha)
    else
        lg.setColor(C.COLORS.border)
    end
    lg.setLineWidth((opts.active or opts.pulse) and 1.6 or 1)
    lg.rectangle("line", x, y, w, h, 3, 3)
    lg.setLineWidth(1)

    local font = opts.font or UI.fonts.sm
    lg.setFont(font)
    local textCol = opts.disabled and C.COLORS.textMuted or (opts.active and accent or C.COLORS.text)
    lg.setColor(textCol)

    local ty = y + math.floor((h - font:getHeight()) * 0.5)
    if opts.hotkey then
        lg.setColor(opts.disabled and C.COLORS.textMuted or accent)
        lg.setFont(UI.fonts.xs)
        lg.print(opts.hotkey, x + 5, y + 3)
        lg.setFont(font)
        lg.setColor(textCol)
        lg.printf(label, x + 10, ty, w - 14, "center")
    else
        lg.printf(label, x + 4, ty, w - 8, "center")
    end

    return hovered, rect
end

function UI.drawTooltip(mx, my, lines, accent)
    if not lines or #lines == 0 then return end
    local lg = love.graphics
    local font = UI.fonts.xs
    lg.setFont(font)
    local lineH = font:getHeight() + 3
    local maxW = 0
    for _, ln in ipairs(lines) do
        local text = type(ln) == "table" and ln.text or ln
        local tw = font:getWidth(text)
        if tw > maxW then maxW = tw end
    end
    local pad = 8
    local w = maxW + pad * 2
    local h = #lines * lineH + pad * 2 - 2

    local tx = mx + 16
    local ty = my + 16
    if tx + w > C.VIRTUAL_W - 8 then
        tx = mx - w - 12
    end
    if ty + h > C.VIRTUAL_H - 8 then
        ty = my - h - 12
    end
    tx = math.max(8, tx)
    ty = math.max(8, ty)

    lg.setColor(0.03, 0.05, 0.10, 0.94)
    lg.rectangle("fill", tx, ty, w, h, 4, 4)
    lg.setColor(accent or C.COLORS.cyan)
    lg.rectangle("line", tx, ty, w, h, 4, 4)

    for i, ln in ipairs(lines) do
        local text = type(ln) == "table" and ln.text or ln
        local col = (type(ln) == "table" and ln.color) or (i == 1 and (accent or C.COLORS.cyan) or C.COLORS.text)
        lg.setColor(col)
        lg.print(text, tx + pad, ty + pad + (i - 1) * lineH)
    end
end

function UI.drawCRTOverlay(w, h)
    local lg = love.graphics
    lg.setColor(0, 0, 0, 0.10)
    for y = 0, h, 3 do
        lg.line(0, y, w, y)
    end
    -- Soft corner/edge vignette strips
    lg.setColor(0, 0, 0, 0.18)
    lg.rectangle("line", 1, 1, w - 2, h - 2)
    lg.setLineWidth(6)
    lg.setColor(0, 0, 0, 0.12)
    lg.rectangle("line", 3, 3, w - 6, h - 6)
    lg.setLineWidth(1)
end

return UI
