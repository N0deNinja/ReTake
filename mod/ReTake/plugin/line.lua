-- A line: skated from a standing start, recorded as one take. F11 slows the game right down and opens a
-- timeline; drag it and a drawn skater shows each moment at once. Replay from here catches up to that moment
-- (it plays the line from its start, locked, so the game's own state comes along), slows right down there,
-- counts 3, 2, 1, and the controller carries on from it, the failed attempt forgotten. Play whole line gives the
-- finished line back as one take.
local U = require("util")
local C = require("clock")
local R = require("report")
local L = {}

local STEPS = 60
local START_STEP = 180 -- steps after the teleport a line starts, and every going back runs from
local COUNT_MS = 3000
local HINT_MS = 8000
local SLOW = 0.05       -- the timeline on the ground: smooth slow motion, the steps shorter
local COUNT_CLOCK = 0.05 -- a countdown in a flight on the board: the clock alone, so its step stays right. Three steps a second
local AIR_SOON_STEPS = 18 -- a countdown just before a takeoff counts as in a flight: it would change the step mid-flight
local LAST_RUN_STEPS = 60 -- the last of a catch-up runs at full speed
local GO_MS = 800
local MARK_EVERY = 6
local RETRIES = 3
local NO_SKATER_MS = 5000
local ROWS_KEPT = 36000
local PROBE_BEFORE, PROBE_AFTER = 120, 120
local VK_RETURN, VK_LEFT, VK_RIGHT, VK_F11 = 13, 37, 39, 122
local SCREEN = "TAS Timeline"

local line = {phase = "off", length = 0, step = 0, since_spawn = 0}
local start = nil   -- {position=, heading=, on_board=}: where the line began
local marks = {}    -- {step=, position=}, a tenth of a second apart, oldest first
local bails = {}    -- steps of the line where the skater bailed
local joins = {}    -- steps of the line where a retake took over
local pending = nil -- {from=, to=, hand_over=, retries=}, while going back
local count = nil   -- {ends=}: slowed right down at the moment
local slowed = false
local clock_now = 1
local applied_speed = 1 -- what reskate.time.slow was last asked for
local slowmo_on = false
local slowmo_speed = 0.25
local SLOWMOS = {0.5, 0.25, 0.1}
local catch_up = 4 -- how fast going back runs
local CATCH_UPS = {1, 2, 4, 8}
local no_skater_since = nil
local go_until = -math.huge
local previous_phase = "off"
local filming = nil -- {rows=, joins=}, while the whole line plays
local probe = nil   -- {rows=, to=, go=}: the steps around a join, for the report
local player = nil  -- the timeline: {cursor=, dragging=, left=, confirm=, f11=, enter=, repeat_at=, ghost=, shown=, dir=}
local closed_at = -math.huge
local listen_at = -math.huge
local no_bail = false -- the game's wipeouts off, all of them
local hint_text = "Start a line"
local hint_until = U.now() + HINT_MS
local width, height = 1920, 1080

local function slow_down(on)
    slowed = on
    reskate.tas.line_paused(on)
    applied_speed = on and SLOW or 1
    return reskate.time.slow(applied_speed)
end

local function set_clock(scale)
    if clock_now == scale then return true end
    local ok, why = reskate.tas.clock(scale)
    if ok then clock_now = scale end
    return ok, why
end

-- In a flight on the board, the one thing a change of step breaks: it is a path read once a step. A bail is not one.
local function board_in_air()
    local state = C.last and C.last.state
    return state == 200 or state == 201
end

-- Whatever was slowed or sped up, back to the game's own.
local function full_speed()
    set_clock(1)
    return slow_down(false)
end

local function find_pad()
    for _, controller in {0, 1, 2, 3, "playstation"} do
        if reskate.input.gamepad(controller) then return controller end
    end
    return nil
end

local function clock_text(steps)
    local seconds = steps / STEPS
    return string.format("%d:%05.2f", math.floor(seconds / 60), seconds % 60)
end

local function mark_index(step)
    local low, high, found = 1, #marks, 1
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if marks[middle].step <= step then
            found = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return found
end

-- Did the line leave the ground just after this step?
local function air_soon(step)
    for index = mark_index(step), #marks do
        local mark = marks[index]
        if mark.step > step + AIR_SOON_STEPS then return false end
        if mark.step >= step and mark.air then return true end
    end
    return false
end

local function forget_after(step)
    while #marks > 0 and marks[#marks].step > step do table.remove(marks) end
    while #bails > 0 and bails[#bails] > step do table.remove(bails) end
    while #joins > 0 and joins[#joins] > step do table.remove(joins) end
end

-- The drawn skater and the camera on it go away; the real one comes back.
local function end_preview()
    if player and player.shown then
        player.shown = false
        reskate.skater.hide(false)
        reskate.camera.release()
    end
end

-- How smoothly it ran, for the report.
local function note_player()
    local seconds = (U.now() - player.opened) / 1000
    if seconds > 1 then
        R.line(string.format("[line] timeline open %.1f s: %.0f ticks a second, opened %s", seconds, player.ticks / seconds, player.was_air and "in a flight" or "not in a flight"))
    end
end

L.on_report = nil      -- the timeline's Report a problem: problem.lua opens its window
L.report_open = nil    -- function: is that window open (the timeline then waits under it)
L.on_timeline = nil    -- function(open): the timeline opening (true) or going (false)

local function close_player()
    if not player then return end
    note_player()
    end_preview()
    player = nil
    closed_at = U.now()
    if L.on_timeline then L.on_timeline(false) end
    reskate.ui.close()
end

local function reporting()
    return L.report_open ~= nil and L.report_open()
end

-- Back to a moment: where the line started, then up to it. The teleport first: refused (at most two a
-- second), nothing has happened.
local function seek(to, hand_over, retries)
    if not start then return false, "no line is recorded" end
    full_speed()
    count = nil
    local ok, why = reskate.skater.teleport(start.position, start.heading, {on_board = start.on_board})
    if not ok then return false, why end
    ok, why = reskate.tas.line_seek(0, to, START_STEP, hand_over)
    if not ok then return false, why end
    local soon = (retries and pending and pending.air_soon) or air_soon(to)
    pending = {from = 0, to = to, hand_over = hand_over, retries = retries or 0, asked_at = U.now(), air_soon = soon}
    if retries then return true end
    if hand_over then
        R.line(string.format("[line] back to %s of %s", clock_text(to), clock_text(line.length)))
        forget_after(to)
        if to > 0 then table.insert(joins, to) end
        probe = {rows = {}, to = to}
        filming = nil
    else
        R.line(string.format("[line] playing the whole line, %s, %d joins", clock_text(to), #joins))
        filming = {rows = {}, joins = {table.unpack(joins)}}
        probe = nil
    end
    return true
end

-- Slowed right down: 3, 2, 1, then full speed and the controller is yours.
local function count_down(flying)
    -- From the timeline it is already slow, in its way. Else smooth slow motion, but for a flight.
    reskate.tas.line_paused(true)
    if not slowed and clock_now == 1 then
        local ok, why
        if flying then ok, why = set_clock(COUNT_CLOCK) else ok, why = slow_down(true) end
        if not ok then
            reskate.log("[line] the game would not slow down: " .. tostring(why))
            reskate.tas.line_paused(false)
            reskate.tas.line_go()
            return
        end
    end
    reskate.tas.line_hold()
    count = {ends = U.now() + COUNT_MS, began = U.now(), ticks = 0, how = clock_now ~= 1 and "clock" or "slow motion"}
end

local function save_film()
    local film = filming
    filming = nil
    if not film then return end
    local rows = {"step\tx\ty\tz\tvx\tvy\tvz\tstate\tair\twipe\trag\tjoin"}
    local is_join = {}
    for _, step in film.joins do is_join[step] = true end
    for index, row in film.rows do
        row[12] = is_join[index - 1] and "1" or "0"
        table.insert(rows, table.concat(row, "\t"))
    end
    R.data("results/runs/" .. os.date("%Y%m%d-%H%M%S") .. "_line.tsv", table.concat(rows, "\n") .. "\n")
    R.line(string.format("[line] played %d steps, joins at: %s", #film.rows, table.concat(film.joins, " ")))
    R.flush()
end

local function save_probe()
    local p = probe
    probe = nil
    if not p or #p.rows == 0 then return end
    local rows = {"phase\tstep\tx\ty\tz\tspeed\troot_gap\tstate\tair\twipe"}
    local peak_after, speed_at = 0, 0
    for _, row in p.rows do
        table.insert(rows, table.concat(row, "\t"))
        if row[1] == "after" then peak_after = math.max(peak_after, tonumber(row[6]) or 0)
        else speed_at = tonumber(row[6]) or speed_at end
    end
    R.data("results/runs/" .. os.date("%Y%m%d-%H%M%S") .. "_join.tsv", table.concat(rows, "\n") .. "\n")
    R.line(string.format("[line] join at %s: speed %.1f m/s going in, peak %.1f m/s in the 2 s after", clock_text(p.to), speed_at, peak_after))
    R.flush()
end

C.listen(function(s)
    if not s.x then return end
    local function f(v) return string.format("%.4f", v or 0) end
    if filming and line.phase == "running_up" and #filming.rows < ROWS_KEPT then
        table.insert(filming.rows, {#filming.rows, f(s.x), f(s.y), f(s.z), f(s.vx), f(s.vy), f(s.vz), tostring(s.state or ""),
            s.air and "1" or "0", s.wipe and "1" or "0", s.rag and "1" or "0", "0"})
    end
    if probe then
        -- The last steps of the catching up and the first after the controller takes over.
        local going_in = line.phase == "running_up" and probe.to - line.step <= PROBE_BEFORE
        if going_in or probe.go then
            local speed = math.sqrt((s.vx or 0) ^ 2 + (s.vy or 0) ^ 2 + (s.vz or 0) ^ 2)
            local root = reskate.skater.position()
            local gap = root and U.dist(s.x, s.y, s.z, root.x, root.y, root.z) or -1
            table.insert(probe.rows, {probe.go and "after" or "before", line.step, f(s.x), f(s.y), f(s.z), f(speed), f(gap), tostring(s.state or ""), s.air and "1" or "0", s.wipe and "1" or "0"})
            if probe.go then
                probe.go -= 1
                if probe.go <= 0 then save_probe() end
            end
        end
    end
end)

-- What the game says a bail was: the cause tells a fall from anything else.
function L.on_bail(e)
    if line.phase == "live" then table.insert(bails, line.length) end
    local parts = {}
    if type(e) == "table" then
        for key, value in e do table.insert(parts, tostring(key) .. "=" .. tostring(value)) end
    end
    local last = C.last
    R.line(string.format("[line] bail: %s; %.1f m/s, falling %.1f m/s", table.concat(parts, " "),
        last and math.sqrt((last.vx or 0) ^ 2 + (last.vy or 0) ^ 2 + (last.vz or 0) ^ 2) or -1, last and -(last.vy or 0) or -1))
    R.flush()
end

-- Stops the line (a test needs the controller).
function L.suspend()
    close_player()
    full_speed()
    count, pending = nil, nil
    if line.phase ~= "off" then reskate.tas.line_stop() end
end

-- A new line: stops here, and after the countdown you go.
function L.new_line()
    if U.in_session() then return false, "ReTake is offline only" end
    full_speed() -- whatever comes of it, the game does not stay slowed down
    local s = reskate.skater.get()
    if not s then return false, "there is no skater yet" end
    if s.airborne then return false, "start a line on the ground" end
    local pad = find_pad()
    if pad == nil then return false, "connect a controller to record a line" end
    local ok, why = reskate.skater.teleport(s.position, s.heading, {on_board = true})
    if not ok then return false, why end
    ok, why = reskate.tas.line_start(pad, START_STEP)
    if not ok then return false, why end
    start = {position = s.position, heading = s.heading, on_board = true}
    marks, bails, joins = {}, {}, {}
    count, filming, probe = nil, nil, nil
    pending = {from = 0, to = 0, hand_over = true, retries = 0, asked_at = U.now()}
    R.line("[line] new line")
    return true
end

function L.stop()
    L.suspend()
    reskate.console.print("ReTake: line off. retake new starts another")
end

L.on_stop_all = nil -- optional: anything else to stop with Stop all

-- The player's own slow motion, on and off (both sticks). The speed the game runs at follows it in L.tick.
function L.toggle_slowmo()
    if U.in_session() then return false, "ReTake is offline only" end
    slowmo_on = not slowmo_on
    return true
end

function L.set_slowmo_speed(speed)
    slowmo_speed = U.clamp(speed, 0.05, 0.9)
    return true
end

-- The game's wipeouts off or on. A hard landing's bail is decided past any limit that can be tuned.
function L.toggle_bails()
    if U.in_session() then return false, "ReTake is offline only" end
    local ok, why = reskate.tas.no_bail(not no_bail)
    if not ok then return false, why end
    no_bail = not no_bail
    R.line(no_bail and "[line] bails off" or "[line] bails on")
    return true
end

-- Stops everything the mod is doing, at once: recording, going back, playing, the countdown, the slow motion and
-- the tests. The controller is yours. The line stays on the timeline to go back in, or to replace.
function L.stop_all()
    close_player()
    full_speed()
    count, pending, filming, probe = nil, nil, nil, nil
    slowmo_on = false
    if no_bail then
        no_bail = false
        reskate.tas.no_bail(false)
    end
    if line.phase ~= "off" then reskate.tas.line_halt() end
    if L.on_stop_all then L.on_stop_all() end
    hint_until = U.now() + HINT_MS
    hint_text = "Everything stopped.  F11: timeline"
    R.line("[line] everything stopped")
    return true
end

function L.set_catch_up(speed)
    catch_up = U.clamp(speed, 1, 8)
    return true
end

local function going_back()
    return line.phase == "seeking" or line.phase == "counting" or line.phase == "running_up"
end

-- One press: back that far. Pressed while going back, further back from the same place.
function L.back(seconds)
    if U.in_session() then return false, "ReTake is offline only" end
    if player then return false, "the timeline is open" end
    if reporting() then return true end -- Ctrl+R while typing a report: nothing
    if line.phase == "off" or line.length == 0 then return false, "no line is recording: F11, New line here" end
    local base = line.length
    if pending and pending.hand_over and going_back() then base = pending.to end
    return seek(math.max(0, base - math.floor(seconds * STEPS + 0.5)), true)
end

function L.play_whole()
    if line.phase == "off" or line.length == 0 then return false, "no line is recorded" end
    close_player()
    return seek(line.length, false)
end

-- Out of the timeline without having picked anything: straight on from where it stopped.
local function carry_on()
    close_player()
    if line.phase == "live" then
        count_down(board_in_air())
        return true
    end
    full_speed()
    return true
end

function L.toggle_player()
    if reporting() then return true end -- F11 while writing a report: the report keeps the keys
    if player then return carry_on() end
    if U.now() - closed_at < 300 then return true end -- the press that closed it
    if U.in_session() then return false, "ReTake is offline only" end
    -- Going back or playing, F11 stops it and opens the timeline, so there is always a way out.
    if going_back() then
        pending, filming, probe = nil, nil, nil
        reskate.tas.line_halt()
        set_clock(1)
    end
    set_clock(1)
    local ok, why = slow_down(true)
    if not ok then return false, why end
    count = nil
    reskate.ui.open(SCREEN)
    player = {was_air = board_in_air(), opened = U.now(), ticks = 0, cursor = line.length, following = true, dragging = false, left = true, confirm = false, f11 = true, enter = true, repeat_at = 0}
    if L.on_timeline then L.on_timeline(true) end
    return true
end

-- Back to the timeline from the report window, as it was. False when it has gone in the meantime.
function L.resume_player()
    if not player then return false end
    reskate.ui.open(SCREEN)
    player.left, player.f11, player.enter, player.dragging = true, true, true, false
    return true
end

function L.on_screen_closed(title)
    if title ~= SCREEN or not player then return end
    note_player()
    end_preview()
    player = nil
    closed_at = U.now()
    if L.on_timeline then L.on_timeline(false) end
    local ok, why = carry_on()
    if not ok then R.toast(tostring(why), "warn") end
end

-- The panel, in pixels: its box, the timeline and the buttons. Sizes are given at 1080 lines and scaled.
local function layout()
    local k = height / 1080
    local m = 40 * k
    local panel = {x0 = m, x1 = width - m, y0 = height - 290 * k, y1 = height - 24 * k} -- a tall header: the logo is big
    local left, right = panel.x0 + 26 * k, panel.x1 - 26 * k
    local bar = {x0 = left, x1 = right, y0 = panel.y0 + 148 * k, y1 = panel.y0 + 156 * k}
    local y0, y1 = panel.y0 + 204 * k, panel.y0 + 248 * k
    local gap = 10 * k
    local function at(x, w) return {x0 = x, x1 = x + w * k, y0 = y0, y1 = y1} end
    local b = {}
    b.replay = at(left, 232)
    b.whole = at(b.replay.x1 + gap, 176)
    b.carry_on = at(b.whole.x1 + gap, 136)
    b.stop = at(right - 132 * k, 132)
    b.new = at(b.stop.x0 - gap - 132 * k, 132)
    local chip = 164
    local mid = (b.carry_on.x1 + b.new.x0) / 2
    local x = mid - (3 * chip * k + 2 * gap) / 2
    b.speed = at(x, chip)
    b.slowmo = at(b.speed.x1 + gap, chip)
    b.bails = at(b.slowmo.x1 + gap, chip)
    -- In the header, on the right: the header row's middle is panel.y0 + 52k.
    b.report = {x0 = right - 196 * k, x1 = right, y0 = panel.y0 + 36 * k, y1 = panel.y0 + 68 * k}
    return k, panel, bar, b
end

local function inside(p, r)
    return p.x >= r.x0 and p.x <= r.x1 and p.y >= r.y0 and p.y <= r.y1
end

local function has_line()
    return line.phase ~= "off" and line.length > 0
end

local function set_cursor(step)
    step = U.clamp(math.floor(step + 0.5), 0, line.length)
    -- At the end it stays at the end, which the slowed game is still adding to.
    player.following = step >= line.length
    if step ~= player.cursor then
        player.cursor = step
        player.confirm = false
        player.ghost = nil
    end
end

local function say_failure(ok, why)
    if not ok then R.toast(tostring(why), "warn") end
end

local function press(name)
    if name == "replay" then
        if not has_line() then return end
        local to = player.cursor
        if player.following and line.phase == "live" then
            say_failure(carry_on())
            return
        end
        close_player()
        say_failure(seek(to, true))
    elseif name == "whole" then
        say_failure(L.play_whole())
    elseif name == "new" then
        if has_line() and not player.confirm then
            player.confirm = true
            return
        end
        close_player()
        say_failure(L.new_line())
    elseif name == "carry_on" then
        say_failure(carry_on())
    elseif name == "speed" then
        for index, speed in CATCH_UPS do
            if speed == catch_up then
                catch_up = CATCH_UPS[index % #CATCH_UPS + 1]
                break
            end
        end
    elseif name == "slowmo" then
        local at = 1
        for index, speed in SLOWMOS do
            if speed == slowmo_speed then at = index end
        end
        slowmo_speed = SLOWMOS[at % #SLOWMOS + 1]
    elseif name == "bails" then
        say_failure(L.toggle_bails())
    elseif name == "stop" then
        L.stop_all()
    elseif name == "report" then
        end_preview()
        if L.on_report then say_failure(L.on_report()) end
    end
end

-- The camera behind the drawn skater, along the way it was going there.
local function aim_preview(position)
    local index = mark_index(player.cursor)
    local a, b = marks[math.max(1, index - 3)], marks[math.min(#marks, index + 3)]
    if a and b then
        local along = b.position - a.position
        local flat = vector.create(along.x, 0, along.z)
        if vector.magnitude(flat) > 0.5 then player.dir = vector.normalize(flat) end
    end
    local dir = player.dir or vector.create(0, 0, 1)
    reskate.camera.look(position - dir * 3.6 + vector.create(0, 1.5, 0), position + vector.create(0, 0.7, 0))
end

local function preview_tick()
    if not has_line() or player.following then
        end_preview()
        return
    end
    if not player.ghost then player.ghost = reskate.tas.line_bodies(player.cursor) end
    if not player.ghost then return end
    if not player.shown then
        player.shown = true
        reskate.skater.hide(true)
    end
    local m = player.ghost.board
    aim_preview(vector.create(m[13], m[14], m[15]))
end

local function player_tick(now)
    if player.following then player.cursor = line.length end
    player.ticks += 1
    local _, _, bar, buttons = layout()
    local mouse = reskate.input.cursor()
    if mouse then
        local p = mouse.position
        if mouse.left and not player.left then
            if has_line() and inside(p, {x0 = bar.x0 - 10, x1 = bar.x1 + 10, y0 = bar.y0 - 20, y1 = bar.y1 + 20}) then
                player.dragging = true
            else
                for name, r in buttons do
                    if inside(p, r) and (has_line() or (name ~= "replay" and name ~= "whole")) then
                        player.left = true
                        press(name)
                        return
                    end
                end
            end
        end
        if not mouse.left then player.dragging = false end
        player.left = mouse.left
        if player.dragging then set_cursor((p.x - bar.x0) / (bar.x1 - bar.x0) * line.length) end
        if mouse.wheel and mouse.wheel ~= 0 then set_cursor(player.cursor + (mouse.wheel > 0 and MARK_EVERY or -MARK_EVERY)) end
    end
    -- Arrow keys: a step at a time, faster held.
    local left, right = reskate.input.key(VK_LEFT), reskate.input.key(VK_RIGHT)
    if left or right then
        if now >= player.repeat_at then
            set_cursor(player.cursor + (right and 1 or -1))
            player.repeat_at = now + (player.arrow_held and 30 or 300)
            player.arrow_held = true
        end
    else
        player.arrow_held = false
        player.repeat_at = 0
    end
    local f11 = reskate.input.key(VK_F11)
    if f11 and not player.f11 then
        say_failure(carry_on())
        return
    end
    player.f11 = f11
    local enter = reskate.input.key(VK_RETURN)
    if enter and not player.enter then
        press("replay")
        return
    end
    player.enter = enter
    preview_tick()
end

function L.tick(busy)
    local now = U.now()
    line = reskate.tas.line()
    -- Asking the status is what has the runtime follow the skater's steps, which slow motion needs from the start:
    -- a flight is kept in step there, line or no line.
    if now >= listen_at then
        listen_at = now + 2000
        reskate.tas.status()
    end
    if U.in_session() then
        if line.phase ~= "off" or slowed or clock_now ~= 1 then
            close_player()
            full_speed()
            count, pending = nil, nil
            slowmo_on = false
            if line.phase ~= "off" then reskate.tas.line_stop() end
        end
        if no_bail then
            no_bail = false
            reskate.tas.no_bail(false)
        end
        return
    end
    if busy then return end
    local skater = reskate.skater.get()
    if skater then
        no_skater_since = nil
    else
        no_skater_since = no_skater_since or now
        if now - no_skater_since > NO_SKATER_MS and line.phase ~= "off" then
            -- A load: the line's places are in another map.
            L.suspend()
            start, marks, bails, joins = nil, {}, {}, {}
        end
        return
    end
    if line.phase == "live" and (#marks == 0 or line.length >= marks[#marks].step + MARK_EVERY) then
        table.insert(marks, {step = line.length, position = skater.position, air = board_in_air()})
    end
    -- Seen on its way: until then "live" is what the line was doing before the ask reached it.
    if pending and going_back() then pending.armed = true end
    -- Asked and never begun: say so, rather than leave the skater standing there.
    if pending and not pending.armed and now - pending.asked_at > 3000 then
        R.line("[line] the line did not begin going: the native side never took the ask")
        R.flush()
        R.toast("The line did not start. Stand still and try New line again.", "warn")
        pending = nil
    end
    -- Going back runs fast, but for its last second, so it comes into the moment as it was.
    if pending and pending.hand_over and catch_up > 1 and pending.to > LAST_RUN_STEPS then
        if line.phase == "counting" or (line.phase == "running_up" and pending.to - line.step > LAST_RUN_STEPS) then set_clock(catch_up)
        elseif line.phase == "running_up" then set_clock(1) end
    end
    if pending and line.phase == "running_up" and not pending.run_at then pending.run_at = now end
    -- Arrived at the moment: the game all but stops there for the countdown.
    if line.phase == "live" and pending and pending.armed and pending.hand_over then
        local p = pending
        pending = nil
        if p.run_at and p.to > 0 then
            local script = reskate.tas.status()
            local seconds = (now - p.run_at) / 1000
            R.line(string.format("[line] caught up %d steps in %.1f s: %.1fx asked %dx, %d steps the game read nothing before", p.to, seconds, p.to / STEPS / math.max(seconds, 0.01), catch_up, script.unread))
        end
        set_clock(1)
        count_down(board_in_air() or p.air_soon)
    end
    if count then count.ticks += 1 end
    if count and now >= count.ends then
        R.line(string.format("[line] countdown by %s: %.0f ticks a second", count.how, count.ticks / math.max((now - count.began) / 1000, 0.1)))
        count = nil
        full_speed()
        reskate.tas.line_go()
        go_until = now + GO_MS
        if probe then probe.go = PROBE_AFTER end
    end
    -- Played to its end, or the game's menu ended the recording. The line stays; nothing moves by itself.
    if line.phase == "played" and previous_phase ~= "played" and (not pending or pending.armed) then
        local whole = pending and not pending.hand_over
        pending, probe = nil, nil
        count = nil
        if not player then full_speed() end -- F11 stopping a run keeps the timeline's slow motion
        save_film()
        hint_until = now + HINT_MS
        hint_text = whole and "Line finished.  F11: timeline" or "Recording stopped.  F11: timeline"
    end
    previous_phase = line.phase
    -- The player's own slow motion, whenever nothing else is setting the speed.
    if not slowed and clock_now == 1 and not player and not count and not going_back() then
        local want = slowmo_on and slowmo_speed or 1
        if want ~= applied_speed then
            applied_speed = want
            reskate.time.slow(want)
        end
    end
    -- Rolling after the teleport (one in three did): going again costs only a moment.
    if line.phase == "counting" and pending and pending.retries < RETRIES and line.since_spawn >= START_STEP - 30 and line.since_spawn < START_STEP - 20 and skater.speed > 0.5 then
        local p = pending
        R.line(string.format("[line] still moving after arriving (%.2f m/s): teleporting again", skater.speed))
        seek(p.to, p.hand_over, p.retries + 1)
    end
    if player then
        if not reporting() then player_tick(now) end
        return
    end
end

-- ReTake's look: ink panels, neon teal for what matters, red for what stops or bails.
local VERSION = "0.0.2"
local LOGO = "assets/retake_logo_teal.png" -- the game keeps a picture by its path until it restarts: a changed picture gets a new name
local ACCENT, INK_HEX, TEXT, MUTED, RED = "#02f7da", "#0c0d11", "#f2f3f5", "#9aa0aa", "#ff5a5a"
local PANEL = {colour = "#0c0d11eb", fill = true, rounding = 16}
local PANEL_EDGE = {colour = "#ffffff1c", thickness = 1, rounding = 16}
local SURFACE = {colour = "#ffffff14", fill = true, rounding = 10}
local SURFACE_HOVER = {colour = "#ffffff26", fill = true, rounding = 10}
local SURFACE_OFF = {colour = "#ffffff08", fill = true, rounding = 10}
local PRIMARY = {colour = ACCENT, fill = true, rounding = 10}
local PRIMARY_HOVER = {colour = "#ffe175", fill = true, rounding = 10}
local DANGER_EDGE = {colour = "#ff5a5a90", thickness = 1.5, rounding = 10}
local DANGER_HOVER = {colour = "#ff5a5a2a", fill = true, rounding = 10}
local ARMED = {colour = RED, fill = true, rounding = 10}
local TRACK = {colour = "#ffffff1f", fill = true, rounding = 4}
local PLAYED = {colour = ACCENT, fill = true, rounding = 4}
local PILL = {colour = "#02f7da26", fill = true, rounding = 6}
local CHIP_PAUSED = {colour = "#ffffff1a", fill = true, rounding = 6}
local BUBBLE = {colour = "#000000e6", fill = true, rounding = 6}
local HUD_PILL = {colour = "#0c0d11c0", fill = true, rounding = 16}
local PATH_DONE = {colour = "#02f7daa0", thickness = 2}
local PATH_AFTER = {colour = "#ffffff50", thickness = 1}
local BONE = {colour = "#ffffff", thickness = 5}
local DECK = {colour = ACCENT, thickness = 5}
local HEAD_DOT = {colour = "#ffffff", fill = true}
local BIG_STYLE = {colour = "#ffffff", size = 150, shadow = true}
local SMALL_STYLE = {colour = "#ffffffd0", size = 26, shadow = true}

local function txt(size, colour, font)
    return {colour = colour, size = size, font = font or "heading"}
end
-- The skeleton's bodies, as physics bone id + 1 (Engine/Game/Skater/skater_body.h: 2 the neck the head rides on).
local BONES = {{2, 3}, {3, 12}, {12, 13}, {13, 14}, {14, 15}, {15, 24}, {12, 7}, {7, 6}, {6, 5}, {5, 4}, {12, 11}, {11, 10}, {10, 9}, {9, 8},
    {24, 19}, {19, 18}, {18, 17}, {17, 16}, {24, 23}, {23, 22}, {22, 21}, {21, 20}}

local function v(x, y)
    return vector.create(x, y, 0)
end

local function centred(d, text, style, x, y)
    local size = d:measure(text, style)
    d:text(v(x - size.x / 2, y), text, style)
    return size
end

local function draw_path(d, cursor)
    if #marks < 2 then return end
    local stride = math.max(1, math.floor(#marks / 150))
    local last = marks[1]
    for index = 1 + stride, #marks, stride do
        local mark = marks[index]
        d:world_line(last.position, mark.position, mark.step <= cursor and PATH_DONE or PATH_AFTER)
        last = mark
    end
end

local function draw_ghost(d, ghost)
    local s = ghost.skeleton
    for _, pair in BONES do d:world_line(s[pair[1]], s[pair[2]], BONE) end
    d:world_circle(s[2] + vector.create(0, 0.12, 0), 0.12, HEAD_DOT)
    local m = ghost.board
    local at = vector.create(m[13], m[14], m[15])
    local across = vector.create(m[1], m[2], m[3]) * 0.1
    local along = vector.create(m[9], m[10], m[11]) * 0.4
    local a, b, c, e = at + along + across, at + along - across, at - along - across, at - along + across
    d:world_line(a, b, DECK)
    d:world_line(b, c, DECK)
    d:world_line(c, e, DECK)
    d:world_line(e, a, DECK)
end

-- A rewind mark: a loop with its arrowhead, drawn in lines, for the primary button.
local function replay_icon(d, cx, cy, r, colour)
    local style = {colour = colour, thickness = 2.6}
    local a0, a1 = math.rad(214), math.rad(492)
    local last
    for i = 0, 20 do
        local a = a0 + (a1 - a0) * i / 20
        local p = v(cx + math.cos(a) * r, cy + math.sin(a) * r)
        if last then d:line(last, p, style) end
        last = p
    end
    local a = math.rad(214) -- the arrowhead on the loop's end, so they line up
    local px, py = cx + math.cos(a) * r, cy + math.sin(a) * r
    local tx, ty, nx, ny = math.sin(a), -math.cos(a), math.cos(a), math.sin(a)
    local tip, half = r * 0.62, r * 0.5
    d:poly({v(px + tx * tip, py + ty * tip), v(px + nx * half - tx * 2, py + ny * half - ty * 2), v(px - nx * half - tx * 2, py - ny * half - ty * 2)}, {colour = colour, fill = true})
    local p = r * 0.42
    d:poly({v(cx - p * 0.6, cy - p), v(cx - p * 0.6, cy + p), v(cx + p * 0.9, cy)}, {colour = colour, fill = true})
end

local function draw_player(d)
    local k, panel, bar, buttons = layout()
    draw_path(d, player.cursor)
    if player.shown and player.ghost then draw_ghost(d, player.ghost) end
    local mouse = reskate.input.cursor()
    local left = bar.x0
    d:rect(v(panel.x0, panel.y0), v(panel.x1, panel.y1), PANEL)
    d:rect(v(panel.x0, panel.y0), v(panel.x1, panel.y1), PANEL_EDGE)

    -- The logo (it has the name in it) and the version.
    local top = panel.y0 + 32 * k -- the header row's text; its middle is top + 20k
    local logo = 100 * k
    d:image(LOGO, v(left - 8 * k, panel.y0 + 6 * k), v(left - 8 * k + logo, panel.y0 + 6 * k + logo))
    local ver = "v" .. VERSION
    local ver_style = txt(15, ACCENT, "bold")
    local ver_size = d:measure(ver, ver_style)
    local vx = left - 8 * k + logo + 6 * k
    d:rect(v(vx, top + 9 * k), v(vx + ver_size.x + 14 * k, top + 31 * k), PILL)
    d:text(v(vx + 7 * k, top + 20 * k - ver_size.y / 2), ver, ver_style)

    -- The moment, large, in the middle; or what to do without a line.
    if has_line() then
        local now_style, all_style = txt(32, TEXT), txt(22, MUTED)
        local now, all = clock_text(player.cursor), " / " .. clock_text(line.length)
        local a, b = d:measure(now, now_style), d:measure(all, all_style)
        local x = width / 2 - (a.x + b.x) / 2
        d:text(v(x, top), now, now_style)
        d:text(v(x + a.x, top + (a.y - b.y) - 2 * k), all, all_style)
        local state = line.phase == "played" and "LINE ENDED" or "PAUSED"
        local chip_style = txt(13, MUTED, "bold")
        local c = d:measure(state, chip_style)
        local cx = vx + ver_size.x + 26 * k
        d:rect(v(cx, top + 9 * k), v(cx + c.x + 16 * k, top + 31 * k), CHIP_PAUSED)
        d:text(v(cx + 8 * k, top + 20 * k - c.y / 2), state, chip_style)
    else
        centred(d, "No line yet", txt(28, TEXT), width / 2, top - 2 * k)
        centred(d, "Stand where your line should start, then press New line.", txt(16, MUTED, "body"), width / 2, top + 34 * k)
    end
    -- Report a problem, top right: quiet, an outline with a "!" in a circle.
    local rb = buttons.report
    local report_hover = mouse and inside(mouse.position, rb)
    if report_hover then d:rect(v(rb.x0, rb.y0), v(rb.x1, rb.y1), SURFACE_HOVER) end
    d:rect(v(rb.x0, rb.y0), v(rb.x1, rb.y1), {colour = report_hover and "#ffffff60" or "#ffffff30", thickness = 1, rounding = 10})
    local report_style = txt(15, report_hover and TEXT or MUTED, "bold")
    local rs = d:measure("Report a problem", report_style)
    local rcy = (rb.y0 + rb.y1) / 2
    local rx = (rb.x0 + rb.x1) / 2 - (rs.x + 24 * k) / 2
    d:circle(v(rx + 8 * k, rcy), 8 * k, {colour = report_hover and TEXT or MUTED, thickness = 1.5})
    d:rect(v(rx + 7 * k, rcy - 4.5 * k), v(rx + 9 * k, rcy + 1 * k), {colour = report_hover and TEXT or MUTED, fill = true})
    d:rect(v(rx + 7 * k, rcy + 2.5 * k), v(rx + 9 * k, rcy + 4.5 * k), {colour = report_hover and TEXT or MUTED, fill = true})
    d:text(v(rx + 24 * k, rcy - rs.y / 2), "Report a problem", report_style)

    local keys = "Scrub: drag · wheel · ←/→      Enter: retake      Esc: close"
    local keys_style = txt(15, MUTED, "body")
    local ks = d:measure(keys, keys_style)
    d:text(v(rb.x0 - 22 * k - ks.x, top + 12 * k), keys, keys_style)

    -- The timeline: what has played in teal, retakes above, bails below, the playhead on top.
    d:rect(v(bar.x0, bar.y0), v(bar.x1, bar.y1), TRACK)
    local span = math.max(1, line.length)
    local function x_of(step) return bar.x0 + (bar.x1 - bar.x0) * step / span end
    local mid = (bar.y0 + bar.y1) / 2
    if has_line() then
        local head = x_of(player.cursor)
        if head > bar.x0 + 2 then d:rect(v(bar.x0, bar.y0), v(head, bar.y1), PLAYED) end
        for _, step in joins do
            local x = x_of(step)
            d:poly({v(x - 6 * k, bar.y0 - 14 * k), v(x + 6 * k, bar.y0 - 14 * k), v(x, bar.y0 - 4 * k)}, {colour = ACCENT, fill = true})
        end
        for _, step in bails do d:circle(v(x_of(step), bar.y1 + 11 * k), 4 * k, {colour = RED, fill = true}) end
        -- Where the mouse would put it.
        local over = mouse and inside(mouse.position, {x0 = bar.x0, x1 = bar.x1, y0 = bar.y0 - 20 * k, y1 = bar.y1 + 20 * k})
        local function bubble(x, label)
            local style = txt(14, TEXT, "bold")
            local size = d:measure(label, style)
            local bx = U.clamp(x - size.x / 2 - 8 * k, panel.x0 + 8 * k, panel.x1 - size.x - 24 * k)
            d:rect(v(bx, bar.y0 - 46 * k), v(bx + size.x + 16 * k, bar.y0 - 22 * k), BUBBLE)
            d:text(v(bx + 8 * k, bar.y0 - 34 * k - size.y / 2), label, style)
        end
        if over and not player.dragging then
            local x = mouse.position.x
            d:line(v(x, bar.y0 - 6 * k), v(x, bar.y1 + 6 * k), {colour = "#ffffff70", thickness = 2})
            bubble(x, clock_text(U.clamp((x - bar.x0) / (bar.x1 - bar.x0), 0, 1) * line.length))
        end
        d:circle(v(head, mid), 11 * k, {colour = INK_HEX, fill = true})
        d:circle(v(head, mid), 8 * k, {colour = "#ffffff", fill = true})
        if player.dragging then bubble(head, clock_text(player.cursor)) end
        -- What the marks are.
        local legend = txt(13, MUTED, "body")
        local lx, ly = bar.x0, bar.y1 + 20 * k
        d:poly({v(lx, ly + 2 * k), v(lx + 10 * k, ly + 2 * k), v(lx + 5 * k, ly + 10 * k)}, {colour = ACCENT, fill = true})
        d:text(v(lx + 16 * k, ly - 1 * k), "Retake", legend)
        local rx = lx + 16 * k + d:measure("Retake", legend).x + 18 * k
        d:circle(v(rx + 4 * k, ly + 6 * k), 4 * k, {colour = RED, fill = true})
        d:text(v(rx + 14 * k, ly - 1 * k), "Bail", legend)
    end

    -- The buttons. One primary action; settings as chips; the ones that end things on the right.
    local function button(r, kind, label, value, value_colour)
        local disabled = not has_line() and (kind == "primary" or r == buttons.whole)
        local hover = not disabled and mouse and inside(mouse.position, r)
        local fill, ink = SURFACE, TEXT
        if disabled then fill, ink = SURFACE_OFF, "#ffffff55"
        elseif kind == "primary" then fill, ink = hover and PRIMARY_HOVER or PRIMARY, INK_HEX
        elseif kind == "armed" then fill, ink = ARMED, INK_HEX
        elseif kind == "danger" then fill, ink = hover and DANGER_HOVER or nil, RED
        elseif hover then fill = SURFACE_HOVER end
        if fill then d:rect(v(r.x0, r.y0), v(r.x1, r.y1), fill) end
        if kind == "danger" then d:rect(v(r.x0, r.y0), v(r.x1, r.y1), DANGER_EDGE) end
        local cy = (r.y0 + r.y1) / 2
        if value then
            local ls, vs = txt(15, MUTED, "body"), txt(18, value_colour or TEXT)
            local a, b = d:measure(label, ls), d:measure(value, vs)
            local x = (r.x0 + r.x1) / 2 - (a.x + 8 * k + b.x) / 2
            d:text(v(x, cy - a.y / 2), label, ls)
            d:text(v(x + a.x + 8 * k, cy - b.y / 2), value, vs)
            return
        end
        local style = txt(18, ink)
        local size = d:measure(label, style)
        local icon = kind == "primary" and 26 * k or 0
        local x = (r.x0 + r.x1) / 2 - (size.x + icon) / 2
        if icon > 0 then replay_icon(d, x + 9 * k, cy, 9 * k, ink) end
        d:text(v(x + icon, cy - size.y / 2), label, style)
    end
    button(buttons.replay, "primary", "Replay from here")
    button(buttons.whole, "normal", "Play whole line")
    button(buttons.carry_on, "normal", "Carry on")
    button(buttons.speed, "chip", "Catch-up", string.format("%d×", catch_up))
    button(buttons.slowmo, "chip", "Slow-mo", string.format("%d%%", math.floor(slowmo_speed * 100 + 0.5)))
    button(buttons.bails, "chip", "Bails", no_bail and "Off" or "On", no_bail and RED or nil)
    button(buttons.new, player.confirm and "armed" or "normal", player.confirm and "Erase line?" or "New line")
    button(buttons.stop, "danger", "Stop all")
end

-- A small status pill in the top left, for while you skate.
local function hud_pill(d, k, y, dot, label, label_colour, key)
    local style = txt(17, label_colour or TEXT)
    local size = d:measure(label, style)
    local x = 32 * k
    local w = 20 * k + (dot and 16 * k or 0) + size.x + (key and 46 * k or 0)
    d:rect(v(x, y), v(x + w, y + 32 * k), HUD_PILL)
    local tx = x + 10 * k
    if dot then
        d:circle(v(tx + 5 * k, y + 16 * k), 5 * k, {colour = dot, fill = true})
        tx += 16 * k
    end
    d:text(v(tx, y + 16 * k - size.y / 2), label, style)
    if key then
        local ks = txt(12, INK_HEX, "bold")
        local kz = d:measure(key, ks)
        local kx = tx + size.x + 10 * k
        d:rect(v(kx, y + 7 * k), v(kx + kz.x + 12 * k, y + 25 * k), {colour = "#ffffffd0", fill = true, rounding = 4})
        d:text(v(kx + 6 * k, y + 16 * k - kz.y / 2), key, ks)
    end
end

function L.draw(d)
    local size = d:size()
    width, height = size.x, size.y
    if player then
        if not reporting() then draw_player(d) end -- the report window is drawn over the game instead
        return
    end
    local k = height / 1080
    local middle = height * 0.24
    if count then
        local shown = centred(d, tostring(math.max(1, math.ceil((count.ends - U.now()) / 1000))), BIG_STYLE, width / 2, middle)
        centred(d, "Hands on the controller", SMALL_STYLE, width / 2, middle + shown.y + 8 * k)
    elseif U.now() < go_until then
        centred(d, "GO", BIG_STYLE, width / 2, middle)
    elseif line.phase == "seeking" or line.phase == "counting" then
        centred(d, pending and pending.to == 0 and "New line: stand still" or "Going back", SMALL_STYLE, width / 2, middle)
    elseif line.phase == "running_up" and pending and pending.hand_over then
        local left = math.max(0, pending.to - line.step) / STEPS
        centred(d, string.format("Catching up to your moment: %.1f s of the line left", left), SMALL_STYLE, width / 2, middle)
    elseif (line.phase == "off" or line.phase == "played") and U.now() < hint_until then
        -- Only for a moment: nothing of this should be on the screen while filming.
        hud_pill(d, k, 40 * k, nil, (hint_text:gsub("%s+F11: ?.*$", "")), nil, "F11")
    elseif line.phase == "live" then
        hud_pill(d, k, 40 * k, RED, clock_text(line.length), nil, "F11")
    end
    if slowmo_on and not count and not going_back() then
        hud_pill(d, k, 80 * k, nil, string.format("SLOW-MO %d%%", math.floor(slowmo_speed * 100 + 0.5)), ACCENT)
    end
end

function L.phase()
    return line.phase, line.length
end

-- What the report's recorder takes every frame: cheap, no copies.
local pad_seen, pad_at = nil, -math.huge
function L.live()
    local now = U.now()
    if now - pad_at > 1000 then pad_seen, pad_at = find_pad(), now end
    return {line = line, slowed = slowed, clock = clock_now, speed = applied_speed, timeline = player ~= nil, counting = count ~= nil,
        going_to = pending and pending.to, pad = pad_seen}
end

-- Everything ReTake knows, for a report.
function L.snapshot()
    local state = {
        phase = line.phase, length = line.length, step = line.step, since_spawn = line.since_spawn, previous_phase = previous_phase,
        slowed = slowed, clock = clock_now, game_speed = applied_speed, slowmo_on = slowmo_on, slowmo_speed = slowmo_speed,
        catch_up = catch_up, bails_off = no_bail, hint = hint_text, screen = string.format("%dx%d", width, height),
        marks = #marks, retakes = #joins, bails = #bails, pad = find_pad(), filming_rows = filming and #filming.rows,
        probe_rows = probe and #probe.rows,
    }
    if pending then
        state.pending = {to = pending.to, hand_over = pending.hand_over, retries = pending.retries, armed = pending.armed,
            air_soon = pending.air_soon, ms_since_asked = U.now() - pending.asked_at, ms_running = pending.run_at and U.now() - pending.run_at}
    end
    if count then state.countdown = {ms_left = count.ends - U.now(), how = count.how} end
    if player then
        state.timeline = {cursor = player.cursor, following = player.following, opened_in_flight = player.was_air,
            ms_open = U.now() - player.opened, preview_shown = player.shown}
    end
    return {state = state, start = start, marks = marks, joins = joins, bails = bails}
end

reskate.ui.screen(SCREEN, function() end, {panel = false})

L.version = VERSION

return L
