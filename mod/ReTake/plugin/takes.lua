-- Takes: every try kept. A retake cuts the line at the moment and records on from there; before it does, the line as
-- it was is saved as a take (takes/<line id>/<n>.retake, a whole line with its info inside, as My lines saves one).
-- In the timeline, Take 1 .. n are the versions kept, and the last the one being skated; switching loads that take as
-- the line, the one being skated kept first if it has anything new. A take branches where it was retaken, so picking
-- the best part of each try is: go to the take whose ending is best, and retake from there.
local R = require("report")
local U = require("util")
local L = require("line")
local TK = {}

local FOLDER = "takes"
local STOP_MS = 3000
local MOST_TAKES = 60 -- a line's takes kept; the oldest go first (files: the data folder holds 1000)

local uid = nil     -- the line whose takes these are
local takes = nil   -- {n=, meta=}, oldest first, read from the folder until something changes
local current = nil -- the take the line is (after a switch), nil when it is the one being skated
local dirty = false -- the line has something no take has (a retake, a new line)
local op = nil      -- {stage=, n=, at=, reopen=}: a switch under way
local library = nil -- library.lua, for "a line is being saved or loaded"

function TK.set_library(lib)
    library = lib
end

local function folder()
    return FOLDER .. "/" .. tostring(uid)
end

local function list()
    if takes then return takes end
    takes = {}
    if not uid or not reskate.tas.line_note then return takes end
    local ok, names = pcall(reskate.files.list, folder())
    if ok and names then
        for _, name in names do
            local n = tonumber(string.match(name, "(%d+)%.retake$"))
            if n then
                local note = reskate.tas.line_note(folder() .. "/" .. n .. ".retake")
                local decoded, meta = pcall(reskate.json.decode, note or "")
                if decoded and type(meta) == "table" then table.insert(takes, {n = n, meta = meta}) end
            end
        end
    end
    table.sort(takes, function(a, b) return a.n < b.n end)
    return takes
end

local function next_number()
    local t = list()
    return #t > 0 and t[#t].n + 1 or 1
end

-- The line as it is, kept as a take: in the background, the line copied at once (so a retake may cut it right after).
local function keep(why)
    if not reskate.tas.line_export or not uid then return false end
    local info = L.info()
    if info.phase == "off" or info.length == 0 or not info.start then return false end
    local n = next_number()
    local p = info.start.position
    local meta = {take = n, length = info.length, saved = os.date("%Y-%m-%d %H:%M:%S"), joins = info.joins, bails = info.bails, line_id = uid,
        start = {x = p.x, y = p.y, z = p.z, heading = info.start.heading, on_board = info.start.on_board ~= false}}
    local ok, err = reskate.tas.line_export(folder() .. "/" .. n .. ".retake", reskate.json.encode(meta))
    if not ok then
        R.line("[takes] the line could not be kept as take " .. n .. ": " .. tostring(err))
        return false
    end
    takes = nil
    R.line(string.format("[takes] take %d kept (%s), %d steps", n, why, info.length))
    -- At most so many: the oldest go.
    local t = list()
    while #t >= MOST_TAKES do
        pcall(reskate.files.remove, folder() .. "/" .. t[1].n .. ".retake")
        table.remove(t, 1)
    end
    return true
end

-- line.lua, just before a retake cuts the line: what it was is kept, if no take has it yet.
function TK.on_retake(to)
    if not uid then uid = L.line_id() end
    if dirty or current == nil then keep("retaken at step " .. to) end
    current, dirty = nil, true
end

-- A new line: its own takes. The last line's go, unless it was saved (then they stay with it).
function TK.on_new_line(id, saved_ids)
    local old = uid
    uid, takes, current, dirty, op = id, nil, nil, true, nil
    if old and old ~= id and not (saved_ids and saved_ids[old]) then
        local ok, names = pcall(reskate.files.list, FOLDER .. "/" .. old)
        if ok and names then
            for _, name in names do pcall(reskate.files.remove, FOLDER .. "/" .. old .. "/" .. string.match(name, "([^/\\]+)$")) end
        end
    end
end

-- A line loaded from My lines: its takes are the ones kept under its id.
function TK.on_loaded(id)
    uid, takes, current, dirty, op = id, nil, nil, false, nil
end

-- For the timeline: "Take index of count", nil while there is only the line being skated.
function TK.status()
    if not uid then return nil end
    local t = list()
    if #t == 0 then return nil end
    local count = #t + ((dirty or current == nil) and 1 or 0)
    local index = count
    if current then
        for i, take in t do if take.n == current then index = i end end
    end
    return {index = index, count = count, busy = op ~= nil}
end

-- One take back or on: that take becomes the line (the one being skated kept first, if it is new).
function TK.step(delta)
    if op then return false, "a take is being switched to" end
    if library and library.busy() then return false, "a line is being saved or loaded" end
    if L.busy() then return false, "wait for the countdown" end
    local status = TK.status()
    if not status then return false, "no takes yet" end
    local want = status.index + delta
    if want < 1 or want > status.count then return true end
    local t = list()
    local target = t[want]
    if not target then return true end -- the last place is the one being skated, kept as a take already
    op = {stage = "keeping", n = target.n, meta = target.meta, at = U.now(), reopen = true}
    if dirty or current == nil then
        if not keep("switched away") then op.stage = "stopping" end
    else
        op.stage = "stopping"
    end
    return true
end

function TK.tick(now)
    if not op then return end
    if op.stage == "keeping" then
        local status = reskate.tas.line_file_status()
        if status == "saving" then return end
        if status ~= "saved" then
            op = nil
            R.toast("The take could not be kept: " .. tostring(status), "warn")
            return
        end
        op.stage = "stopping"
    end
    if op.stage == "stopping" then
        if not op.stopped then
            L.suspend()
            op.stopped, op.at = true, now
        end
        local phase = L.phase()
        if phase == "off" or phase == "played" then
            local pad = L.find_pad()
            local ok, why = false, "connect a controller"
            if pad ~= nil then ok, why = reskate.tas.line_import(folder() .. "/" .. op.n .. ".retake", pad) end
            if not ok then
                op = nil
                R.toast("The take could not be loaded: " .. tostring(why), "warn")
                return
            end
            op.stage = "loading"
        elseif now - op.at > STOP_MS then
            op = nil
            R.toast("The take could not be loaded: the line would not stop", "warn")
        end
    elseif op.stage == "loading" then
        local status = reskate.tas.line_file_status()
        if status == "loading" then return end
        local o = op
        op = nil
        if status ~= "loaded" then
            R.toast("The take could not be loaded: " .. tostring(status), "warn")
            return
        end
        L.adopt(o.meta)
        current, dirty = o.n, false
        R.line(string.format("[takes] take %d is the line now", o.n))
        if o.reopen then L.toggle_player() end
    end
end

return TK
