-- ReTake's look: skate.'s own menus (ReSkate's hub, Animator Studio), with ReTake's teal where the game has its blue.
-- Hand-cut tiles, white "paper" for what is chosen, big ExtraBold capitals, keycaps for keys, a brushed line under
-- a title and a screen-print of dots in a corner. Sizes are given at 1080 lines; `k` scales them.
local S = {}

S.ACCENT = "#02f7da"
S.ACCENT_HOVER = "#7dfcec"
S.PAPER = "#f5f5f5"
S.INK = "#111111"
S.TEXT = "#f5f5f5"
S.SOFT = "#d2d2d6"
S.MUTED = "#96989e"
S.RED = "#ff5c5c"
S.STICKY = "#ecd76c"
S.GHOST = "#b9a7ff"
S.TILE = "#1a1a1af0"
S.TILE_GREY = "#2d2d2ff0"
S.TILE_LIGHT = "#3d3e42f0"
S.ROW_HOVER = "#343539f0"
S.PANEL = "#121213f7"
S.SCRIM = "#000000b0"

local function v(x, y)
    return vector.create(x, y, 0)
end
S.v = v

function S.inside(p, r)
    return p ~= nil and r ~= nil and p.x >= r.x0 and p.x <= r.x1 and p.y >= r.y0 and p.y <= r.y1
end

function S.hovered(mouse, r)
    return mouse ~= nil and S.inside(mouse.position, r)
end

-- A text style. On a light fill the game's shadow only smudges: `shadow` false there.
function S.font(size, colour, font, shadow)
    return {colour = colour, size = size, font = font or "bold", shadow = shadow == true}
end

-- The same text, the same tile edge: a tile keeps its cut from frame to frame.
function S.seed(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + string.byte(text, i)) % 4093 end
    return h + 1
end

function S.tile(d, r, colour, seed, k)
    d:rough_rect(v(r.x0, r.y0), v(r.x1, r.y1), {colour = colour, seed = seed or 1, scale = k or 1})
end

function S.centred(d, text, style, x, y)
    local m = d:measure(text, style)
    d:text(v(x - m.x / 2, y - m.y / 2), text, style)
    return m
end

-- The game's screen-print: dots 7 pixels apart.
function S.dots(d, x, y, columns, rows, colour)
    d:halftone(v(x, y), columns, rows, {colour = colour})
end

-- A window: its tile with a shadow, dots in the top right corner.
function S.panel(d, r, k, seed)
    d:rect(v(r.x0 + 10 * k, r.y0 + 12 * k), v(r.x1 + 10 * k, r.y1 + 12 * k), {colour = "#00000066", fill = true})
    S.tile(d, r, S.PANEL, seed or 7, k)
    -- Printed over the corner, half off the tile.
    S.dots(d, r.x1 - 96 * k, r.y0 - 16 * k, 18, 5, "#02f7da55")
end

-- The screen dimmed under a window.
function S.scrim(d, w, h)
    d:rect(v(0, 0), v(w, h), {colour = S.SCRIM, fill = true})
end

-- A window's title: "ReTake" in marker over the name in capitals, a brushed teal line under it. Its height.
function S.title(d, x, y, text, k, kicker)
    local ks = S.font(17, S.ACCENT, "title")
    local top = y
    if kicker ~= false then
        d:text(v(x + 2 * k, y), kicker or "ReTake", ks)
        top += 22 * k
    end
    local ts = S.font(32, S.TEXT, "heading", true)
    local label = string.upper(text)
    local m = d:measure(label, ts)
    d:text(v(x, top), label, ts)
    local under = top + m.y + 4 * k
    S.tile(d, {x0 = x, x1 = x + math.min(m.x, 120 * k), y0 = under, y1 = under + 6 * k}, S.ACCENT, S.seed(label), k * 0.5)
    return under + 6 * k - y
end

-- A key and what it does, like the game's "Esc Back": a white cap, then the words. Its width.
function S.keycap(d, x, y, key, label, k)
    local cs = S.font(12, S.INK, "bold")
    local c = d:measure(key, cs)
    local h = 22 * k
    d:rect(v(x, y), v(x + c.x + 14 * k, y + h), {colour = S.PAPER, fill = true, rounding = 3 * k})
    d:text(v(x + 7 * k, y + h / 2 - c.y / 2), key, cs)
    if not label or label == "" then return c.x + 14 * k end
    local ls = S.font(14, S.SOFT, "bold", true)
    local l = d:measure(label, ls)
    d:text(v(x + c.x + 22 * k, y + h / 2 - l.y / 2), label, ls)
    return c.x + 22 * k + l.x
end

-- How wide keycaps are, to place them from the right.
function S.keycap_width(d, key, label, k)
    local c = d:measure(key, S.font(12, S.INK, "bold"))
    if not label or label == "" then return c.x + 14 * k end
    return c.x + 22 * k + d:measure(label, S.font(14, S.SOFT, "bold", true)).x
end

-- A button. kind: "tile" (the default), "primary", "danger", "armed" (a "Sure?"), "quiet".
-- o: {kind=, mouse=, off=, k=, size=, icon=function(d, x, y, colour), key="Esc", upper=false}. Whether it is hovered.
function S.button(d, r, label, o)
    o = o or {}
    local k = o.k or 1
    local kind = o.kind or "tile"
    local hover = not o.off and S.hovered(o.mouse, r)
    local fill, ink = S.TILE_GREY, S.TEXT
    if o.off then fill, ink = "#2d2d2f80", "#ffffff40"
    elseif kind == "primary" then fill, ink = hover and S.PAPER or S.ACCENT, S.INK
    elseif kind == "armed" then fill, ink = S.RED, S.INK
    elseif kind == "danger" then fill, ink = hover and S.RED or S.TILE_GREY, hover and S.INK or S.RED
    elseif kind == "quiet" then fill, ink = hover and S.TILE_LIGHT or S.TILE, hover and S.TEXT or S.MUTED
    elseif hover then fill, ink = S.ACCENT, S.INK end
    S.tile(d, r, fill, S.seed(label), k)
    local light = ink == S.INK
    local text = o.upper == false and label or string.upper(label)
    local style = S.font(o.size or 16, ink, "bold", not light)
    local m = d:measure(text, style)
    local icon = o.icon and 26 * k or o.key and S.keycap_width(d, o.key, nil, k) + 10 * k or 0
    local x = (r.x0 + r.x1) / 2 - (m.x + icon) / 2
    local cy = (r.y0 + r.y1) / 2
    if o.icon then o.icon(d, x + 9 * k, cy, ink)
    elseif o.key then S.keycap(d, x, cy - 11 * k, o.key, nil, k) end
    d:text(v(x + icon, cy - m.y / 2), text, style)
    return hover
end

-- A setting, the game's way: its name on the left, what it is now on the right in teal.
function S.setting(d, r, name, value, o)
    o = o or {}
    local k = o.k or 1
    local hover = S.hovered(o.mouse, r)
    S.tile(d, r, hover and S.TILE_LIGHT or S.TILE_GREY, S.seed(name), k)
    local cy = (r.y0 + r.y1) / 2
    local ns = S.font(14, hover and S.TEXT or S.MUTED, "body", true)
    local vs = S.font(17, o.value_colour or (hover and S.TEXT or S.ACCENT), "bold", true)
    local n, m = d:measure(name, ns), d:measure(value, vs)
    local inset = 14 * k
    if n.x + m.x + 2 * inset + 10 * k > r.x1 - r.x0 then inset = 8 * k end
    d:text(v(r.x0 + inset, cy - n.y / 2), name, ns)
    d:text(v(r.x1 - inset - m.x, cy - m.y / 2), value, vs)
    return hover
end

-- A row of a list: a tile, lighter under the mouse, a teal edge on its left then.
function S.row(d, r, hover, seed, k)
    S.tile(d, r, hover and S.ROW_HOVER or S.TILE, seed, k)
    if hover then S.tile(d, {x0 = r.x0, x1 = r.x0 + 5 * k, y0 = r.y0 + 6 * k, y1 = r.y1 - 6 * k}, S.ACCENT, seed + 1, k * 0.4) end
end

-- A small tag: "PAUSED" on a sticky note, a version in teal.
function S.tag(d, x, y, text, k, fill, ink)
    local style = S.font(12, ink or S.INK, "bold")
    local m = d:measure(text, style)
    local r = {x0 = x, x1 = x + m.x + 16 * k, y0 = y, y1 = y + 22 * k}
    S.tile(d, r, fill or S.STICKY, S.seed(text), k * 0.5)
    d:text(v(x + 8 * k, y + 11 * k - m.y / 2), text, style)
    return r.x1 - r.x0
end

-- A note under a list: teal, or red for what went wrong.
function S.note(d, x, y, text, k, bad)
    local style = S.font(15, bad and S.RED or S.ACCENT, "body", true)
    if bad then
        d:circle(v(x + 7 * k, y + 9 * k), 7 * k, {colour = S.RED, fill = true})
        d:text(v(x + 5.5 * k, y + 1 * k), "!", S.font(12, S.INK, "bold"))
        x += 20 * k
    end
    d:text(v(x, y), text, style)
end

return S
