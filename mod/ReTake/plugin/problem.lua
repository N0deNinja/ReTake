-- Report a problem: the player says what went wrong, and ReTake saves it in one file with what the game and
-- ReTake were doing. A flight recorder runs all the time: the last physics steps and ticks, and the log. The
-- timeline opening freezes a copy of it, so the moments before the problem stay in the report however long
-- the player then spends in the timeline and typing.
local U = require("util")
local C = require("clock")
local R = require("report")
local S = require("ui")
local L = require("line")
local P = {}

local SCREEN = "ReTake Report"
local FOLDER = "reports"
local STEPS_KEPT = 1800 -- 30 seconds of the game's physics
local TICKS_KEPT = 3600 -- 25 to 60 seconds of frames, by the frame rate
local SINCE_KEPT = 900  -- ticks after the freeze (in the timeline, typing)
local LOG_LINES = 400
local MARKS_MOST = 2000
local MOST_BYTES = 1000 * 1000 -- the files API takes at most 1 MB a file
local MOST_CHARS = 2000
local VK_BACK, VK_RETURN, VK_CONTROL, VK_ESCAPE = 8, 13, 17, 27

-- ---- the flight recorder -----------------------------------------------------------------------------
local function ring(size)
    return {size = size, n = 0, at = 0, items = {}}
end

local function push(r, item)
    r.at = r.at % r.size + 1
    r.items[r.at] = item
    if r.n < r.size then r.n += 1 end
end

-- Oldest first.
local function list(r)
    local out = table.create(r.n)
    local first = r.n < r.size and 1 or r.at % r.size + 1
    for i = 0, r.n - 1 do out[i + 1] = r.items[(first - 1 + i) % r.size + 1] end
    return out
end

local steps = ring(STEPS_KEPT)
local ticks = ring(TICKS_KEPT)
local tick_count = 0
local frozen = nil -- {steps=, ticks=, at=, tick=, why=}: the recorder as it was
local now_line = {phase = "off", step = 0, length = 0}
local last_tick_at = nil
local drift = nil -- {most=, at=, rows=}: how far a replay is from the recording, while it plays

local STEP_HEAD = "t\tdt\tx\ty\tz\tvx\tvy\tvz\tspeed\tstate\tair\twipe\trag\tsrc\thash\tboard_hash\tphase\tline_step\tline_length\theading\tacross\talong\tup_y\tyaw_rate\tbody_gap\thand_speed"
local TICK_HEAD = "ms\tframe_ms\tphase\tline_step\tline_length\tsince_spawn\tslowed\tclock\tgame_speed\ttimeline\tcounting\tgoing_to\tx\ty\tz\tspeed\tair\tdrift_rough_m\tlx\tly\trx\try\tlt\trt\tbuttons\thand_speed_most\tbody_gap"
local BUTTONS = {{"a", "A"}, {"b", "B"}, {"x", "X"}, {"y", "Y"}, {"lb", "LB"}, {"rb", "RB"}, {"left_stick", "L3"}, {"right_stick", "R3"},
    {"up", "U"}, {"down", "D"}, {"left", "L"}, {"right", "R"}, {"start", "ST"}, {"back", "BK"}}

local function n3(value)
    return value and string.format("%.3f", value) or ""
end

local function flag(value)
    return value and "1" or "0"
end

local hand_most = nil -- the hands' fastest against the pelvis since the last frame's row
C.listen(function(s)
    if s.hand_speed then hand_most = math.max(hand_most or 0, s.hand_speed) end
    local speed =s.vx and math.sqrt(s.vx ^ 2 + (s.vy or 0) ^ 2 + (s.vz or 0) ^ 2)
    push(steps, table.concat({
        string.format("%.4f", s.t), string.format("%.5f", s.dt or 0), n3(s.x), n3(s.y), n3(s.z), n3(s.vx), n3(s.vy), n3(s.vz), n3(speed),
        tostring(s.state or ""), flag(s.air), flag(s.wipe), flag(s.rag), tostring(s.src or ""), tostring(s.hash or ""), tostring(s.bhash or ""),
        now_line.phase, tostring(now_line.step), tostring(now_line.length),
        s.vx and n3(math.deg(math.atan2(s.vx, s.vz or 0))) or "", n3(s.across), n3(s.along), n3(s.up_y), n3(s.yaw_rate), n3(s.body_gap), n3(s.hand_speed),
    }, "\t"))
end)

local function pad_text(pad)
    if not pad then return {"", "", "", "", "", "", ""} end
    local pressed = {}
    local b = pad.buttons or {}
    for _, pair in BUTTONS do
        if b[pair[1]] then table.insert(pressed, pair[2]) end
    end
    return {string.format("%.2f", pad.left_x or 0), string.format("%.2f", pad.left_y or 0), string.format("%.2f", pad.right_x or 0),
        string.format("%.2f", pad.right_y or 0), string.format("%.2f", pad.left_trigger or 0), string.format("%.2f", pad.right_trigger or 0),
        table.concat(pressed, "+")}
end

-- Roughly how far the skater is from where the recording had the board, while a replay plays: this frame's last step
-- against the recording at the line's step as this frame read it, which can be a step or two apart, a metre or more at
-- speed. The report's catch-up line takes ReSkate.dll's own measure instead (tas.status().replay_off), exact to the step.
local function replay_drift(line)
    local s = C.last
    if line.phase ~= "running_up" or not s or not s.x or s.src ~= "board" then return nil end
    local ok, at = pcall(reskate.tas.line_position, line.step)
    if not ok or not at then return nil end
    return U.dist(s.x, s.y, s.z, at.x, at.y, at.z)
end

-- Once a tick, from main.lua.
local function record(now)
    local live = L.live()
    local line = live.line
    now_line = line
    tick_count += 1
    local skater = reskate.skater.get()
    local gap = replay_drift(line)
    if gap then
        drift = drift or {most = 0, at = 0, rows = 0}
        drift.rows += 1
        if gap > drift.most then drift.most, drift.at = gap, line.step end
    elseif drift and line.phase ~= "running_up" then
        local status = reskate.tas.status()
        if status.replay_off then
            R.line(string.format("[report] the replay was at most %.3f m from the recording before a step was put back (at step %d)",
                status.replay_off, status.replay_off_at or 0))
        else
            R.line(string.format("[report] the replay was at most %.2f m from the recording, roughly (at step %d, %d frames measured)", drift.most, drift.at, drift.rows))
        end
        drift = nil
    end
    local pad = live.pad ~= nil and reskate.input.gamepad(live.pad) or nil
    local p = skater and skater.position
    local row = {
        tostring(now), last_tick_at and tostring(now - last_tick_at) or "", line.phase, tostring(line.step), tostring(line.length), tostring(line.since_spawn or ""),
        flag(live.slowed), string.format("%g", live.clock), string.format("%g", live.speed), flag(live.timeline), flag(live.counting), live.going_to and tostring(live.going_to) or "",
        n3(p and p.x), n3(p and p.y), n3(p and p.z), n3(skater and skater.speed), skater and flag(skater.airborne) or "", gap and string.format("%.3f", gap) or "",
    }
    for _, value in pad_text(pad) do table.insert(row, value) end
    -- The arms over the steps since the last frame: at full speed one or two, slowed one or none.
    table.insert(row, n3(hand_most))
    table.insert(row, n3(C.last and C.last.body_gap))
    hand_most = nil
    push(ticks, table.concat(row, "\t"))
    last_tick_at = now
end

-- A copy of the recorder now: the report keeps it whatever happens after.
function P.freeze(why)
    frozen = {steps = list(steps), ticks = list(ticks), at = U.now(), tick = tick_count, why = why}
end

-- ---- the report file ---------------------------------------------------------------------------------
local function clock_text(step)
    local seconds = (tonumber(step) or 0) / 60
    return string.format("%d:%05.2f", math.floor(seconds / 60), seconds % 60)
end

local function describe(value)
    local kind = type(value)
    if kind == "vector" then return string.format("(%.3f, %.3f, %.3f)", value.x, value.y, value.z) end
    if kind == "number" then return string.format("%.6g", value) end
    if kind ~= "table" then return tostring(value) end
    local parts = {}
    for key, item in value do
        table.insert(parts, tostring(key) .. "=" .. (type(item) == "table" and "{...}" or describe(item)))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function fields(out, title, t)
    table.insert(out, "")
    table.insert(out, "== " .. title .. " ==")
    if type(t) ~= "table" then
        table.insert(out, tostring(t))
        return
    end
    local keys = {}
    for key in t do table.insert(keys, tostring(key)) end
    table.sort(keys)
    for _, key in keys do table.insert(out, key .. ": " .. describe(t[key])) end
end

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return "could not read: " .. tostring(value)
end

local function build(description)
    local out = {}
    local function add(line) table.insert(out, line) end
    add("ReTake problem report")
    add("ReTake " .. L.version .. ", saved " .. os.date("%Y-%m-%d %H:%M:%S"))
    add("")
    add("== What happened, in the player's words ==")
    add(description ~= "" and description or "(nothing written)")

    local snap = L.snapshot()
    fields(out, "ReTake now", snap.state)
    fields(out, "The line (tas.line)", safe(reskate.tas.line))
    fields(out, "The runtime (tas.status)", safe(reskate.tas.status))
    fields(out, "The skater (skater.get)", safe(reskate.skater.get))
    fields(out, "Last physics step", C.last)
    fields(out, "Game", {
        in_session = safe(U.in_session),
        physics_steps_seen = C.steps,
        game_seconds_seen = C.sim_t,
        poses = C.pose_names,
        frozen_when = frozen and frozen.why,
        frozen_ms_before_save = frozen and (U.now() - frozen.at),
        gamepad = snap.state.pad,
    })

    add("")
    add("== The line's marks (start, retakes, bails) ==")
    add("start: " .. describe(snap.start))
    local joins, bails = {}, {}
    for _, step in snap.joins do table.insert(joins, clock_text(step) .. " (" .. step .. ")") end
    for _, step in snap.bails do table.insert(bails, clock_text(step) .. " (" .. step .. ")") end
    add("retakes at: " .. (#joins > 0 and table.concat(joins, ", ") or "none"))
    add("bails at: " .. (#bails > 0 and table.concat(bails, ", ") or "none"))

    local runs = reskate.files.list("results/runs")
    if type(runs) == "table" and #runs > 0 then
        table.sort(runs)
        add("")
        add("== Latest files in results/runs ==")
        for index = math.max(1, #runs - 9), #runs do add(runs[index]) end
    end

    add("")
    add("== ReTake's log, latest " .. LOG_LINES .. " lines ==")
    for _, line in R.tail(LOG_LINES) do add(line) end

    -- What was recorded, the biggest part: cut down from its oldest end to fit the 1 MB a file.
    local head = table.concat(out, "\n")
    local marks = {"step\tx\ty\tz\tair"}
    local stride = math.max(1, math.ceil(#snap.marks / MARKS_MOST))
    for index = 1, #snap.marks, stride do
        local m = snap.marks[index]
        table.insert(marks, string.format("%d\t%.3f\t%.3f\t%.3f\t%s", m.step, m.position.x, m.position.y, m.position.z, flag(m.air)))
    end
    local before = frozen or {steps = list(steps), ticks = list(ticks), tick = tick_count, why = "the report"}
    local since = {}
    if frozen then
        local all = list(ticks)
        local count = math.min(tick_count - frozen.tick, #all, SINCE_KEPT)
        for index = #all - count + 1, #all do table.insert(since, all[index]) end
    end
    -- The heading row, then the rows (copied, so cutting them down leaves the recorder alone).
    local function with_head(heading, rows)
        local out = table.create(#rows + 1)
        out[1] = heading
        table.move(rows, 1, #rows, 2, out)
        return out
    end
    local sections = {
        {"The line's path, every " .. (stride * 6) .. " steps (" .. #snap.marks .. " marks)", marks},
        {"Physics steps before " .. before.why .. ", oldest first", with_head(STEP_HEAD, before.steps)},
        {"Frames before " .. before.why .. ", oldest first", with_head(TICK_HEAD, before.ticks)},
        {"Frames after that, until the report was saved", with_head(TICK_HEAD, since)},
    }
    local size = #head + 200
    for _, section in sections do
        for _, row in section[2] do size += #row + 1 end
        size += #section[1] + 10
    end
    -- Over the limit: the oldest frames go first, then the oldest steps.
    local cut = {3, 2, 4, 1}
    for _, which in cut do
        local rows = sections[which][2]
        while size > MOST_BYTES and #rows > 2 do
            size -= #table.remove(rows, 2) + 1
        end
    end
    local text = {head}
    for _, section in sections do
        table.insert(text, "")
        table.insert(text, "== " .. section[1] .. " (" .. (#section[2] - 1) .. " rows) ==")
        table.insert(text, table.concat(section[2], "\n"))
    end
    table.insert(text, "")
    table.insert(text, "== end ==")
    local all = table.concat(text, "\n") .. "\n"
    if #all > MOST_BYTES then all = string.sub(all, 1, MOST_BYTES - 40) .. "\n== cut at 1 MB ==\n" end
    return all
end

-- ---- the window -------------------------------------------------------------------------------------
local form = nil -- {text=, from_timeline=, saved=, error=, keys..., wrapped=, wrapped_for=}

local function drop_last(s)
    local i = #s
    if i == 0 then return s end
    while i > 1 and bit32.band(string.byte(s, i), 0xC0) == 0x80 do i -= 1 end
    return string.sub(s, 1, i - 1)
end

local function drop_word(s)
    s = string.gsub(s, "%s+$", "")
    return (string.gsub(s, "[^%s]+$", ""))
end

function P.is_open()
    return form ~= nil
end

function P.open(from_timeline)
    if form then return true end
    if not from_timeline then P.freeze("the report window opened") end
    reskate.ui.open(SCREEN)
    reskate.input.text(true) -- whatever was typed before is not part of it
    form = {text = "", from_timeline = from_timeline, left = true, enter = true, escape = true, back = false, back_at = 0, opened = U.now()}
    R.line("[report] report window open")
    return true
end

-- Back to the timeline, or to the game.
local function close_form()
    local was = form
    form = nil
    if not was then return end
    if was.from_timeline and L.resume_player() then return end
    reskate.ui.close()
end

-- The timeline closed under it (a load, a session): nothing to go back to.
function P.drop()
    form = nil
end

function P.on_screen_closed(title)
    if title ~= SCREEN or not form then return end
    close_form()
end

local function save()
    local stem = FOLDER .. "/retake-report-" .. os.date("%Y%m%d-%H%M%S")
    local name = stem .. ".txt"
    for n = 2, 9 do -- two in the same second: the second one gets its own name
        if reskate.files.read(name) == nil then break end
        name = stem .. "-" .. n .. ".txt"
    end
    local ok_build, text = pcall(build, form.text)
    if not ok_build then
        text = "ReTake problem report (the full report failed: " .. tostring(text) .. ")\n\n" .. form.text .. "\n\n" .. table.concat(R.tail(LOG_LINES), "\n") .. "\n"
    end
    -- With a line, the DLL adds its every step (the controller as recorded, the board) after the text: it may be
    -- larger than the 1 MB a plugin's own file may be. Without the call (an older ReSkate.dll), the text alone.
    local ok, why = false, "no line"
    local phase, length = L.phase()
    if reskate.tas.line_save and phase ~= "off" and length > 0 then
        local called, saved, reason = pcall(reskate.tas.line_save, name, text)
        ok, why = called and saved, called and reason or saved
        if not ok then R.line("[report] the line's steps could not be added: " .. tostring(why)) end
    end
    if not ok then ok, why = reskate.files.write(name, text) end
    if not ok then
        form.error = "Could not save it: " .. tostring(why)
        return
    end
    form.saved = name
    form.error = nil
    R.line("[report] saved " .. name .. " (" .. #text .. " bytes)")
    R.flush()
end

local function typing(now)
    local typed = reskate.input.text(true)
    if typed ~= "" and #form.text < MOST_CHARS * 2 then
        form.text ..= typed
    end
    local ctrl = reskate.input.key(VK_CONTROL)
    local back = reskate.input.key(VK_BACK)
    if back then
        if not form.back or now >= form.back_at then
            form.text = ctrl and drop_word(form.text) or drop_last(form.text)
            form.back_at = now + (form.back and 35 or 450)
            form.back = true
        end
    else
        form.back = false
    end
    local enter = reskate.input.key(VK_RETURN)
    if enter and not form.enter then
        if ctrl then save() else form.text ..= "\n" end
    end
    form.enter = enter
    if utf8.len(form.text) and utf8.len(form.text) > MOST_CHARS then
        form.text = string.sub(form.text, 1, utf8.offset(form.text, MOST_CHARS + 1) - 1)
    end
end

-- The window's parts, in pixels; sizes given at 1080 lines and scaled.
local width, height = 1920, 1080
local function layout()
    local k = height / 1080
    local w, h = math.min(920 * k, width - 32 * k), (form and form.saved and 420 or 640) * k
    local box = {x0 = (width - w) / 2, y0 = (height - h) / 2}
    box.x1, box.y1 = box.x0 + w, box.y0 + h
    local pad = 34 * k
    local field = {x0 = box.x0 + pad, x1 = box.x1 - pad, y0 = box.y0 + 176 * k, y1 = box.y0 + 496 * k}
    local by0, by1 = box.y1 - 78 * k, box.y1 - 30 * k
    local buttons = {
        save = {x0 = box.x1 - pad - 236 * k, x1 = box.x1 - pad, y0 = by0, y1 = by1},
    }
    buttons.cancel = {x0 = buttons.save.x0 - 12 * k - 150 * k, x1 = buttons.save.x0 - 12 * k, y0 = by0, y1 = by1}
    buttons.folder = {x0 = box.x0 + pad, x1 = box.x0 + pad + 200 * k, y0 = by0, y1 = by1}
    return k, box, field, buttons, pad
end

local function inside(p, r)
    return p.x >= r.x0 and p.x <= r.x1 and p.y >= r.y0 and p.y <= r.y1
end

local function click(name)
    if form.saved then
        if name == "folder" then
            local ok, why = reskate.files.reveal(FOLDER)
            if not ok then form.error = "Could not open the folder: " .. tostring(why) end
        elseif name == "save" or name == "cancel" then
            close_form()
        end
        return
    end
    if name == "save" then save()
    elseif name == "cancel" then close_form() end
end

function P.tick(now)
    record(now)
    if not form then return end
    if form.saved then
        reskate.input.text(true) -- keeps Esc ours, so it goes back rather than closing everything
    else
        typing(now)
        if not form then return end
    end
    local escape = reskate.input.key(VK_ESCAPE)
    if escape and not form.escape then
        close_form()
        return
    end
    form.escape = escape
    if form.saved then
        local enter = reskate.input.key(VK_RETURN)
        if enter and not form.enter then
            close_form()
            return
        end
        form.enter = enter
    end
    local mouse = reskate.input.cursor()
    if mouse then
        if mouse.left and not form.left then
            local _, _, _, buttons = layout()
            for name, r in buttons do
                if inside(mouse.position, r) and (name ~= "folder" or form.saved) then
                    form.left = true
                    click(name)
                    return
                end
            end
        end
        form.left = mouse.left
    end
end

-- ---- drawing ----------------------------------------------------------------------------------------
local v = S.v

-- Words to lines that fit `w`; a word too long for a line is broken up.
local function wrap(d, text, style, w)
    local lines = {}
    for paragraph in string.gmatch(text .. "\n", "([^\n]*)\n") do
        local line = ""
        for word in string.gmatch(paragraph, "%S+") do
            local try = line == "" and word or line .. " " .. word
            if d:measure(try, style).x <= w then
                line = try
            else
                if line ~= "" then table.insert(lines, line) end
                line = ""
                if d:measure(word, style).x <= w then
                    line = word
                else
                    for char in string.gmatch(word, "[%z\1-\127\194-\244][\128-\191]*") do
                        if d:measure(line .. char, style).x > w and line ~= "" then
                            table.insert(lines, line)
                            line = ""
                        end
                        line ..= char
                    end
                end
            end
        end
        table.insert(lines, line)
    end
    return lines
end

function P.draw(d)
    if not form then return end
    local size = d:size()
    width, height = size.x, size.y
    local k, box, field, buttons, pad = layout()
    local mouse = reskate.input.cursor()
    S.scrim(d, width, height)
    S.panel(d, box, k, 41)
    local x = box.x0 + pad
    local th = S.title(d, x, box.y0 + 22 * k, form.saved and "Report saved" or "Report a problem", k)

    if form.saved then
        local body = S.font(16, S.SOFT, "body", true)
        local y = box.y0 + 34 * k + th
        local when = frozen and frozen.why == "you opened the timeline" and "before you opened the timeline" or "before this window opened"
        for _, line in wrap(d, "Send us this file. It has what you wrote, and what the game and ReTake were doing just " .. when .. ".", body, box.x1 - pad - x) do
            d:text(v(x, y), line, body)
            y += 25 * k
        end
        y += 16 * k
        local path = "Mods\\.reskate_plugin_data\\ReTake\\" .. string.gsub(form.saved, "/", "\\")
        local path_style = S.font(15, S.INK, "bold")
        S.tile(d, {x0 = x, x1 = box.x1 - pad, y0 = y, y1 = y + 48 * k}, S.PAPER, 43, k)
        for _, line in wrap(d, path, path_style, box.x1 - pad - x - 32 * k) do
            d:text(v(x + 16 * k, y + 24 * k - d:measure(line, path_style).y / 2), line, path_style)
            break
        end
        y += 72 * k
        d:text(v(x, y), "Nothing is sent anywhere by ReTake. You choose who gets the file.", S.font(14, S.MUTED, "body", true))
        if form.error then S.note(d, x, y + 30 * k, form.error, k, true) end
        S.button(d, buttons.folder, "Open folder", {kind = "quiet", mouse = mouse, k = k})
        S.button(d, buttons.save, form.from_timeline and "Back to timeline" or "Done", {kind = "primary", mouse = mouse, k = k})
        return
    end

    local intro = S.font(15, S.SOFT, "body", true)
    local y = box.y0 + 30 * k + th
    for _, line in wrap(d, "What went wrong, and what were you doing just before? ReTake saves it with the last 30 seconds of the game, so we can see what happened.", intro, box.x1 - pad - x) do
        d:text(v(x, y), line, intro)
        y += 23 * k
    end

    -- The field: the game's white text box, ringed in teal: it always has the keyboard.
    S.tile(d, {x0 = field.x0 - 4 * k, x1 = field.x1 + 4 * k, y0 = field.y0 - 4 * k, y1 = field.y1 + 4 * k}, S.ACCENT, 44, k)
    S.tile(d, field, S.PAPER, 45, k)
    local style = S.font(18, S.INK, "body")
    local inner = 18 * k
    local line_h = 28 * k
    local room = math.floor((field.y1 - field.y0 - 2 * inner) / line_h)
    local caret_on = math.floor((U.now() - form.opened) / 500) % 2 == 0
    local caret = {colour = S.INK, fill = true}
    if form.text == "" then
        local hint = S.font(18, "#6e6e6e", "body")
        local hy = field.y0 + inner
        for _, line in wrap(d, "For example: I went back to 0:12, just before the rail, and in the replay the skater fell off the rail before the countdown.", hint, field.x1 - field.x0 - 2 * inner) do
            d:text(v(field.x0 + inner, hy), line, hint)
            hy += line_h
        end
        if caret_on then d:rect(v(field.x0 + inner, field.y0 + inner), v(field.x0 + inner + 2.5 * k, field.y0 + inner + 24 * k), caret) end
    else
        if form.wrapped_for ~= form.text or form.wrapped_w ~= field.x1 - field.x0 then
            form.wrapped = wrap(d, form.text, style, field.x1 - field.x0 - 2 * inner - 6 * k)
            form.wrapped_for, form.wrapped_w = form.text, field.x1 - field.x0
        end
        local lines = form.wrapped
        local first = math.max(1, #lines - room + 1) -- the end, where the typing is, stays in view
        local ly = field.y0 + inner
        for index = first, #lines do
            d:text(v(field.x0 + inner, ly), lines[index], style)
            ly += line_h
        end
        if caret_on then
            local last = lines[#lines] or ""
            local cx = field.x0 + inner + (last ~= "" and d:measure(last, style).x + 2 * k or 0)
            local cy = field.y0 + inner + (#lines - first) * line_h
            d:rect(v(cx, cy), v(cx + 2.5 * k, cy + 24 * k), caret)
        end
    end
    local count = string.format("%d / %d", utf8.len(form.text) or #form.text, MOST_CHARS)
    local count_style = S.font(13, S.MUTED, "bold", true)
    local cs = d:measure(count, count_style)
    d:text(v(field.x1 - cs.x, field.y1 + 14 * k), count, count_style)
    local kx, ky = field.x0, field.y1 + 12 * k
    kx += S.keycap(d, kx, ky, "Enter", "New line", k) + 22 * k
    S.keycap(d, kx, ky, "Ctrl+Enter", "Save", k)
    if form.error then S.note(d, field.x0, field.y1 + 44 * k, form.error, k, true) end
    S.button(d, buttons.cancel, "Cancel", {mouse = mouse, k = k, key = "Esc"})
    S.button(d, buttons.save, "Save report", {kind = "primary", mouse = mouse, k = k})
end

reskate.ui.screen(SCREEN, function() end, {panel = false})

return P
