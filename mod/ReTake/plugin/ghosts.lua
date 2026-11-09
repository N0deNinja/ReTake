-- Ghost lines: a line as its skater rode it, to share and try. Making one plays your line once, hands off, while
-- ReSkate.dll keeps the skater's pose at every step (as multiplayer sends a player to the others), the camera, and
-- the outfit: a .ghost file in Mods\.reskate_plugin_data\ReTake\ghosts, to send to anyone with ReTake. Someone who
-- has it sees a pin over its start; near it, ReTake says so. Watch: the line as its skater saw it, through their
-- camera. Try it: you start where they did, at their speed, and their skater rides beside you, a real skater in
-- their outfit with their name over them. A ghost can't be retaken or changed: it is theirs to match.
local U = require("util")
local R = require("report")
local S = require("ui")
local L = require("line")
local G = {}

local FOLDER = "ghosts"
local NAME_FILE = "name.txt"
local LABELS_FILE = "labels.txt"
local SCREEN = "ReTake Ghost lines"
local STEPS = 60
local NEAR_M = 40          -- this close to a ghost line's start, ReTake says it is there
local PIN_M = 400          -- pins over the starts this far off
local MAP_M = 300          -- the window's map shows this far around you
local COUNT_MS = 3000      -- 3, 2, 1 before a try
local LEAD_MS = 600        -- a watch starts this long after the camera is on the ghost
local END_HOLD_MS = 1500   -- the ghost stays at its end this long
local LIST_MS = 20000      -- the folder is looked at again this often
local LOAD_MS = 15000
local MAKE_MS = 15000      -- the line's playing has to start within this
local HEAD_UP = 1.95       -- the name's point, this far above the skater's root (until the head is drawn)
local ABOVE_HEAD = 0.3     -- and this far above the middle of the ghost's head as the game draws it
local ROWS_SHOWN = 6
local VK_ESCAPE, VK_BACK, VK_TAB, VK_RETURN, VK_CONTROL = 27, 8, 9, 13, 17
local TITLE_MOST, AUTHOR_MOST = 40, 24

local library = nil -- library.lua: the map, travelling
local cache, cache_at, notes = nil, -math.huge, {} -- the ghost lines there are; notes by file, read once
local making = nil  -- {name=, catch_up=, stage=, at=, seen=, failed=, meta=, file=}
local loading = nil -- {entry=, kind=, at=, stage=}: a ghost being loaded to watch or try
local run = nil     -- {kind="watch"|"try", entry=, stage=, first=, last=, at=, base=, ...}
local last_entry = nil -- the one last watched or tried, first in the window
local near_said = {} -- file -> true while you are near its start
local near_at = -math.huge
local name = nil     -- the player's name for the ghosts they make
local labels = nil   -- the floating labels shown: "all", "near" or "off"
local window = nil   -- {left=, escape=, scroll=, confirm=, message=, error=}
local width, height = 1920, 1080

function G.set_library(lib)
    library = lib
end

local function say(text, kind)
    if window then
        if kind == "warn" then window.error, window.message = text, nil else window.message, window.error = text, nil end
    end
    R.toast(text, kind)
    R.line("[ghosts] " .. text)
end

local function clock_text(steps)
    local seconds = math.max(0, steps or 0) / STEPS
    return string.format("%d:%05.2f", math.floor(seconds / 60), seconds % 60)
end

local function has_api()
    return reskate.tas.ghost_record ~= nil and reskate.tas.ghost_show ~= nil
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---- who you are --------------------------------------------------------------------------------------------
function G.name()
    if name == nil then
        local text = reskate.files.read(NAME_FILE)
        name = text and string.match(text, "^%s*(.-)%s*$") or ""
    end
    if name ~= "" then return name end
    return library and library.player_name() or nil
end

function G.set_name(text)
    text = string.match(tostring(text or ""), "^%s*(.-)%s*$")
    if #text > 24 then text = string.sub(text, 1, 24) end
    local ok, why = reskate.files.write(NAME_FILE, text)
    if not ok then return false, why end
    name = text
    return true
end

-- ---- the floating labels ------------------------------------------------------------------------------------
-- Over the starts of the ghost lines around you and over a ghost's skater: all of them, only the ones near you
-- (where F10 can start them), or none.
local LABEL_NAMES = {all = "All", near = "Near only", off = "Off"}
local LABEL_ORDER = {"all", "near", "off"}

function G.labels()
    if labels == nil then
        local text = reskate.files.read(LABELS_FILE)
        text = text and string.lower(string.match(text, "^%s*(.-)%s*$")) or ""
        labels = LABEL_NAMES[text] and text or "all"
    end
    return labels
end

function G.set_labels(what)
    what = string.lower(tostring(what or ""))
    if not LABEL_NAMES[what] then return false, "the labels are all, near or off" end
    labels = what
    local ok, why = reskate.files.write(LABELS_FILE, what)
    if not ok then return false, why end
    R.line("[ghosts] labels " .. what)
    return true
end

function G.labels_text(what)
    what = what or G.labels()
    if what == "near" then return string.format("near only (within %d m of a start)", NEAR_M) end
    if what == "off" then return "off (no names over the starts or the ghosts)" end
    return string.format("all (every start within %d m)", PIN_M)
end

local function next_labels()
    local now = G.labels()
    for i, what in LABEL_ORDER do
        if what == now then return LABEL_ORDER[i % #LABEL_ORDER + 1] end
    end
    return "all"
end

-- ---- the folder ---------------------------------------------------------------------------------------------
-- The ghost lines there are, by name: {file=, meta=}. Each file's note is read once.
function G.list(fresh)
    local now = U.now()
    if cache and not fresh and now - cache_at < LIST_MS then return cache end
    local out = {}
    local ok, names = pcall(reskate.files.list, FOLDER)
    if ok and names then
        for _, path in names do
            local file = string.match(path, "([^/\\]+%.ghost)$")
            if file then
                local meta = notes[file]
                if meta == nil then
                    meta = false
                    local note, why = reskate.tas.ghost_note(FOLDER .. "/" .. file)
                    if note then
                        local decoded, value = pcall(reskate.json.decode, note)
                        if decoded and type(value) == "table" and type(value.start) == "table" then meta = value end
                    else
                        R.line("[ghosts] " .. file .. " is not a ghost line this ReTake reads: " .. tostring(why))
                    end
                    notes[file] = meta
                end
                if meta then table.insert(out, {file = file, meta = meta}) end
            end
        end
    end
    table.sort(out, function(a, b) return string.lower(tostring(a.meta.name)) < string.lower(tostring(b.meta.name)) end)
    cache, cache_at = out, now
    return out
end

local function start_of(entry)
    local s = entry.meta.start
    return vector.create(s.x or 0, s.y or 0, s.z or 0)
end

local function here_ok(entry)
    return not library or library.same_map(entry.meta.map)
end

local function skater_at()
    local ok, s = pcall(reskate.skater.get)
    return ok and s and s.position or nil
end

-- ---- making one ---------------------------------------------------------------------------------------------
function G.making()
    return making ~= nil
end

local function make_fail(why)
    local m = making
    making = nil
    pcall(reskate.tas.ghost_record, false)
    if m and m.catch_up then L.set_catch_up(m.catch_up) end
    say("The ghost line could not be made: " .. tostring(why), "warn")
end

-- Whether a ghost line can be made of the line you have now, and why not.
local function make_check()
    if U.in_session() then return false, "ReTake is offline only" end
    if not has_api() then return false, "this ReSkate.dll cannot make ghost lines: install ReTake's DLL from this version" end
    if making then return false, "a ghost line is being made" end
    if run or loading then return false, "stop the ghost line first" end
    local info = L.info()
    if info.phase == "off" or info.length == 0 or not info.start then return false, "there is no line to make a ghost of: skate one first" end
    if L.busy() then return false, "wait for the countdown" end
    if library and library.busy() then return false, "a line is being saved or loaded" end
    if not L.sensor_ready() then return false, "ride for a moment first: until you've skated since the game started, a replay goes off on rails" end
    return true
end

-- A ghost line's title when none is given: the saved line's name, or when it was made.
local function default_title()
    local source = library and library.source()
    return (source and source.name) or ("Ghost " .. os.date("%d %b, %H:%M"))
end

-- The line you have, played once from its start, hands off, kept as a ghost line called `title`, signed `author`
-- (your name: the one you set, else your Steam name).
function G.make(title, author)
    local can, why_not = make_check()
    if not can then return false, why_not end
    local info = L.info()
    local p = info.start.position
    local source = library and library.source()
    title = (title and title ~= "") and title or default_title()
    author = (author and author ~= "") and author or G.name() or "a skater"
    local map = library and library.current_map()
    making = {
        title = title, catch_up = L.catch_up_speed(), stage = "playing", at = U.now(), seen = false,
        meta = {
            name = title, author = author, made = os.date("%Y-%m-%d %H:%M"), retake = L.version, map = map,
            map_name = map and library and library.map_name(map) or nil,
            start = {x = p.x, y = p.y, z = p.z, heading = info.start.heading, on_board = info.start.on_board ~= false},
            line = source and source.name or nil,
        },
    }
    local ok, why = reskate.tas.ghost_record(true)
    if not ok then
        making = nil
        return false, why
    end
    -- Real time, so every step of the line is drawn once and kept.
    L.set_catch_up(1)
    ok, why = L.play_whole()
    if not ok then
        make_fail(why)
        return false, why
    end
    say("Making a ghost line of your line: it plays once, hands off")
    return true
end

local function make_tick(now)
    local m = making
    if m.stage == "playing" then
        local line = reskate.tas.line()
        if line.phase == "running_up" then
            m.seen = true
            local ok, why = reskate.tas.ghost_capture(line.step)
            if not ok and not m.failed then
                m.failed = true
                R.line("[ghosts] a pose was not kept: " .. tostring(why))
            end
        elseif m.seen and line.phase == "played" then
            reskate.tas.ghost_record(false)
            L.set_catch_up(m.catch_up)
            local s = reskate.tas.ghost_status()
            if (s.recorded or 0) < STEPS then return make_fail("too little of the line was kept (" .. tostring(s.recorded) .. " steps)") end
            m.meta.first, m.meta.last = s.recorded_first, s.recorded_last
            m.meta.length = s.recorded_last - s.recorded_first
            m.meta.outfit = s.recorded_outfit
            local stem = string.gsub(string.gsub(string.lower(m.title), "[^%w]+", "-"), "^%-*(.-)%-*$", "%1")
            if stem == "" then stem = "ghost" end
            m.file = string.sub(stem, 1, 40) .. "-" .. os.date("%Y%m%d-%H%M%S") .. ".ghost"
            local ok, why = reskate.tas.ghost_export(FOLDER .. "/" .. m.file, reskate.json.encode(m.meta))
            if not ok then return make_fail(why) end
            m.stage, m.at = "saving", now
        elseif line.phase == "off" or (m.seen and line.phase ~= "running_up") or (not m.seen and now - m.at > MAKE_MS) then
            make_fail("the line stopped playing")
        end
    elseif m.stage == "saving" then
        local status = reskate.tas.ghost_status().file
        if status == "saving" then return end
        making = nil
        if status ~= "saved" then
            say("The ghost line could not be saved: " .. tostring(status), "warn")
            return
        end
        cache = nil
        R.line(string.format("[ghosts] made %q as %s, %s, outfit %s", m.title, m.file, clock_text(m.meta.length), tostring(m.meta.outfit)))
        say("Ghost line made: " .. m.title .. ". To share it, send " .. m.file .. " (F10, Open folder)")
    end
end

-- ---- watching and trying ------------------------------------------------------------------------------------
function G.running()
    return run ~= nil or loading ~= nil
end

local function give_back()
    pcall(reskate.tas.ghost_hide)
    pcall(reskate.camera.release)
    pcall(reskate.skater.hide, false)
    pcall(reskate.skater.hold, false)
end

function G.stop(why)
    if making then make_fail(why or "stopped") end
    local was = run or loading
    run, loading = nil, nil
    if was then
        give_back()
        if why then R.line("[ghosts] stopped: " .. tostring(why)) end
    end
end

-- The physics steps since the skater was built: the ghost keeps to the game's own steps, so a pause or slow motion
-- holds it too. Between two steps, the time since the last one, so it moves smoothly at any frame rate.
-- Counted here, so a skater built again (a bail) never sends the ghost back.
local function game_step(r, now)
    local count = reskate.tas.line().since_spawn or 0
    if r.count == nil then r.count, r.count_at, r.steps = count, now, 0 end
    if count ~= r.count then
        r.steps += count > r.count and count - r.count or 1
        r.count, r.count_at = count, now
    end
    return r.steps + math.min(1, (now - r.count_at) * STEPS / 1000)
end

local function begin(entry, kind)
    local s = reskate.tas.ghost_status()
    local meta = entry.meta
    pcall(reskate.tas.status) -- the count of steps needs ReSkate.dll listening to them
    L.keep_still()
    local start = start_of(entry)
    local ok, why = reskate.skater.teleport(start, meta.start.heading or 0, {on_board = meta.start.on_board ~= false})
    if not ok then
        give_back()
        return say("Could not go to the ghost line's start: " .. tostring(why), "warn")
    end
    pcall(reskate.skater.hold, true)
    last_entry = entry
    run = {kind = kind, entry = entry, first = s.loaded_first, last = s.loaded_last, at = U.now(), stage = kind == "watch" and "lead" or "count"}
    if kind == "watch" then
        pcall(reskate.skater.hide, true)
        R.line(string.format("[ghosts] watching %q by %s", tostring(meta.name), tostring(meta.author)))
    else
        R.line(string.format("[ghosts] trying %q by %s", tostring(meta.name), tostring(meta.author)))
    end
end

-- Watch (kind "watch") or try ("try") a ghost line: on its map, loaded, then from its start.
function G.go(entry, kind)
    if U.in_session() then return false, "ReTake is offline only" end
    if not has_api() then return false, "this ReSkate.dll cannot show ghost lines: install ReTake's DLL from this version" end
    if making then return false, "a ghost line is being made" end
    if L.busy() then return false, "wait for the countdown" end
    if library and library.busy() then return false, "a line is being saved or loaded" end
    G.stop()
    loading = {entry = entry, kind = kind, at = U.now()}
    if not here_ok(entry) then
        if not library then return false, "the ghost line is on another map" end
        local ok, why = library.travel(entry.meta.map, function()
            if loading and loading.entry == entry then loading.stage, loading.at = nil, U.now() end
        end)
        if not ok then
            loading = nil
            return false, "this ghost line is on " .. library.map_label(entry.meta) .. ": " .. tostring(why)
        end
        loading.stage = "travel"
        return true
    end
    return true
end

local function load_tick(now)
    local l = loading
    if l.stage == "travel" then
        -- library.lua calls back once there; given up on there, it says why.
        if not library.busy() then
            loading = nil
            R.line("[ghosts] the trip to the ghost line's map did not end there")
        end
        return
    end
    if not l.stage then
        local ok, why = reskate.tas.ghost_load(FOLDER .. "/" .. l.entry.file)
        if not ok then
            loading = nil
            return say("The ghost line could not be loaded: " .. tostring(why), "warn")
        end
        l.stage, l.at = "loading", now
        return
    end
    local status = reskate.tas.ghost_status().file
    if status == "loading" then
        if now - l.at > LOAD_MS then
            loading = nil
            say("The ghost line took too long to load", "warn")
        end
        return
    end
    loading = nil
    if status ~= "loaded" then return say("The ghost line could not be loaded: " .. tostring(status), "warn") end
    begin(l.entry, l.kind)
end

local function show(step)
    local frame, why = reskate.tas.ghost_show(step)
    if not frame and run and run.why ~= why then
        run.why = why
        R.line("[ghosts] the ghost is not shown: " .. tostring(why))
    end
    if run then run.frame = frame end
    return frame
end

local function finish(text)
    local r = run
    run = nil
    give_back()
    if text then say(text) end
    return r
end

local function run_tick(now)
    local r = run
    local entry = r.entry
    if r.kind == "watch" then
        local step = r.first
        if r.stage == "lead" then
            if now - r.at >= LEAD_MS then r.stage, r.base = "playing", game_step(r, now) end
        else
            step = r.first + (game_step(r, now) - r.base)
        end
        local frame = show(step)
        if frame then
            local c = frame.camera
            local fov = c.fov
            if not (fov and fov >= 10 and fov <= 150) then fov = 0 end
            pcall(reskate.camera.set, c.position, c.forward, c.up, fov)
            if frame.ended then
                r.ended_at = r.ended_at or now
                if now - r.ended_at > END_HOLD_MS then
                    finish(nil)
                    -- Straight on at the start, ready: they have seen it, now it's theirs to try.
                    say("That was " .. tostring(entry.meta.name) .. " by " .. tostring(entry.meta.author) .. ". F10: try it")
                end
            end
        end
        return
    end
    -- A try: 3, 2, 1 held at the start beside the ghost, then you both go, you at its speed.
    if r.stage == "count" then
        show(r.first)
        if now - r.at >= COUNT_MS then
            pcall(reskate.skater.hold, false)
            local a = reskate.tas.ghost_frame(r.first)
            local b = reskate.tas.ghost_frame(r.first + 6)
            if a and b then
                local k = STEPS / 6
                local v = vector.create((b.root.x - a.root.x) * k, (b.root.y - a.root.y) * k, (b.root.z - a.root.z) * k)
                local speed = math.sqrt(v.x * v.x + v.z * v.z)
                if speed > 0.3 and speed < 60 then r.push, r.push_speed = v, speed end
            end
            r.stage, r.base, r.go_at = "go", game_step(r, now), now
        end
        return
    end
    -- Their speed at the start, given for a moment (the hold lets go on the next step).
    if r.push and now - r.go_at < 150 then
        local ok, sp = pcall(reskate.skater.speed)
        if not (ok and type(sp) == "number" and sp >= r.push_speed * 0.9) then pcall(reskate.skater.set_velocity, r.push) end
    end
    local frame = show(r.first + (game_step(r, now) - r.base))
    if frame and frame.ended then
        r.ended_at = r.ended_at or now
        if now - r.ended_at > END_HOLD_MS then
            finish(tostring(entry.meta.author) .. "'s line is done. F10: try it again")
        end
    end
end

-- Near a ghost line's start: once, while you are near it, ReTake says so.
local function near_tick(now)
    if now - near_at < 250 then return end
    near_at = now
    if run or loading or making or window then return end
    local at = skater_at()
    if not at then return end
    for _, entry in G.list() do
        if here_ok(entry) then
            local d = distance(at, start_of(entry))
            if d < NEAR_M and not near_said[entry.file] then
                near_said[entry.file] = true
                R.toast(string.format("Ghost line here: %s by %s.  F10 to watch or try it", tostring(entry.meta.name), tostring(entry.meta.author)))
            elseif d > NEAR_M * 1.5 then
                near_said[entry.file] = nil
            end
        end
    end
end

function G.tick(now)
    if making then make_tick(now) end
    if loading then load_tick(now) end
    if run then run_tick(now) end
    near_tick(now)
    if window then G.window_tick() end
end

-- ---- the window ---------------------------------------------------------------------------------------------
function G.is_open()
    return window ~= nil
end

function G.open()
    if window then return true end
    if run or loading then G.stop("the ghost lines window opened") end
    G.list(true)
    reskate.ui.open(SCREEN)
    reskate.input.text(true)
    window = {left = true, escape = true, scroll = 0}
    return true
end

local function close_window()
    if not window then return end
    window = nil
    reskate.ui.close()
end

function G.toggle()
    if window then
        close_window()
        return true
    end
    return G.open()
end

function G.on_screen_closed(title)
    if title == SCREEN and window then window = nil end
end

-- The list: the last one watched or tried first, then those on this map nearest first, then the rest.
local function ordered()
    local at = skater_at()
    local out = {}
    for _, entry in G.list() do
        local d = (at and here_ok(entry)) and distance(at, start_of(entry)) or math.huge
        table.insert(out, {entry = entry, d = d})
    end
    table.sort(out, function(a, b)
        local la, lb = last_entry and a.entry.file == last_entry.file, last_entry and b.entry.file == last_entry.file
        if la ~= lb then return la end
        if a.d ~= b.d then return a.d < b.d end
        return string.lower(tostring(a.entry.meta.name)) < string.lower(tostring(b.entry.meta.name))
    end)
    return out
end

local function layout()
    local k = height / 1080
    local w, h = math.min(1240 * k, width - 32 * k), 680 * k
    local box = {x0 = (width - w) / 2, y0 = (height - h) / 2}
    box.x1, box.y1 = box.x0 + w, box.y0 + h
    local pad = 34 * k
    local side = 360 * k
    local map = {x0 = box.x1 - pad - side, x1 = box.x1 - pad, y0 = box.y0 + 150 * k}
    map.y1 = map.y0 + side
    local list = {x0 = box.x0 + pad, x1 = map.x0 - 24 * k, y0 = box.y0 + 150 * k, y1 = box.y1 - 100 * k}
    local row_h = (list.y1 - list.y0) / ROWS_SHOWN
    local buttons = {
        make = {x0 = box.x1 - pad - 380 * k, x1 = box.x1 - pad, y0 = box.y0 + 34 * k, y1 = box.y0 + 82 * k},
        close = {x0 = box.x1 - pad - 160 * k, x1 = box.x1 - pad, y0 = box.y1 - 78 * k, y1 = box.y1 - 30 * k},
        folder = {x0 = box.x0 + pad, x1 = box.x0 + pad + 170 * k, y0 = box.y1 - 78 * k, y1 = box.y1 - 30 * k},
    }
    buttons.labels = {x0 = buttons.folder.x1 + 12 * k, x1 = buttons.folder.x1 + 12 * k + 300 * k, y0 = buttons.folder.y0, y1 = buttons.folder.y1}
    local rows = {}
    local entries = ordered()
    for index = 1, ROWS_SHOWN do
        local item = entries[index + window.scroll]
        if not item then break end
        local y0 = list.y0 + (index - 1) * row_h
        local r = {entry = item.entry, d = item.d, box = {x0 = list.x0, x1 = list.x1, y0 = y0 + 4 * k, y1 = y0 + row_h - 4 * k}}
        local by0, by1 = (r.box.y0 + r.box.y1) / 2 - 22 * k, (r.box.y0 + r.box.y1) / 2 + 22 * k
        r.try = {x0 = list.x1 - 16 * k - 110 * k, x1 = list.x1 - 16 * k, y0 = by0, y1 = by1}
        r.watch = {x0 = r.try.x0 - 10 * k - 110 * k, x1 = r.try.x0 - 10 * k, y0 = by0, y1 = by1}
        r.delete = {x0 = r.watch.x0 - 10 * k - 100 * k, x1 = r.watch.x0 - 10 * k, y0 = by0, y1 = by1}
        table.insert(rows, r)
    end
    return k, box, list, map, buttons, rows, pad, #entries
end

local function inside(p, r)
    return p.x >= r.x0 and p.x <= r.x1 and p.y >= r.y0 and p.y <= r.y1
end

local function answer(ok, why)
    if not ok then say(tostring(why), "warn") end
    return ok
end

function G.delete(entry)
    local ok = reskate.files.remove(FOLDER .. "/" .. entry.file)
    notes[entry.file] = nil
    cache = nil
    if not ok then return false, "it could not be deleted" end
    if last_entry and last_entry.file == entry.file then last_entry = nil end
    R.line("[ghosts] deleted " .. entry.file)
    return true
end

-- ---- naming a ghost line before it is made --------------------------------------------------------------------
local function drop_last(text)
    local i = #text
    if i == 0 then return text end
    while i > 1 and bit32.band(string.byte(text, i), 0xC0) == 0x80 do i -= 1 end
    return string.sub(text, 1, i - 1)
end

local function cut(text, most)
    local n = utf8.len(text)
    if n and n > most then return string.sub(text, 1, utf8.offset(text, most + 1) - 1) end
    return text
end

-- The Make button: a title and a name to type first, filled in already.
local function start_naming()
    local can, why = make_check()
    if not can then return say(tostring(why), "warn") end
    local known = library and library.player_name() or nil
    window.naming = {title = cut(default_title(), TITLE_MOST), author = cut(G.name() or "", AUTHOR_MOST), field = "title", steam = known,
        back = true, back_at = 0, enter = true, tab = true, escape = true, opened = U.now()}
    reskate.input.text(true) -- nothing typed before it counts
end

local function naming_layout(box, k)
    local w, h = 660 * k, 360 * k
    local r = {x0 = (box.x0 + box.x1) / 2 - w / 2, y0 = (box.y0 + box.y1) / 2 - h / 2 + 20 * k}
    r.x1, r.y1 = r.x0 + w, r.y0 + h
    local pad = 30 * k
    local f = {
        title = {x0 = r.x0 + pad, x1 = r.x1 - pad, y0 = r.y0 + 112 * k, y1 = r.y0 + 156 * k},
        author = {x0 = r.x0 + pad, x1 = r.x1 - pad, y0 = r.y0 + 196 * k, y1 = r.y0 + 240 * k},
        make = {x0 = r.x1 - pad - 190 * k, x1 = r.x1 - pad, y0 = r.y1 - 72 * k, y1 = r.y1 - 26 * k},
    }
    f.back = {x0 = f.make.x0 - 12 * k - 150 * k, x1 = f.make.x0 - 12 * k, y0 = f.make.y0, y1 = f.make.y1}
    return r, f
end

local function finish_naming()
    local n = window.naming
    local title, author = string.match(n.title, "^%s*(.-)%s*$"), string.match(n.author, "^%s*(.-)%s*$")
    if author == "" then
        n.error = "Type the name to show over your skater"
        n.field = "author"
        return
    end
    -- A name typed over your Steam name is kept for next time; your Steam name itself needs keeping by no one.
    G.set_name(author ~= (n.steam or "") and author or "")
    window.naming = nil
    if answer(G.make(title, author)) then close_window() end
end

local function naming_tick(now)
    local n = window.naming
    local typed = reskate.input.text(true)
    if typed ~= "" then
        typed = string.gsub(typed, "[%c]", "")
        if n.field == "title" then n.title = cut(n.title .. typed, TITLE_MOST) else n.author = cut(n.author .. typed, AUTHOR_MOST) end
        n.error = nil
    end
    local back = reskate.input.key(VK_BACK)
    if back then
        if not n.back or now >= n.back_at then
            if n.field == "title" then n.title = drop_last(n.title) else n.author = drop_last(n.author) end
            n.back_at = now + (n.back and 35 or 450)
            n.back = true
        end
    else
        n.back = false
    end
    local tab = reskate.input.key(VK_TAB)
    if tab and not n.tab then n.field = n.field == "title" and "author" or "title" end
    n.tab = tab
    local escape = reskate.input.key(VK_ESCAPE)
    if escape and not n.escape then
        window.naming = nil
        window.escape = true
        return
    end
    n.escape = escape
    local enter = reskate.input.key(VK_RETURN)
    if enter and not n.enter then return finish_naming() end
    n.enter = enter
end

local function naming_click(p)
    local k, box = layout()
    local _, f = naming_layout(box, k)
    if inside(p, f.title) then window.naming.field = "title"
    elseif inside(p, f.author) then window.naming.field = "author"
    elseif inside(p, f.make) then finish_naming()
    elseif inside(p, f.back) then window.naming = nil end
end

local function click(mouse)
    if window.naming then return naming_click(mouse.position) end
    local _, _, _, _, buttons, rows = layout()
    local p = mouse.position
    if inside(p, buttons.close) then return close_window() end
    if inside(p, buttons.folder) then
        pcall(reskate.files.reveal, FOLDER)
        window.message, window.error = "A ghost line someone sent you goes in this folder; it shows up here.", nil
        cache = nil
        return
    end
    if inside(p, buttons.make) then return start_naming() end
    if inside(p, buttons.labels) then
        local ok, why = G.set_labels(next_labels())
        if ok then window.message, window.error = "Floating labels: " .. G.labels_text(), nil
        else window.message, window.error = nil, tostring(why) end
        return
    end
    for _, r in rows do
        if inside(p, r.watch) or inside(p, r.try) then
            if answer(G.go(r.entry, inside(p, r.watch) and "watch" or "try")) then close_window() end
            return
        elseif inside(p, r.delete) then
            if window.confirm == r.entry.file then
                window.confirm = nil
                answer(G.delete(r.entry))
                window.scroll = math.max(0, math.min(window.scroll, #G.list() - ROWS_SHOWN))
            else
                window.confirm = r.entry.file
            end
            return
        end
    end
    window.confirm = nil
end

function G.window_tick()
    if window.naming then naming_tick(U.now()) end
    if not window then return end
    if window.naming then
        local mouse = reskate.input.cursor()
        if mouse then
            if mouse.left and not window.left then click(mouse) end
            if window then window.left = mouse.left end
        end
        return
    end
    reskate.input.text(true)
    local escape = reskate.input.key(VK_ESCAPE)
    if escape and not window.escape then return close_window() end
    window.escape = escape
    local mouse = reskate.input.cursor()
    if mouse then
        if mouse.wheel and mouse.wheel ~= 0 then
            local count = #G.list()
            window.scroll = math.max(0, math.min(window.scroll + (mouse.wheel > 0 and -1 or 1), math.max(0, count - ROWS_SHOWN)))
        end
        if mouse.left and not window.left then click(mouse) end
        if window then window.left = mouse.left end
    end
end

-- ---- drawing ------------------------------------------------------------------------------------------------
local GHOST = S.GHOST
local v = S.v
local centred = S.centred

local function distance_text(dist)
    if dist == math.huge then return nil end
    if dist < 1000 then return string.format("%d m", math.floor(dist + 0.5)) end
    return string.format("%.1f km", dist / 1000)
end

-- From above, around you: you an arrow at the middle, each ghost line on this map a dot at its start.
local function draw_map(d, k, m)
    S.tile(d, m, S.TILE, 61, k)
    S.dots(d, m.x0 + 12 * k, m.y0 + 12 * k, 8, 4, "#ffffff22")
    local cx, cy = (m.x0 + m.x1) / 2, (m.y0 + m.y1) / 2
    local half = (m.x1 - m.x0) / 2 - 14 * k
    for _, ring in {100, 200, 300} do
        d:circle(v(cx, cy), half * ring / MAP_M, {colour = ring == MAP_M and "#ffffff2a" or "#ffffff14", thickness = ring == MAP_M and 2 or 1})
    end
    d:line(v(cx, cy - half), v(cx, cy + half), {colour = "#ffffff10", thickness = 1})
    d:line(v(cx - half, cy), v(cx + half, cy), {colour = "#ffffff10", thickness = 1})
    S.tag(d, m.x0 + 12 * k, m.y1 - 34 * k, string.format("%d M AROUND YOU", MAP_M), k, S.TILE_LIGHT, S.SOFT)
    local s = nil
    pcall(function() s = reskate.skater.get() end)
    if not s or not s.position then
        centred(d, "NO SKATER", S.font(15, S.MUTED, "bold", true), cx, cy)
        return
    end
    local at = s.position
    -- Your heading up the map.
    local heading = s.heading or 0
    local ch, sh = math.cos(heading), math.sin(heading)
    local function place(p)
        local dx, dz = p.x - at.x, p.z - at.z
        -- Turned so the way you face is up.
        local rx = dx * ch - dz * sh
        local ry = dx * sh + dz * ch
        return rx / MAP_M * half, ry / MAP_M * half
    end
    for _, entry in G.list() do
        if here_ok(entry) then
            local x, y = place(start_of(entry))
            local out = math.sqrt(x * x + y * y) > half
            if out then
                local f = half / math.sqrt(x * x + y * y)
                x, y = x * f, y * f
            end
            local px, py = cx + x, cy - y
            if not out then d:circle(v(px, py), 12 * k, {colour = "#b9a7ff40", fill = true}) end
            d:circle(v(px, py), (out and 5 or 7) * k, {colour = out and "#b9a7ff80" or GHOST, fill = true})
            if not out then d:text(v(px + 14 * k, py - 9 * k), tostring(entry.meta.name), S.font(13, S.TEXT, "bold", true)) end
        end
    end
    d:poly({v(cx, cy - 13 * k), v(cx + 9 * k, cy + 10 * k), v(cx, cy + 5 * k), v(cx - 9 * k, cy + 10 * k)}, {colour = S.ACCENT, fill = true})
end

-- The naming step: a tile over the window, two white fields, Back and Make it.
local function draw_naming(d, k, box, mouse)
    local n = window.naming
    d:rect(v(box.x0, box.y0), v(box.x1, box.y1), {colour = "#000000a0", fill = true})
    local r, f = naming_layout(box, k)
    S.panel(d, r, k, 71)
    local x = r.x0 + 30 * k
    S.title(d, x, r.y0 + 20 * k, "Name your ghost line", k, false)
    local caret_on = math.floor((U.now() - n.opened) / 500) % 2 == 0
    local function field(rect, label, text, hint, on)
        d:text(v(rect.x0, rect.y0 - 22 * k), label, S.font(13, on and S.ACCENT or S.MUTED, "bold", true))
        if on then S.tile(d, {x0 = rect.x0 - 3 * k, x1 = rect.x1 + 3 * k, y0 = rect.y0 - 3 * k, y1 = rect.y1 + 3 * k}, S.ACCENT, S.seed(label) + 2, k) end
        S.tile(d, rect, S.PAPER, S.seed(label), k)
        local style = S.font(18, text == "" and "#6e6e6e" or S.INK, "body")
        local shown = text == "" and hint or text
        local m = d:measure(shown, style)
        local cy = (rect.y0 + rect.y1) / 2
        d:text(v(rect.x0 + 14 * k, cy - m.y / 2), shown, style)
        if on and caret_on then
            local cx = rect.x0 + 14 * k + (text == "" and 0 or m.x + 2 * k)
            d:rect(v(cx, cy - 12 * k), v(cx + 2.5 * k, cy + 12 * k), {colour = S.INK, fill = true})
        end
    end
    field(f.title, "TITLE", n.title, "What the line is called", n.field == "title")
    field(f.author, "YOUR NAME, OVER YOUR SKATER", n.author, "Type your name", n.field == "author")
    local note = n.error or (n.steam and n.author == n.steam and "Your Steam name. Type over it to sign with another.")
        or (not n.steam and "Your Steam name couldn't be read: type the name to show.") or "Kept for your next ghost lines."
    S.note(d, f.author.x0, f.author.y1 + 10 * k, note, k, n.error ~= nil)
    S.keycap(d, x, (f.make.y0 + f.make.y1) / 2 - 11 * k, "Tab", "Next field", k)
    S.button(d, f.back, "Back", {mouse = mouse, k = k, key = "Esc"})
    S.button(d, f.make, "Make it", {kind = "primary", mouse = mouse, k = k, key = "Enter"})
end

local function draw_window(d)
    local k, box, list, m, buttons, rows, pad, count = layout()
    local mouse = reskate.input.cursor()
    S.scrim(d, width, height)
    S.panel(d, box, k, 51)
    local x = box.x0 + pad
    local th = S.title(d, x, box.y0 + 26 * k, "Ghost lines", k)
    d:text(v(x, box.y0 + 36 * k + th), "Other skaters' lines, to watch through their eyes and then try, with them riding beside you.",
        S.font(14, S.MUTED, "body", true))
    local info = L.info()
    local can_make = info.phase ~= "off" and info.length > 0 and info.start ~= nil and not making
    S.button(d, buttons.make, can_make and ("Make a ghost of my line  " .. clock_text(info.length)) or "Make a ghost of my line",
        {kind = "primary", mouse = mouse, k = k, off = not can_make, size = 14})
    if count == 0 then
        local cy = (list.y0 + list.y1) / 2
        centred(d, "NO GHOST LINES YET", S.font(20, S.SOFT, "heading", true), (list.x0 + list.x1) / 2, cy - 14 * k)
        centred(d, "Make one of your line, or put one someone sent in the folder.", S.font(14, S.MUTED, "body", true), (list.x0 + list.x1) / 2, cy + 16 * k)
    end
    for _, r in rows do
        local b = r.box
        S.row(d, b, S.hovered(mouse, b), S.seed(r.entry.file), k)
        local meta = r.entry.meta
        local cy = (b.y0 + b.y1) / 2
        d:circle(v(b.x0 + 24 * k, cy - 13 * k), 7 * k, {colour = GHOST, fill = true})
        d:text(v(b.x0 + 40 * k, cy - 25 * k), tostring(meta.name or r.entry.file), S.font(19, S.TEXT, "heading", true))
        local sub = string.format("by %s  ·  %s", tostring(meta.author or "someone"), clock_text(meta.length))
        local away = distance_text(r.d)
        if not here_ok(r.entry) then sub ..= "  ·  on " .. (library and library.map_label(meta) or "another map")
        elseif away then sub ..= "  ·  " .. away .. " away" end
        d:text(v(b.x0 + 40 * k, cy + 4 * k), sub, S.font(13, S.MUTED, "body", true))
        local busy = making ~= nil
        local sure = window.confirm == r.entry.file
        S.button(d, r.try, "Try it", {kind = "primary", mouse = mouse, k = k, off = busy, size = 15})
        S.button(d, r.watch, "Watch", {mouse = mouse, k = k, off = busy, size = 15})
        S.button(d, r.delete, sure and "Sure?" or "Delete", {kind = sure and "armed" or "danger", mouse = mouse, k = k, off = busy, size = 15})
    end
    if count > ROWS_SHOWN then
        local more = string.format("%d–%d of %d  (wheel to scroll)", window.scroll + 1, math.min(count, window.scroll + ROWS_SHOWN), count)
        d:text(v(x, box.y1 - 66 * k), more, S.font(13, S.MUTED, "body", true))
    end
    draw_map(d, k, m)
    local who = G.name()
    d:text(v(m.x0, m.y1 + 14 * k), "Your ghosts are signed " .. (who and ("\"" .. who .. "\"") or "\"a skater\""), S.font(14, S.SOFT, "body", true))
    d:text(v(m.x0, m.y1 + 36 * k), "Change it when you make one (or: retake name <name>)", S.font(12, S.MUTED, "body", true))
    local note = window.error or window.message
    if note then S.note(d, x, box.y1 - 112 * k, note, k, window.error ~= nil) end
    S.button(d, buttons.close, "Close", {mouse = mouse, k = k, key = "F10"})
    S.button(d, buttons.folder, "Open folder", {kind = "quiet", mouse = mouse, k = k})
    S.setting(d, buttons.labels, "Floating labels", LABEL_NAMES[G.labels()], {mouse = mouse, k = k,
        value_colour = G.labels() == "off" and S.MUTED or nil})
    if window.naming then draw_naming(d, k, box, mouse) end
end

-- A name over a point in the world, with how far it is: the ghost's tag, and the pins over the starts.
local function tag(d, k, at, title, under, colour, follow_with)
    -- d:follow: the overlay moves the tag to where the camera has the point as each frame is drawn, so it holds
    -- still over it while the camera swings (the camera here is a tick old). Older ReSkates: world_to_screen.
    local follow = d.follow ~= nil
    local p
    if follow then p = d:follow(at, follow_with) else p = d:world_to_screen(at) end
    if not p then return end
    local style = S.font(18, S.INK, "heading")
    local label = title -- a name as its skater wrote it
    local m = d:measure(label, style)
    local sub = under and S.font(13, S.SOFT, "bold", true)
    local ms = sub and d:measure(under, sub) or vector.create(0, 0, 0)
    local w = m.x + 22 * k
    local h = m.y + 10 * k
    local sw = sub and ms.x + 14 * k or 0
    local x0, y0 = p.x - w / 2, p.y - h - 10 * k
    local cx = x0 + w / 2
    -- The name on a paper tile with the ghost's colour along its foot, a point down to where it is; how far beside it.
    S.tile(d, {x0 = x0, x1 = x0 + w, y0 = y0, y1 = y0 + h}, S.PAPER, S.seed(label), k * 0.6)
    d:rect(v(x0, y0 + h - 4 * k), v(x0 + w, y0 + h), {colour = colour, fill = true})
    d:poly({v(cx - 7 * k, y0 + h), v(cx + 7 * k, y0 + h), v(cx, y0 + h + 9 * k)}, {colour = colour, fill = true})
    d:text(v(cx - m.x / 2, y0 + 4 * k), label, style)
    if sub then
        local sx, sh = x0 + w + 4 * k, ms.y + 6 * k
        S.tile(d, {x0 = sx, x1 = sx + sw, y0 = y0 + (h - sh) / 2, y1 = y0 + (h + sh) / 2}, "#1a1a1ad8", S.seed(under), k * 0.5)
        d:text(v(sx + 7 * k, y0 + h / 2 - ms.y / 2), under, sub)
    end
    if follow then d:follow() end
end

-- What is going on, along the bottom: a tile with its words and a key.
local function status_bar(d, k, text, key, what)
    local style = S.font(18, S.TEXT, "heading", true)
    local m = d:measure(string.upper(text), style)
    local cap = key and S.keycap_width(d, key, what, k) + 26 * k or 0
    local w = m.x + cap + 40 * k
    local r = {x0 = width / 2 - w / 2, x1 = width / 2 + w / 2, y0 = height - 96 * k, y1 = height - 50 * k}
    S.tile(d, r, "#1a1a1ae6", S.seed(text), k)
    S.tile(d, {x0 = r.x0, x1 = r.x0 + 6 * k, y0 = r.y0, y1 = r.y1}, GHOST, 3, k * 0.4)
    d:text(v(r.x0 + 20 * k, (r.y0 + r.y1) / 2 - m.y / 2), string.upper(text), style)
    if key then S.keycap(d, r.x0 + 20 * k + m.x + 26 * k, (r.y0 + r.y1) / 2 - 11 * k, key, what, k) end
end

function G.draw(d)
    local size = d:size()
    width, height = size.x, size.y
    local k = height / 1080
    if window then return draw_window(d) end
    local r = run
    if r then
        -- Their name over their skater.
        if r.frame and G.labels() ~= "off" then
            local h = r.frame.root
            tag(d, k, vector.create(h.x, h.y + HEAD_UP, h.z), tostring(r.entry.meta.author or "someone"), nil, GHOST,
                {ghost_head = ABOVE_HEAD})
        end
        local status
        if r.kind == "try" and r.stage == "count" then
            local left = math.max(1, math.ceil((COUNT_MS - (U.now() - r.at)) / 1000))
            centred(d, tostring(left), {colour = "#ffffff", size = 160, font = "title_large", shadow = true}, width / 2, height * 0.38)
            status = "Get ready: " .. tostring(r.entry.meta.name)
        elseif r.kind == "watch" then
            status = "Watching " .. tostring(r.entry.meta.name) .. " by " .. tostring(r.entry.meta.author)
        else
            status = "Trying " .. tostring(r.entry.meta.name)
        end
        status_bar(d, k, status, "F10", "Stop")
        return
    end
    if loading then
        status_bar(d, k, "Loading the ghost line…")
        return
    end
    if making then
        status_bar(d, k, "Making a ghost line: hands off")
        return
    end
    -- Pins over the starts of the ghost lines on this map: smaller the further off they are.
    local shown = G.labels()
    if shown == "off" then return end
    local at = skater_at()
    if not at then return end
    local most = shown == "near" and NEAR_M or PIN_M
    for _, entry in G.list() do
        if here_ok(entry) then
            local s = start_of(entry)
            local dist = distance(at, s)
            if dist < most and dist > 3 then
                local under = distance_text(dist) .. (dist < NEAR_M and "  ·  F10" or "")
                local far = math.clamp((dist - NEAR_M) / (PIN_M - NEAR_M), 0, 1)
                tag(d, k * (1 - 0.3 * far), vector.create(s.x, s.y + 2.6, s.z), tostring(entry.meta.name), under, GHOST)
            end
        end
    end
end

reskate.ui.screen(SCREEN, function() end, {panel = false})

return G
