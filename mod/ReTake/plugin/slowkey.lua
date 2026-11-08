-- The slow-motion button: L3 + R3 at first. In the timeline, click "Slow-mo key" and press the button or buttons you
-- want (a controller combo, or a key), then let go; click it again while it listens for none at all (off). Kept in
-- slowmo_key.txt: the combo as reskate.input.bind takes it ("Pad.L3+Pad.R3", "Ctrl+K"), or "off".
local U = require("util")
local R = require("report")
local K = {}

local ACTION = "retake_slowmo"
local FILE = "slowmo_key.txt"
local DEFAULT = "Pad.L3+Pad.R3"
local LISTEN_MS = 10000
local TRIGGER = 0.5
local VK_ESCAPE = 27

-- Pad buttons in the order a combo is written, with their names on an Xbox pad and a PlayStation one.
local PAD = {
    {field = "lb", name = "LB", xbox = "LB", ps = "L1"}, {field = "rb", name = "RB", xbox = "RB", ps = "R1"},
    {trigger = "left_trigger", name = "LT", xbox = "LT", ps = "L2"}, {trigger = "right_trigger", name = "RT", xbox = "RT", ps = "R2"},
    {field = "left_stick", name = "L3", xbox = "L3", ps = "L3"}, {field = "right_stick", name = "R3", xbox = "R3", ps = "R3"},
    {field = "a", name = "A", xbox = "A", ps = "Cross"}, {field = "b", name = "B", xbox = "B", ps = "Circle"},
    {field = "x", name = "X", xbox = "X", ps = "Square"}, {field = "y", name = "Y", xbox = "Y", ps = "Triangle"},
    {field = "up", name = "Up", xbox = "Up", ps = "Up"}, {field = "down", name = "Down", xbox = "Down", ps = "Down"},
    {field = "left", name = "Left", xbox = "Left", ps = "Left"}, {field = "right", name = "Right", xbox = "Right", ps = "Right"},
    {field = "start", name = "Start", xbox = "Start", ps = "Options"}, {field = "back", name = "Back", xbox = "Back", ps = "Share"},
}
local PAD_BY_NAME = {}
for _, b in PAD do PAD_BY_NAME[string.lower(b.name)] = b end

-- Keys the game can bind: Ctrl, Shift, Alt, Space, 0-9, A-Z, F1-F12 (in that order in a combo).
local KEYS = {{vk = 0x11, name = "Ctrl"}, {vk = 0x10, name = "Shift"}, {vk = 0x12, name = "Alt"}, {vk = 0x20, name = "Space"}}
for c = 0x30, 0x39 do table.insert(KEYS, {vk = c, name = string.char(c)}) end
for c = 0x41, 0x5a do table.insert(KEYS, {vk = c, name = string.char(c)}) end
for n = 1, 12 do table.insert(KEYS, {vk = 0x6f + n, name = "F" .. n}) end
-- ReTake's own keys, which slow motion can't take.
local TAKEN = {["f10"] = "F10 opens Ghost lines", ["f11"] = "F11 opens the timeline", ["ctrl+r"] = "Ctrl+R goes back"}

local combo = nil     -- what slow motion is on: a combo, or "off"
local listen = nil    -- {began=, released=, pad=, keys=, playstation=}: waiting for buttons
local playstation = false

local function pads()
    local out = {}
    for _, controller in {0, 1, 2, 3, "playstation"} do
        local ok, pad = pcall(reskate.input.gamepad, controller)
        if ok and pad then table.insert(out, pad) end
    end
    return out
end

-- What is held right now: the pad buttons (by PAD index) and keys (by KEYS index).
local function held()
    local pad, keys = {}, {}
    for _, p in pads() do
        if p.playstation then playstation = true end
        local b = p.buttons or {}
        for index, button in PAD do
            if (button.field and b[button.field]) or (button.trigger and (p[button.trigger] or 0) > TRIGGER) then pad[index] = true end
        end
    end
    for index, key in KEYS do
        if reskate.input.key(key.vk) then keys[index] = true end
    end
    return pad, keys
end

local function any(set)
    return next(set) ~= nil
end

-- "Pad.LB+Pad.A" from PAD indexes, or "Ctrl+K" from KEYS indexes, in their order.
local function write(set, list, prefix)
    local parts = {}
    for index, item in list do
        if set[index] then table.insert(parts, prefix .. item.name) end
    end
    return table.concat(parts, "+")
end

-- How a combo reads: "L3 + R3", "L1 + Cross", "Ctrl + K", "Off".
function K.label(text)
    text = text or combo or DEFAULT
    if text == "off" then return "Off" end
    local parts = {}
    for part in string.gmatch(text, "[^+]+") do
        local button = string.match(string.lower(part), "^pad%.(.+)$")
        local found = button and PAD_BY_NAME[button]
        if found then table.insert(parts, playstation and found.ps or found.xbox)
        else table.insert(parts, part) end
    end
    return table.concat(parts, " + ")
end

-- Puts slow motion on a combo (or "off"), and keeps it in the file if asked.
local function apply(text, keep)
    local ok, done, why = pcall(reskate.input.bind, ACTION, text ~= "off" and text or nil)
    if not ok then return false, tostring(done) end
    if done == false then return false, tostring(why) end
    combo = text
    if keep then
        local saved, err = reskate.files.write(FILE, text)
        if not saved then return true, "kept until the game closes only (" .. tostring(err) .. ")" end
    end
    return true
end

-- At load: the combo kept from last time, or L3 + R3.
function K.load()
    local text = reskate.files.read(FILE)
    text = text and string.match(text, "^%s*(.-)%s*$") or ""
    if text == "" then text = DEFAULT end
    local ok = apply(text, false)
    if not ok and text ~= DEFAULT then apply(DEFAULT, false) end
end

function K.current()
    return combo or DEFAULT
end

function K.is_listening()
    return listen ~= nil
end

-- Sets it from text: "off", "default", or a combo as reskate.input.bind takes it ("Pad.LB+Pad.RB", "Ctrl+K").
function K.set(text)
    text = string.match(tostring(text or ""), "^%s*(.-)%s*$")
    local lower = string.lower(text)
    if lower == "off" or lower == "none" then text = "off"
    elseif lower == "default" or lower == "" then text = DEFAULT
    elseif TAKEN[lower] then return false, TAKEN[lower] end
    K.cancel()
    local ok, why = apply(text, true)
    if not ok then
        apply(combo or DEFAULT, false)
        return false, "Can't put slow motion on " .. text .. ": " .. tostring(why)
    end
    local said = text == "off" and "Slow motion has no button now (retake slowmo still turns it on)" or ("Slow motion is on " .. K.label(text))
    if why then said = said .. ": " .. why end
    return true, said
end

-- Starts listening for the buttons to put slow motion on. Clicked again while listening: off.
function K.press()
    if listen then return K.set("off") end
    -- Not on its old combo while you press, or pressing it again would turn slow motion on.
    pcall(reskate.input.bind, ACTION, nil)
    local pad, keys = held()
    listen = {began = U.now(), released = not any(pad) and not any(keys), pad = {}, keys = {}}
    R.toast("Press the button or buttons for slow motion, then let go. Click Slow-mo key again for none.", "info")
    return true
end

-- Stops listening and keeps the combo it had.
function K.cancel(why)
    if not listen then return end
    listen = nil
    apply(combo or DEFAULT, false)
    if why then R.toast(why, "info") end
end

function K.tick()
    if not listen then return end
    if reskate.input.key(VK_ESCAPE) then return K.cancel("Slow motion stays on " .. K.label()) end
    if U.now() - listen.began > LISTEN_MS then return K.cancel("Nothing pressed: slow motion stays on " .. K.label()) end
    local pad, keys = held()
    if not listen.released then
        -- Something was held as it started: only what is pressed after letting go counts.
        if not any(pad) and not any(keys) then listen.released = true end
        return
    end
    for index in pad do listen.pad[index] = true end
    for index in keys do listen.keys[index] = true end
    if any(pad) or any(keys) then return end
    if not any(listen.pad) and not any(listen.keys) then return end
    -- All let go: what was pressed together is the combo. A pad combo beats keys pressed by the way.
    local text = any(listen.pad) and write(listen.pad, PAD, "Pad.") or write(listen.keys, KEYS, "")
    listen = nil
    local ok, why = K.set(text)
    if ok and not string.find(text, "+", 1, true) then why = tostring(why) .. ". It still does what it does in the game too" end
    R.toast(tostring(why), ok and "info" or "warn")
end

return K
