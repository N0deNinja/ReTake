-- My lines: lines saved to keep, to go back to after the game has been closed. ReSkate.dll writes and reads a line's
-- every step (reskate.tas.line_export and line_import, in the background); beside each, a small file of what ReTake
-- keeps of it: its name, where it started, and where it was retaken and bailed. A loaded line is as one just
-- recorded: stopped at its end, the timeline open to any moment of it.
local U = require("util")
local R = require("report")
local L = require("line")
local LIB = {}

local SCREEN = "ReTake Lines"
local FOLDER = "lines"
local ROWS_SHOWN = 6
local STOP_MS = 3000
local VK_ESCAPE, VK_RETURN = 27, 13

local op = nil      -- {kind="save"|"load", id=, meta=, stage=, at=}: one at a time
local window = nil  -- {from_timeline=, left=, escape=, scroll=, confirm=, message=, error=}
local cache = nil   -- the saved lines, newest first, until something changes

local function path(id, ext)
    return FOLDER .. "/" .. id .. ext
end

local function clock_text(steps)
    local seconds = (steps or 0) / 60
    return string.format("%d:%05.2f", math.floor(seconds / 60), seconds % 60)
end

-- ---- maps ----------------------------------------------------------------------------------------------------
-- A line is a place on a map: loaded on another map, going back would teleport the skater to its start there, out of
-- bounds. So a line keeps its map, and loading one from another map travels there first, as the game's own travel
-- does (reskate.travel.go to one of its destinations): the world's root level with that map in it. Never
-- reskate.travel.load: it loads what it is given as the root, and a map (DingoLevel_MPR) loaded so crashed the game
-- (2026-11-08).
local TRAVEL_MS = 120000 -- a level load, at most
local SETTLE_MS = 2500   -- the skater there for this long before the line is loaded
-- The maps the game travels between, as its destinations name them, and as the level being played names them
-- (Engine/Game/World/location_travel.h, travel_level_asset).
local TRAVEL_MAPS = {
    bam = "levels/game/bam_levelroot/bam_levelroot",
    grom = "levels/game/dingolevel_isle_of_grom/dingolevel_isle_of_grom",
    mpr = "levels/game/dingolevel_mpr/dingolevel_mpr",
    stadium_1 = "levels/game/dingolevel_sdm/dingolevel_sdm_int_001/dingolevel_sdm_int_001",
}

local function norm(map)
    return string.lower(string.gsub(tostring(map or ""), "\\", "/"))
end

-- The map being played, as ReSkate names it ("levels/game/…"), or nil.
local function current_map()
    if not reskate.level or not reskate.level.current then return nil end
    local ok, level = pcall(reskate.level.current)
    return ok and level and level.name or nil
end

-- The game's travel destination for `map`, and its name; nil for a map it does not travel to (a custom park).
local function destination_of(map)
    if not reskate.travel or not reskate.travel.locations then return nil end
    local ok, places = pcall(reskate.travel.locations)
    if not ok or type(places) ~= "table" then return nil end
    local want = norm(map)
    for _, place in places do
        if TRAVEL_MAPS[place.map] == want then return place.id, place.name end
    end
    return nil
end

local function map_label(meta)
    return meta.map_name or (meta.map and string.match(meta.map, "([^/\\|]+)$")) or "another map"
end

local function say(text, kind)
    if window then
        if kind == "warn" then window.error, window.message = text, nil else window.message, window.error = text, nil end
    end
    R.toast(text, kind)
end

-- The saved lines, newest first: {id=, meta=}.
function LIB.list()
    if cache then return cache end
    local out = {}
    local ok, names = pcall(reskate.files.list, FOLDER)
    if ok and names then
        for _, name in names do
            local id = string.match(name, "([^/\\]+)%.json$")
            if id then
                local text = reskate.files.read(path(id, ".json"))
                local decoded, meta = pcall(reskate.json.decode, text or "")
                if decoded and type(meta) == "table" then table.insert(out, {id = id, meta = meta}) end
            end
        end
    end
    table.sort(out, function(a, b) return a.id > b.id end)
    cache = out
    return out
end

function LIB.busy()
    return op ~= nil
end

-- Saves the line as it is now, under `name` (else its date). In the background: a toast says when it is done.
function LIB.save(name)
    if not reskate.tas.line_export then return false, "this ReSkate.dll cannot save lines: install ReTake's DLL from this version" end
    if op then return false, "a line is being saved or loaded" end
    local info = L.info()
    if info.phase == "off" or info.length == 0 or not info.start then return false, "there is no line to save" end
    if L.busy() then return false, "wait for the countdown, then save" end
    local id = os.date("%Y%m%d-%H%M%S")
    for n = 2, 9 do
        if reskate.files.read(path(id, ".json")) == nil then break end
        id = os.date("%Y%m%d-%H%M%S") .. "-" .. n
    end
    local p = info.start.position
    local meta = {
        name = (name and name ~= "") and name or ("Line " .. os.date("%d %b, %H:%M")),
        saved = os.date("%Y-%m-%d %H:%M"),
        length = info.length,
        start = {x = p.x, y = p.y, z = p.z, heading = info.start.heading, on_board = info.start.on_board ~= false},
        joins = info.joins,
        bails = info.bails,
        retake = L.version,
        map = current_map(),
    }
    if meta.map then
        local _, name = destination_of(meta.map)
        meta.map_name = name
        if not name then
            -- For a report: where the game travels, beside what this map is called.
            local ok, places = false, nil
            if reskate.travel and reskate.travel.locations then ok, places = pcall(reskate.travel.locations) end
            local known = {}
            if ok and type(places) == "table" then
                for _, place in places do table.insert(known, tostring(place.id) .. "=" .. tostring(place.map)) end
            end
            R.line(string.format("[lines] the map %s is not one the game travels to: %s", tostring(meta.map), table.concat(known, ", ")))
        end
    end
    local ok, why = reskate.tas.line_export(path(id, ".line"))
    if not ok then return false, why end
    op = {kind = "save", id = id, meta = meta, at = U.now()}
    if window then window.message, window.error = "Saving…", nil end
    return true
end

-- Loads a saved line in place of the one there is: the line is stopped first, then ReSkate.dll reads it back.
function LIB.load(id)
    if not reskate.tas.line_import then return false, "this ReSkate.dll cannot load lines: install ReTake's DLL from this version" end
    if op then return false, "a line is being saved or loaded" end
    if U.in_session() then return false, "ReTake is offline only" end
    if L.busy() then return false, "wait for the countdown, then load" end
    local entry
    for _, e in LIB.list() do
        if e.id == id then entry = e end
    end
    if not entry then return false, "there is no such line" end
    if L.find_pad() == nil then return false, "connect a controller to load a line" end
    -- On another map: there first. A line saved before lines kept their map has none, and loads where you are.
    local here = current_map()
    local meta = entry.meta
    if meta.map and here and norm(meta.map) ~= norm(here) then
        local destination, name = destination_of(meta.map)
        if not destination then return false, "this line is on " .. map_label(meta) .. ", which ReTake can't travel to: go there, then load it" end
        L.suspend()
        op = {kind = "load", id = id, meta = meta, stage = "travel", destination = destination, at = U.now(), tries = 0}
        R.line(string.format("[lines] %q is on %s (%s), this is %s: travelling there", tostring(meta.name), tostring(name), tostring(meta.map), tostring(here)))
        if window then window.message, window.error = "Travelling to " .. (name or map_label(meta)) .. "…", nil end
        return true
    end
    L.suspend()
    op = {kind = "load", id = id, meta = meta, stage = "stopping", at = U.now()}
    if window then window.message, window.error = "Loading…", nil end
    return true
end

function LIB.delete(id)
    if op and op.id == id then return false, "it is being saved or loaded" end
    local ok1 = reskate.files.remove(path(id, ".json"))
    pcall(reskate.files.remove, path(id, ".line"))
    cache = nil
    if not ok1 then return false, "it could not be deleted" end
    R.line("[lines] deleted " .. id)
    return true
end

-- Once a tick: what is being saved or loaded, on.
local function op_tick(now)
    if not op then return end
    if op.kind == "save" then
        local status = reskate.tas.line_file_status()
        if status == "saving" then return end
        local o = op
        op = nil
        cache = nil
        if status ~= "saved" then
            say("The line could not be saved: " .. tostring(status), "warn")
            return
        end
        local ok, why = reskate.files.write(path(o.id, ".json"), reskate.json.encode(o.meta))
        if not ok then
            pcall(reskate.files.remove, path(o.id, ".line"))
            say("The line could not be saved: " .. tostring(why), "warn")
            return
        end
        R.line(string.format("[lines] saved %q as %s, %s, on %s", o.meta.name, o.id, clock_text(o.meta.length), tostring(o.meta.map)))
        say("Saved: " .. o.meta.name)
    elseif op.stage == "travel" then
        -- One trip every 5 s: refused, asked again a little later.
        if op.next_at and now < op.next_at then return end
        local ok, why = reskate.travel.go(op.destination)
        if ok then
            op.stage, op.at, op.seen = "arriving", now, nil
            return
        end
        op.tries += 1
        if op.tries >= 4 then
            op = nil
            say("Could not travel to the line's map: " .. tostring(why), "warn")
            return
        end
        op.next_at = now + 1500
    elseif op.stage == "arriving" then
        -- There once the map is the line's and a skater stands in it a moment: then as any load.
        if norm(current_map()) == norm(op.meta.map) and reskate.skater.get() then
            op.seen = op.seen or now
            if now - op.seen >= SETTLE_MS then op.stage, op.at = "stopping", now end
        else
            op.seen = nil
            if now - op.at > TRAVEL_MS then
                op = nil
                say("The line's map did not load: try loading the line again", "warn")
            end
        end
    elseif op.stage == "stopping" then
        local phase = L.phase()
        if phase == "off" or phase == "played" then
            local ok, why = reskate.tas.line_import(path(op.id, ".line"), L.find_pad())
            if not ok then
                op = nil
                say("The line could not be loaded: " .. tostring(why), "warn")
                return
            end
            op.stage = "loading"
        elseif now - op.at > STOP_MS then
            op = nil
            say("The line could not be loaded: the line there would not stop", "warn")
        end
    else
        local status = reskate.tas.line_file_status()
        if status == "loading" then return end
        local o = op
        op = nil
        if status ~= "loaded" then
            say("The line could not be loaded: " .. tostring(status), "warn")
            return
        end
        L.adopt(o.meta)
        say("Loaded: " .. tostring(o.meta.name) .. ". Pick a moment and retake it")
    end
end

-- ---- the window -----------------------------------------------------------------------------------------
function LIB.is_open()
    return window ~= nil
end

function LIB.open(from_timeline)
    if window then return true end
    cache = nil
    reskate.ui.open(SCREEN)
    reskate.input.text(true) -- Esc is ours while it is open
    window = {from_timeline = from_timeline, left = true, escape = true, enter = true, scroll = 0}
    return true
end

local function close_window()
    local was = window
    window = nil
    if not was then return end
    if was.from_timeline and L.resume_player() then return end
    reskate.ui.close()
end

function LIB.drop()
    window = nil
end

function LIB.on_screen_closed(title)
    if title ~= SCREEN or not window then return end
    close_window()
end

local width, height = 1920, 1080
local function layout()
    local k = height / 1080
    local w, h = math.min(940 * k, width - 32 * k), 640 * k
    local box = {x0 = (width - w) / 2, y0 = (height - h) / 2}
    box.x1, box.y1 = box.x0 + w, box.y0 + h
    local pad = 34 * k
    local list = {x0 = box.x0 + pad, x1 = box.x1 - pad, y0 = box.y0 + 160 * k, y1 = box.y1 - 100 * k}
    local row_h = (list.y1 - list.y0) / ROWS_SHOWN
    local buttons = {
        save = {x0 = box.x1 - pad - 270 * k, x1 = box.x1 - pad, y0 = box.y0 + 32 * k, y1 = box.y0 + 80 * k},
        close = {x0 = box.x1 - pad - 160 * k, x1 = box.x1 - pad, y0 = box.y1 - 78 * k, y1 = box.y1 - 30 * k},
    }
    local rows = {}
    local entries = LIB.list()
    for index = 1, ROWS_SHOWN do
        local entry = entries[index + window.scroll]
        if not entry then break end
        local y0 = list.y0 + (index - 1) * row_h
        local r = {entry = entry, box = {x0 = list.x0, x1 = list.x1, y0 = y0 + 4 * k, y1 = y0 + row_h - 4 * k}}
        local by0, by1 = (r.box.y0 + r.box.y1) / 2 - 22 * k, (r.box.y0 + r.box.y1) / 2 + 22 * k
        r.load = {x0 = list.x1 - 16 * k - 120 * k, x1 = list.x1 - 16 * k, y0 = by0, y1 = by1}
        r.delete = {x0 = r.load.x0 - 10 * k - 120 * k, x1 = r.load.x0 - 10 * k, y0 = by0, y1 = by1}
        table.insert(rows, r)
    end
    return k, box, list, buttons, rows, pad
end

local function inside(p, r)
    return p.x >= r.x0 and p.x <= r.x1 and p.y >= r.y0 and p.y <= r.y1
end

local function answer(ok, why)
    if not ok then say(tostring(why), "warn") end
end

local function click(mouse)
    local _, _, _, buttons, rows = layout()
    local p = mouse.position
    if inside(p, buttons.close) then
        close_window()
        return
    end
    if inside(p, buttons.save) then
        answer(LIB.save())
        return
    end
    for _, r in rows do
        if inside(p, r.load) then
            local from_timeline = window.from_timeline
            local ok, why = LIB.load(r.entry.id)
            answer(ok, why)
            -- Loading stops the line and closes the timeline under it; this window closes too, the toast says how it went.
            if ok then
                window = nil
                reskate.ui.close()
            end
            return
        elseif inside(p, r.delete) then
            if window.confirm == r.entry.id then
                window.confirm = nil
                answer(LIB.delete(r.entry.id))
                local count = #LIB.list()
                window.scroll = math.max(0, math.min(window.scroll, count - ROWS_SHOWN))
            else
                window.confirm = r.entry.id
            end
            return
        end
    end
    window.confirm = nil
end

function LIB.tick(now)
    op_tick(now)
    if not window then return end
    reskate.input.text(true)
    local escape = reskate.input.key(VK_ESCAPE)
    if escape and not window.escape then
        close_window()
        return
    end
    window.escape = escape
    local mouse = reskate.input.cursor()
    if mouse then
        if mouse.wheel and mouse.wheel ~= 0 then
            local count = #LIB.list()
            window.scroll = math.max(0, math.min(window.scroll + (mouse.wheel > 0 and -1 or 1), math.max(0, count - ROWS_SHOWN)))
        end
        if mouse.left and not window.left then click(mouse) end
        if window then window.left = mouse.left end
    end
end

-- ---- drawing ----------------------------------------------------------------------------------------------
local ACCENT, INK, TEXT, MUTED, RED = "#02f7da", "#0c0d11", "#f2f3f5", "#9aa0aa", "#ff5a5a"

local function v(x, y)
    return vector.create(x, y, 0)
end

local function txt(size, colour, font)
    return {colour = colour, size = size, font = font or "heading"}
end

local function button(d, r, label, kind, mouse, k, off)
    local hover = not off and mouse and inside(mouse.position, r)
    local fill, ink = {colour = hover and "#ffffff26" or "#ffffff14", fill = true, rounding = 10}, TEXT
    if kind == "primary" then fill, ink = {colour = hover and "#5ffbe8" or ACCENT, fill = true, rounding = 10}, INK end
    if kind == "danger" then fill, ink = {colour = hover and "#ff5a5a40" or "#ff5a5a26", fill = true, rounding = 10}, RED end
    if off then fill, ink = {colour = "#ffffff08", fill = true, rounding = 10}, "#ffffff40" end
    d:rect(v(r.x0, r.y0), v(r.x1, r.y1), fill)
    local style = txt(17, ink)
    local size = d:measure(label, style)
    d:text(v((r.x0 + r.x1) / 2 - size.x / 2, (r.y0 + r.y1) / 2 - size.y / 2), label, style)
end

function LIB.draw(d)
    if not window then return end
    local size = d:size()
    width, height = size.x, size.y
    local k, box, list, buttons, rows, pad = layout()
    local mouse = reskate.input.cursor()
    d:rect(v(0, 0), v(width, height), {colour = "#000000a0", fill = true})
    d:rect(v(box.x0, box.y0), v(box.x1, box.y1), {colour = "#0c0d11f4", fill = true, rounding = 16})
    d:rect(v(box.x0, box.y0), v(box.x1, box.y1), {colour = "#ffffff1c", thickness = 1, rounding = 16})
    local x = box.x0 + pad
    d:text(v(x, box.y0 + 30 * k), "My lines", txt(30, TEXT))
    d:text(v(x, box.y0 + 80 * k), "Save a line to come back to it, even after closing the game. Loading one replaces the line you have now.",
        txt(15, MUTED, "body"))
    local info = L.info()
    local can_save = info.phase ~= "off" and info.length > 0 and info.start ~= nil and not op
    button(d, buttons.save, can_save and ("Save this line  " .. clock_text(info.length)) or "Save this line", "primary", mouse, k, not can_save)

    local here = current_map()
    local entries = LIB.list()
    if #entries == 0 then
        local empty = txt(18, MUTED, "body")
        local m = d:measure("No lines saved yet.", empty)
        d:text(v((list.x0 + list.x1) / 2 - m.x / 2, (list.y0 + list.y1) / 2 - m.y), "No lines saved yet.", empty)
    end
    for _, r in rows do
        local b = r.box
        local hover = mouse and inside(mouse.position, b)
        d:rect(v(b.x0, b.y0), v(b.x1, b.y1), {colour = hover and "#ffffff12" or "#ffffff08", fill = true, rounding = 10})
        local meta = r.entry.meta
        local cy = (b.y0 + b.y1) / 2
        d:text(v(b.x0 + 18 * k, cy - 24 * k), tostring(meta.name or r.entry.id), txt(20, TEXT))
        local retakes = meta.joins and #meta.joins or 0
        local sub = string.format("%s  ·  saved %s  ·  %d %s", clock_text(meta.length), tostring(meta.saved or "?"), retakes, retakes == 1 and "retake" or "retakes")
        if meta.map and here and norm(meta.map) ~= norm(here) then sub ..= "  ·  on " .. map_label(meta) end
        d:text(v(b.x0 + 18 * k, cy + 4 * k), sub, txt(14, MUTED, "body"))
        local busy = op ~= nil
        button(d, r.load, op and op.id == r.entry.id and "Loading…" or "Load", "primary", mouse, k, busy)
        button(d, r.delete, window.confirm == r.entry.id and "Sure?" or "Delete", window.confirm == r.entry.id and "danger" or "normal", mouse, k, busy)
    end
    if #entries > ROWS_SHOWN then
        local more = string.format("%d–%d of %d  (wheel to scroll)", window.scroll + 1, math.min(#entries, window.scroll + ROWS_SHOWN), #entries)
        d:text(v(x, box.y1 - 64 * k), more, txt(14, MUTED, "body"))
    end
    local note = window.error or window.message
    if note then d:text(v(x, box.y1 - 90 * k), note, txt(15, window.error and RED or ACCENT, "body")) end
    button(d, buttons.close, window.from_timeline and "Back" or "Close", "normal", mouse, k)
end

reskate.ui.screen(SCREEN, function() end, {panel = false})

return LIB
