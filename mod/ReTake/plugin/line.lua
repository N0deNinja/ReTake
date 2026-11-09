-- A line: skated from a standing start, recorded as one take. F11 slows the game right down and opens a
-- timeline; drag it and a drawn skater shows each moment at once. Replay from here catches up to that moment
-- (it plays the line from its start, locked, so the game's own state comes along), slows right down there,
-- counts 3, 2, 1, and the controller carries on from it, the failed attempt forgotten. Play whole line gives the
-- finished line back as one take.
local U = require("util")
local C = require("clock")
local R = require("report")
local S = require("ui")
local L = {}

local STEPS = 60
local START_STEP = 180 -- steps after the teleport a line starts, and every going back runs from
local COUNT_MS = 3000
local HINT_MS = 8000
local SLOW = 0.05       -- the timeline on the ground: smooth slow motion, the steps shorter
local AIR_SOON_STEPS = 18 -- a moment just before a takeoff, noted in a report
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
local line_uid = nil -- the line's id (L.line_id)
local marks = {}    -- {step=, position=}, a tenth of a second apart, oldest first
local bails = {}    -- steps of the line where the skater bailed
local joins = {}    -- steps of the line where a retake took over
local pending = nil -- {from=, to=, hand_over=, retries=}, while going back
local sensor_was = nil -- the game's sensor block as last seen (logged when it changes)
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
-- The slow-motion test: the same moment of the line, taken over again and again, the countdown's slowing down
-- at a different speed each time and the controller held as recorded throughout, so only the speed differs.
local TEST_SPEEDS = {1, 0.5, 0.25, 0.1, 0.05}
local TEST_SLOW_STEPS = 9 -- game time slowed: what the countdown's 3 s at 0.05 is (9 steps of 1/60 s)
local TEST_STEPS = 60     -- each take, one second of game time from the moment
local TEST_ROWS = 6000
local test = nil -- {to=, index=, run=, results=, rows=, seek_at=, tries=}
local player = nil  -- the timeline: {cursor=, dragging=, left=, confirm=, f11=, enter=, repeat_at=, ghost=, shown=, dir=}
local closed_at = -math.huge
local listen_at = -math.huge
local no_bail = false -- the game's wipeouts off, all of them
local hint_text = "Start a line"
local hint_until = U.now() + HINT_MS
local width, height = 1920, 1080

-- The speed changes by a quarter a tick at most (0.05 to 1 in about ten ticks) rather than all at once. Back to full
-- speed at once, a step twenty times longer than the one before, the skater's arms were flung back as the controller
-- came back (2026-11-07, in play; slowing down at once did nothing like it). Slowing down eases too. Going back is at
-- once (`gently` false): it teleports, and the skater is built with the step it has then. `retake ease` switches the
-- easing off and on, to compare.
local EASE = 0.75
local ease_on = true
local eased_speed = 1 -- what the game runs at now; applied_speed is where it is going
local ease_up = false -- speeding up eases too, this time

-- In a flight on the board, the speed changes in one go: each change of step mid-flight is one more step of the flight's
-- path to match, and easing in made ten of them (the board flung from 11 to 48 m/s, 2026-11-07).
local function flying()
    local state = C.last and C.last.state
    return state == 200 or state == 201
end

local function set_speed(speed, gently)
    applied_speed = speed
    ease_up = gently == true
    if flying() then
        eased_speed = speed
    elseif ease_on and speed < eased_speed then
        eased_speed = math.max(speed, eased_speed * EASE)
    elseif ease_on and ease_up and speed > eased_speed then
        eased_speed = math.min(speed, eased_speed / EASE)
    else
        eased_speed = speed
    end
    return reskate.time.slow(eased_speed)
end

-- Once a tick: on towards the speed asked for.
local function ease_tick()
    if eased_speed ~= applied_speed and flying() then
        eased_speed = applied_speed -- taking off mid-ease: the rest in one go
        reskate.time.slow(eased_speed)
    elseif eased_speed > applied_speed then
        eased_speed = math.max(applied_speed, eased_speed * EASE)
        reskate.time.slow(eased_speed)
    elseif eased_speed < applied_speed then
        eased_speed = ease_on and ease_up and math.min(applied_speed, eased_speed / EASE) or applied_speed
        reskate.time.slow(eased_speed)
    end
end

-- `on` true or false sets it; nil only says. Either way, what it is now.
function L.ease(on)
    if on ~= nil and on ~= ease_on then
        ease_on = on
        R.line(ease_on and "[line] speed changes ease in" or "[line] speed changes are at once")
    end
    return ease_on
end

local function slow_down(on)
    slowed = on
    reskate.tas.line_paused(on)
    return set_speed(on and SLOW or 1)
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

-- Back to full speed with the skater riding on: eased up, as the countdown ends or slow motion goes off.
local function ride_on()
    set_clock(1)
    slowed = false
    reskate.tas.line_paused(false)
    return set_speed(1, true)
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
-- On the board at the line's start, as it was recorded, or on foot: the board upright under the skater (its up axis
-- 1.0 high) or carried (0.3). New line asks for the board, but the game can leave the skater on foot, and a line
-- begun on foot (run, then Triangle onto the board) replayed on the board goes wrong from its first step: after a
-- trip to another map the teleport put the board under the skater, and the replay jumped about (2026-11-08). So
-- going back starts as the recording did. nil when the recording cannot say.
local function recorded_on_board()
    if not reskate.tas.line_bodies then return nil end
    for _, step in {0, 1, 2} do
        local ok, bodies = pcall(reskate.tas.line_bodies, step)
        if ok and bodies and bodies.board and bodies.board[6] then return bodies.board[6] > 0.8 end
    end
    return nil
end

-- The game's sensor block (ReSkate.dll reads it): on once the skater has been ridden since the game started, else off.
-- true, false, or nil when the DLL can't tell.
local function sensor_on()
    local ok, s = pcall(reskate.tas.status)
    if not ok or type(s) ~= "table" or s.sensor_started == nil then return nil end
    return s.sensor_started == true
end

-- Whether the line can be replayed as it was skated. A line skated with the sensor block on, replayed with it off, takes
-- rails the other way: a line loaded straight after starting the game went off at its first rail, every time. A line
-- skated with it off replays the same with it off, so that is fine. A line from before ReTake kept this counts as on.
function L.sensor_ready()
    if sensor_on() ~= false then return true end
    return start ~= nil and start.sensor == false
end

local function seek(to, hand_over, retries)
    if not start then return false, "no line is recorded" end
    if not retries and not L.sensor_ready() then
        return false, "ride for a moment first: until you've skated since the game started, a replay goes off on rails"
    end
    full_speed()
    count = nil
    -- A retake: the line as it is now is kept as a take first (takes.lua), before it is cut at the moment.
    if hand_over and not retries and to < line.length and L.on_retake then L.on_retake(to) end
    local on_board = recorded_on_board()
    if on_board == nil then on_board = start.on_board end
    local ok, why = reskate.skater.teleport(start.position, start.heading, {on_board = on_board})
    if not ok then return false, why end
    ok, why = reskate.tas.line_seek(0, to, START_STEP, hand_over)
    if not ok then return false, why end
    local soon = (retries and pending and pending.air_soon) or air_soon(to)
    pending = {from = 0, to = to, hand_over = hand_over, retries = retries or 0, asked_at = U.now(), air_soon = soon, on_board = on_board}
    if retries then return true end
    if hand_over then
        R.line(string.format("[line] back to %s of %s", clock_text(to), clock_text(line.length)))
        forget_after(to)
        if to > 0 and not test then table.insert(joins, to) end
        probe = not test and {rows = {}, to = to} or nil
        filming = nil
    else
        R.line(string.format("[line] playing the whole line, %s, %d joins", clock_text(to), #joins))
        filming = {rows = {}, joins = {table.unpack(joins)}}
        probe = nil
    end
    return true
end

-- Slowed right down: 3, 2, 1, then full speed and the controller is yours.
-- Always smooth slow motion, in a flight too: the skater follows the shorter step (ReSkate.dll's step_fields and its
-- flight path, match_flight_step), so the countdown no longer drops to the clock alone, three frames a second.
local function count_down()
    -- From the timeline it is already slow, in its way.
    reskate.tas.line_paused(true)
    if not slowed and clock_now == 1 then
        local ok, why = slow_down(true)
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

-- The slow-motion test's arithmetic: headings in degrees, differences folded into -180 to 180.
local function wrap(degrees)
    return (degrees + 180) % 360 - 180
end

-- How far the travel is from the board's axis, either end of it: 0 rolling straight, 90 fully sideways.
local function slip(travel, axis)
    local off = math.abs(wrap(travel - axis))
    return off > 90 and 180 - off or off
end

local function heading_of(s)
    return math.deg(math.atan2(s.vx, s.vz))
end

local function flat_speed(s)
    return math.sqrt(s.vx ^ 2 + s.vz ^ 2)
end

-- Finished or stopped: the results file, a line each take in the log, the controller back to the player.
local function test_end(why)
    local t = test
    test = nil
    if not t then return end
    full_speed()
    reskate.tas.line_paused(false)
    if line.phase == "live" then reskate.tas.line_go() end
    local lines = {}
    local base = t.results[1]
    for _, r in t.results do
        local text = string.format("%.2fx: in the first 0.15 s the travel turned %+.1f deg and the board %+.1f deg, %.1f to %.1f m/s, slip at most %.1f deg, body gap at most %.2f m",
            r.speed, r.travel_turn, r.board_turn, r.speed_in, r.speed_mid, r.slip_most, r.gap_most)
        if base and r ~= base then
            text ..= string.format("; a second on, %.2f m from the 1x take, heading %+.1f deg, speed %+.1f m/s",
                U.dist(r.last.x, r.last.y, r.last.z, base.last.x, base.last.y, base.last.z),
                wrap(heading_of(r.last) - heading_of(base.last)), flat_speed(r.last) - flat_speed(base.last))
        end
        table.insert(lines, text)
    end
    local head = {"# ReTake slow-motion test at " .. clock_text(t.to) .. (why and (": stopped, " .. why) or "")}
    for _, text in lines do table.insert(head, "# " .. text) end
    table.insert(head, "speed\tslowed\tstep\tt\tdt\tx\ty\tz\tvx\tvy\tvz\theading\tacross\talong\tup_y\tyaw_rate\tbody_gap\tstate\tair")
    local name = "results/slowtest-" .. os.date("%Y%m%d-%H%M%S") .. ".tsv"
    R.data(name, table.concat(head, "\n") .. "\n" .. table.concat(t.rows, "\n") .. "\n")
    R.line(string.format("[slowtest] at %s, %d takes%s, saved in %s", clock_text(t.to), #t.results, why and (", stopped: " .. why) or "", name))
    for _, text in lines do R.line("[slowtest] " .. text) end
    R.flush()
    reskate.console.print("ReTake: slow-motion test " .. (why and ("stopped: " .. why) or "done") .. ". " .. name)
    for _, text in lines do reskate.console.print("  " .. text) end
    hint_until = U.now() + HINT_MS
    hint_text = "Slow-motion test saved.  F11: timeline"
end

-- At the moment again: the next take. Slowed as the countdown slows, for its 9 steps, then full speed;
-- the controller held as recorded all the while.
local function test_begin()
    local speed = TEST_SPEEDS[test.index]
    reskate.tas.line_paused(true)
    if speed < 1 then
        slowed = true
        local ok, why = set_speed(speed) -- eased as the countdown is, so the take is what the player gets
        if not ok then return test_end("the game would not slow down to " .. speed .. ": " .. tostring(why)) end
    end
    reskate.tas.line_hold()
    test.run = {speed = speed, from = line.step, t0 = C.sim_t, slow = speed < 1}
end

-- One take's numbers, once it has run its second.
local function test_take_done()
    local r = test.run
    test.run = nil
    if r.first and r.mid and r.last then
        table.insert(test.results, {speed = r.speed, last = r.last,
            travel_turn = wrap(heading_of(r.mid) - heading_of(r.first)),
            board_turn = r.mid[r.axis] and r.first[r.axis] and wrap(r.mid[r.axis] - r.first[r.axis]) or 0,
            speed_in = flat_speed(r.first), speed_mid = flat_speed(r.mid), slip_most = r.slip_most or 0, gap_most = r.gap_most or 0})
    end
    test.index += 1
    if test.index > #TEST_SPEEDS then return test_end() end
    full_speed()
    test.seek_at, test.tries = U.now(), 0
end

-- The steps of a take, every one of them.
local function test_step(s)
    local r = test and test.run
    if not r or not s.x or not s.vx or line.phase ~= "live" then return end
    if not r.first then
        r.first = s
        -- Which axis the board rolls along: the one the travel is nearer to as the take begins.
        if s.along and s.across then r.axis = slip(heading_of(s), s.along) <= slip(heading_of(s), s.across) and "along" or "across" end
    end
    if line.step - r.from <= TEST_SLOW_STEPS then r.mid = s end
    r.last = s
    if r.axis and s[r.axis] and flat_speed(s) > 1 then r.slip_most = math.max(r.slip_most or 0, slip(heading_of(s), s[r.axis])) end
    if s.body_gap then r.gap_most = math.max(r.gap_most or 0, s.body_gap) end
    if #test.rows < TEST_ROWS then
        local function f(value) return value and string.format("%.4f", value) or "" end
        table.insert(test.rows, table.concat({tostring(r.speed), r.slow and "1" or "0", tostring(line.step - r.from), f(C.sim_t - r.t0), f(s.dt),
            f(s.x), f(s.y), f(s.z), f(s.vx), f(s.vy), f(s.vz), f(heading_of(s)), f(s.across), f(s.along), f(s.up_y), f(s.yaw_rate), f(s.body_gap),
            tostring(s.state or ""), s.air and "1" or "0"}, "\t"))
    end
end

-- Once a tick while a test runs: going back for the next take, the slowing down ended on time, a take finished.
local function test_tick(now)
    if not test then return end
    if not test.run then
        if test.seek_at and now >= test.seek_at and not pending then
            local ok, why = seek(test.to, true)
            if ok then
                test.seek_at = nil
            else
                test.tries += 1
                if test.tries > 6 then return test_end("could not go back: " .. tostring(why)) end
                test.seek_at = now + 600
            end
        end
        return
    end
    if line.phase ~= "live" then return test_end("the line stopped (" .. line.phase .. ")") end
    local done = line.step - test.run.from
    if test.run.slow and done >= TEST_SLOW_STEPS then
        test.run.slow = false
        ride_on() -- as the countdown ends
    end
    if done >= TEST_STEPS then test_take_done() end
end

-- retake slowtest [time]: the test at that moment of the line (default 2 s before its end). Everything after
-- the moment is thrown away, as a retake does.
function L.slow_test(at)
    if U.in_session() then return false, "ReTake is offline only" end
    if test then return false, "a slow-motion test is already running" end
    if not start then return false, "no line is recorded" end
    if line.phase ~= "live" or line.length == 0 then return false, "record a line first, riding straight at the moment to test" end
    local to = at and math.floor(at * STEPS + 0.5) or line.length - 2 * STEPS
    if to < 1 or to > line.length then return false, string.format("pick a moment between 0:00.02 and %s", clock_text(line.length)) end
    close_player()
    count = nil
    test = {to = to, index = 1, results = {}, rows = {}, seek_at = U.now(), tries = 0}
    R.line(string.format("[slowtest] at %s of %s: %d takes, slowed for %d steps at %s", clock_text(to), clock_text(line.length), #TEST_SPEEDS,
        TEST_SLOW_STEPS, table.concat(TEST_SPEEDS, ", ")))
    return true
end

local function test_cancel(why)
    if test then test_end(why) end
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
    if test then test_step(s) end
    -- Off the board while going back, in a line that started on it: once a going back, where and how, for a report.
    -- After a trip to another map the board went its recorded way and the skater stayed at the start on foot (2026-11-08).
    if pending and not pending.off_logged and line.phase == "running_up" and pending.on_board and (s.state == 504 or s.state == 300) then
        pending.off_logged = true
        local root = reskate.skater.position()
        R.line(string.format("[line] off the board while going back, at step %d (state %s): board at %.1f, %.1f, %.1f, skater at %s, %d steps since the teleport",
            line.step, tostring(s.state), s.x, s.y, s.z, root and string.format("%.1f, %.1f, %.1f", root.x, root.y, root.z) or "?", line.since_spawn or -1))
    end
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
    test_cancel("the line was stopped")
    close_player()
    full_speed()
    count, pending = nil, nil
    if line.phase ~= "off" then reskate.tas.line_stop() end
end

-- A new line: stops here, and after the countdown you go.
function L.new_line()
    if U.in_session() then return false, "ReTake is offline only" end
    test_cancel("New line")
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
    start = {position = s.position, heading = s.heading, on_board = true, sensor = sensor_on()}
    line_uid = os.date("%Y%m%d-%H%M%S")
    if L.on_new_line then L.on_new_line(line_uid) end
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
    test_cancel("Stop all")
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

function L.catch_up_speed()
    return catch_up
end

-- A ghost line is about to move the skater: whatever the line is doing stops, and the line is kept as it is
-- (recording, it ends here; it is never forgotten).
function L.keep_still()
    test_cancel("a ghost line")
    close_player()
    full_speed()
    count, pending = nil, nil
    slowmo_on = false
    if line.phase ~= "off" and line.phase ~= "played" then reskate.tas.line_halt() end
end

-- Where the line starts, for a ghost line made of it.
function L.start()
    return start
end

local function going_back()
    return line.phase == "seeking" or line.phase == "counting" or line.phase == "running_up"
end

-- One press: back that far. Pressed while going back, further back from the same place.
function L.back(seconds)
    if U.in_session() then return false, "ReTake is offline only" end
    if player then return false, "the timeline is open" end
    if test then return false, "a slow-motion test is running: F11 stops it" end
    if reporting() then return true end -- Ctrl+R while typing a report: nothing
    if line.phase == "off" or line.length == 0 then return false, "no line is recording: F11, New line here" end
    local base = line.length
    if pending and pending.hand_over and going_back() then base = pending.to end
    return seek(math.max(0, base - math.floor(seconds * STEPS + 0.5)), true)
end

function L.play_whole()
    if line.phase == "off" or line.length == 0 then return false, "no line is recorded" end
    if test then return false, "a slow-motion test is running: F11 stops it" end
    close_player()
    return seek(line.length, false)
end

-- Out of the timeline without having picked anything: straight on from where it stopped.
local function carry_on()
    close_player()
    if line.phase == "live" then
        count_down()
        return true
    end
    full_speed()
    return true
end

function L.toggle_player()
    if reporting() then return true end -- F11 while writing a report: the report keeps the keys
    if test then
        test_cancel("F11")
        return true
    end
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
    b.replay = at(left, 252)
    b.whole = at(b.replay.x1 + gap, 196)
    b.carry_on = at(b.whole.x1 + gap, 146)
    b.stop = at(right - 140 * k, 140)
    b.new = at(b.stop.x0 - gap - 150 * k, 150)
    local chip = 164
    local mid = (b.carry_on.x1 + b.new.x0) / 2
    local key_chip = 214
    local x = mid - ((3 * chip + key_chip) * k + 3 * gap) / 2
    b.speed = at(x, chip)
    b.slowmo = at(b.speed.x1 + gap, chip)
    b.bails = at(b.slowmo.x1 + gap, chip)
    b.slowkey = at(b.bails.x1 + gap, key_chip)
    -- In the header, on the right: the header row's middle is panel.y0 + 52k.
    b.report = {x0 = right - 222 * k, x1 = right, y0 = panel.y0 + 34 * k, y1 = panel.y0 + 70 * k}
    b.lines = {x0 = b.report.x0 - gap - 128 * k, x1 = b.report.x0 - gap, y0 = b.report.y0, y1 = b.report.y1}
    -- Takes, left of My lines: the arrows either side of "Take 2 of 4".
    b.take_next = {x0 = b.lines.x0 - 22 * k - 34 * k, x1 = b.lines.x0 - 22 * k, y0 = b.report.y0, y1 = b.report.y1}
    b.take_prev = {x0 = b.take_next.x0 - 150 * k - 34 * k, x1 = b.take_next.x0 - 150 * k, y0 = b.report.y0, y1 = b.report.y1}
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
    elseif name == "slowkey" then
        if L.on_slowkey then say_failure(L.on_slowkey()) end
    elseif name == "stop" then
        L.stop_all()
    elseif name == "report" then
        end_preview()
        if L.on_report then say_failure(L.on_report()) end
    elseif name == "lines" then
        end_preview()
        if L.on_lines then say_failure(L.on_lines()) end
    elseif (name == "take_prev" or name == "take_next") and L.takes_status and L.takes_status() then
        end_preview()
        if L.on_take_step then say_failure(L.on_take_step(name == "take_next" and 1 or -1)) end
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
        local ok, s = pcall(reskate.tas.status)
        local on = ok and type(s) == "table" and s.sensor_started
        if on ~= nil and on ~= sensor_was then
            if sensor_was ~= nil or not on then
                R.line(string.format("[line] the game's sensor block is %s: phase %s, %d steps since the skater was built, line skated with it %s",
                    on and "on" or "OFF", tostring(line.phase), line.since_spawn or -1,
                    start == nil and "-" or start.sensor == nil and "?" or start.sensor and "on" or "off"))
            end
            sensor_was = on
        end
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
    ease_tick()
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
        if test then test_begin() else count_down() end
    end
    test_tick(now)
    if count then count.ticks += 1 end
    if count and now >= count.ends then
        R.line(string.format("[line] countdown by %s: %.0f ticks a second", count.how, count.ticks / math.max((now - count.began) / 1000, 0.1)))
        count = nil
        ride_on()
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
    if not slowed and clock_now == 1 and not player and not count and not test and not going_back() then
        local want = slowmo_on and slowmo_speed or 1
        if want ~= applied_speed then set_speed(want, true) end
    end
    -- After arriving, not as the line began, on the board or on foot (recorded_on_board): the teleport could not
    -- change it. Replayed so, the recording is put back each step on a skater the game moves another way, and it
    -- jumps about (2026-11-08). So the same, again; and if it never takes, stopped, with a word.
    local state = C.last and C.last.state
    local on_foot = state == 504 or state == 300
    local wrong = pending and pending.on_board ~= nil and state ~= nil and ((pending.on_board and on_foot) or (not pending.on_board and not on_foot))
    if line.phase == "counting" and wrong and line.since_spawn >= START_STEP - 30 and line.since_spawn < START_STEP - 20 then
        local p = pending
        local want = p.on_board and "on the board" or "on foot"
        if p.retries < RETRIES then
            R.line("[line] not " .. want .. " after arriving, as the line began: teleporting again")
            seek(p.to, p.hand_over, p.retries + 1)
        else
            R.line("[line] still not " .. want .. " after " .. RETRIES .. " teleports: stopped")
            pending = nil
            reskate.tas.line_halt()
            full_speed()
            R.toast(p.on_board and "This line starts on the board: get on it, then retake." or "This line starts on foot: step off the board, then retake.", "warn")
        end
    elseif line.phase == "counting" and pending and pending.retries < RETRIES and line.since_spawn >= START_STEP - 30 and line.since_spawn < START_STEP - 20 and skater.speed > 0.5 then
        -- Rolling after the teleport (one in three did): going again costs only a moment.
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
local VERSION = "0.0.6"
local LOGO = "assets/retake_logo_teal.png" -- the game keeps a picture by its path until it restarts: a changed picture gets a new name
local ACCENT, INK_HEX, TEXT, MUTED, RED = "#02f7da", "#0c0d11", "#f2f3f5", "#9aa0aa", "#ff5a5a"
local PATH_DONE = {colour = "#02f7daa0", thickness = 2}
local PATH_AFTER = {colour = "#ffffff50", thickness = 1}
local BONE = {colour = "#ffffff", thickness = 5}
local DECK = {colour = ACCENT, thickness = 5}
local HEAD_DOT = {colour = "#ffffff", fill = true}
-- The countdown in the game's marker, as its "LEGENDARY!"; what is going on under it in capitals.
local BIG_STYLE = {colour = "#ffffff", size = 160, shadow = true, font = "title_large"}
local GO_STYLE = {colour = "#02f7da", size = 160, shadow = true, font = "title_large"}
local SMALL_STYLE = {colour = "#ffffffe0", size = 24, shadow = true, font = "heading"}

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
    S.panel(d, panel, k, 11)

    -- The logo (it has the name in it), the version, and whether it is paused or ended, on a sticky note.
    local top = panel.y0 + 32 * k -- the header row's text; its middle is top + 20k
    local logo = 100 * k
    d:image(LOGO, v(left - 8 * k, panel.y0 + 6 * k), v(left - 8 * k + logo, panel.y0 + 6 * k + logo))
    local vx = left - 8 * k + logo + 6 * k
    local tag_y = top + 9 * k
    local vw = S.tag(d, vx, tag_y, "v" .. VERSION, k, S.TILE_LIGHT, S.ACCENT)

    -- The moment, large, in the middle; or what to do without a line.
    if has_line() then
        local now_style, all_style = S.font(34, S.TEXT, "heading", true), S.font(22, S.MUTED, "heading", true)
        local now, all = clock_text(player.cursor), " / " .. clock_text(line.length)
        local a, b = d:measure(now, now_style), d:measure(all, all_style)
        local x = width / 2 - (a.x + b.x) / 2
        d:text(v(x, top - 2 * k), now, now_style)
        d:text(v(x + a.x, top - 2 * k + (a.y - b.y) - 3 * k), all, all_style)
        S.tag(d, vx + vw + 10 * k, tag_y, line.phase == "played" and "LINE ENDED" or "PAUSED", k)
    else
        S.centred(d, "NO LINE YET", S.font(28, S.TEXT, "heading", true), width / 2, top + 10 * k)
        S.centred(d, "Stand where your line should start, then press New line.", S.font(15, S.MUTED, "body", true), width / 2, top + 44 * k)
    end
    -- Report a problem, top right: quiet, with a "!" in a circle. My lines beside it.
    local function bang(dd, x, y, colour)
        dd:circle(v(x, y), 8 * k, {colour = colour, thickness = 1.8})
        dd:rect(v(x - 1 * k, y - 4.5 * k), v(x + 1 * k, y + 1 * k), {colour = colour, fill = true})
        dd:rect(v(x - 1 * k, y + 2.5 * k), v(x + 1 * k, y + 4.5 * k), {colour = colour, fill = true})
    end
    S.button(d, buttons.report, "Report a problem", {kind = "quiet", mouse = mouse, k = k, size = 13, icon = bang})
    S.button(d, buttons.lines, "My lines", {mouse = mouse, k = k, size = 13})

    -- With takes: "< Take 2 of 4 >" where the keys are; else the keys.
    local takes = L.takes_status and L.takes_status()
    if takes then
        local tp, tn = buttons.take_prev, buttons.take_next
        S.button(d, tp, "<", {mouse = mouse, k = k, off = takes.index <= 1, size = 15})
        S.button(d, tn, ">", {mouse = mouse, k = k, off = takes.index >= takes.count, size = 15})
        local label = takes.busy and "SWITCHING…" or string.format("TAKE %d OF %d", takes.index, takes.count)
        S.centred(d, label, S.font(14, takes.index == takes.count and S.TEXT or S.ACCENT, "bold", true), (tp.x1 + tn.x0) / 2, (tp.y0 + tp.y1) / 2)
    else
        local x = buttons.lines.x0 - 26 * k - S.keycap_width(d, "Esc", "Close", k) - 22 * k - S.keycap_width(d, "Enter", "Retake", k)
        local ky = (buttons.lines.y0 + buttons.lines.y1) / 2 - 11 * k
        x += S.keycap(d, x, ky, "Enter", "Retake", k) + 22 * k
        S.keycap(d, x, ky, "Esc", "Close", k)
    end

    -- The timeline: what has played in teal, retakes above, bails below, the playhead on top.
    local mid = (bar.y0 + bar.y1) / 2
    d:rect(v(bar.x0 - 2 * k, bar.y0 - 2 * k), v(bar.x1 + 2 * k, bar.y1 + 2 * k), {colour = "#000000", fill = true})
    d:rect(v(bar.x0, bar.y0), v(bar.x1, bar.y1), {colour = "#ffffff22", fill = true})
    local span = math.max(1, line.length)
    local function x_of(step) return bar.x0 + (bar.x1 - bar.x0) * step / span end
    if has_line() then
        local head = x_of(player.cursor)
        if head > bar.x0 + 1 then d:rect(v(bar.x0, bar.y0), v(head, bar.y1), {colour = S.ACCENT, fill = true}) end
        for _, step in joins do
            local x = x_of(step)
            d:poly({v(x - 7 * k, bar.y0 - 16 * k), v(x + 7 * k, bar.y0 - 16 * k), v(x, bar.y0 - 5 * k)}, {colour = S.ACCENT, fill = true})
        end
        for _, step in bails do d:circle(v(x_of(step), bar.y1 + 12 * k), 4.5 * k, {colour = S.RED, fill = true}) end
        -- Where the mouse would put it.
        local over = mouse and inside(mouse.position, {x0 = bar.x0, x1 = bar.x1, y0 = bar.y0 - 20 * k, y1 = bar.y1 + 20 * k})
        local function bubble(x, label)
            local style = S.font(14, S.INK, "bold")
            local size = d:measure(label, style)
            local bx = U.clamp(x - size.x / 2 - 9 * k, panel.x0 + 8 * k, panel.x1 - size.x - 26 * k)
            local r = {x0 = bx, x1 = bx + size.x + 18 * k, y0 = bar.y0 - 50 * k, y1 = bar.y0 - 24 * k}
            S.tile(d, r, S.PAPER, 31, k * 0.5)
            d:text(v(bx + 9 * k, (r.y0 + r.y1) / 2 - size.y / 2), label, style)
        end
        if over and not player.dragging then
            local x = mouse.position.x
            d:line(v(x, bar.y0 - 8 * k), v(x, bar.y1 + 8 * k), {colour = "#ffffff90", thickness = 2})
            bubble(x, clock_text(U.clamp((x - bar.x0) / (bar.x1 - bar.x0), 0, 1) * line.length))
        end
        d:circle(v(head, mid), 13 * k, {colour = "#000000", fill = true})
        d:circle(v(head, mid), 10 * k, {colour = S.PAPER, fill = true})
        d:circle(v(head, mid), 4 * k, {colour = S.ACCENT, fill = true})
        if player.dragging then bubble(head, clock_text(player.cursor)) end
        -- What the marks are.
        local legend = S.font(12, S.MUTED, "bold", true)
        local lx, ly = bar.x0, bar.y1 + 22 * k
        d:poly({v(lx, ly + 2 * k), v(lx + 11 * k, ly + 2 * k), v(lx + 5.5 * k, ly + 11 * k)}, {colour = S.ACCENT, fill = true})
        d:text(v(lx + 17 * k, ly - 1 * k), "RETAKE", legend)
        local rx = lx + 17 * k + d:measure("RETAKE", legend).x + 18 * k
        d:circle(v(rx + 4.5 * k, ly + 6 * k), 4.5 * k, {colour = S.RED, fill = true})
        d:text(v(rx + 15 * k, ly - 1 * k), "BAIL", legend)
    end

    -- The buttons. One primary action; settings as the game's setting tiles; the ones that end things on the right.
    local off = not has_line()
    S.button(d, buttons.replay, "Replay from here", {kind = "primary", mouse = mouse, k = k, off = off, size = 15,
        icon = function(dd, x, y, colour) replay_icon(dd, x, y, 9 * k, colour) end})
    S.button(d, buttons.whole, "Play whole line", {mouse = mouse, k = k, off = off, size = 15})
    S.button(d, buttons.carry_on, "Carry on", {mouse = mouse, k = k, size = 15})
    S.setting(d, buttons.speed, "Catch-up", string.format("%d×", catch_up), {mouse = mouse, k = k})
    S.setting(d, buttons.slowmo, "Slow-mo", string.format("%d%%", math.floor(slowmo_speed * 100 + 0.5)), {mouse = mouse, k = k})
    S.setting(d, buttons.bails, "Bails", no_bail and "Off" or "On", {mouse = mouse, k = k, value_colour = no_bail and S.RED or nil})
    if L.slowkey_label then
        local text, listening = L.slowkey_label()
        S.setting(d, buttons.slowkey, "Slow-mo key", text, {mouse = mouse, k = k,
            value_colour = listening and S.STICKY or (text == "Off" and S.MUTED or nil)})
    end
    S.button(d, buttons.new, player.confirm and "Erase line?" or "New line", {kind = player.confirm and "armed" or "tile", mouse = mouse, k = k, size = 15})
    S.button(d, buttons.stop, "Stop all", {kind = "danger", mouse = mouse, k = k, size = 15})
end

-- A small status tile in the top left, for while you skate: a dot, what it is, and its key.
local function hud_pill(d, k, y, dot, label, label_colour, key)
    local style = S.font(16, label_colour or S.TEXT, "bold", true)
    local size = d:measure(label, style)
    local x = 32 * k
    local cap = key and S.keycap_width(d, key, nil, k) + 12 * k or 0
    local w = 24 * k + (dot and 18 * k or 0) + size.x + cap
    S.tile(d, {x0 = x, x1 = x + w, y0 = y, y1 = y + 34 * k}, "#1a1a1ae0", S.seed(label), k * 0.6)
    local tx = x + 12 * k
    if dot then
        d:circle(v(tx + 6 * k, y + 17 * k), 6 * k, {colour = dot, fill = true})
        tx += 18 * k
    end
    d:text(v(tx, y + 17 * k - size.y / 2), label, style)
    if key then S.keycap(d, tx + size.x + 12 * k, y + 6 * k, key, nil, k) end
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
    if test then
        local speed = TEST_SPEEDS[math.min(test.index, #TEST_SPEEDS)]
        centred(d, string.format("Slow-motion test: take %d of %d, %s  (hands off; F11 stops it)", math.min(test.index, #TEST_SPEEDS), #TEST_SPEEDS,
            speed < 1 and string.format("slowed to %gx", speed) or "full speed"), SMALL_STYLE, width / 2, middle)
        return
    end
    if count then
        local shown = centred(d, tostring(math.max(1, math.ceil((count.ends - U.now()) / 1000))), BIG_STYLE, width / 2, middle)
        centred(d, "HANDS ON THE CONTROLLER", SMALL_STYLE, width / 2, middle + shown.y + 8 * k)
    elseif U.now() < go_until then
        centred(d, "GO!", GO_STYLE, width / 2, middle)
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

L.on_lines = nil -- the timeline's My lines: library.lua opens its window
L.on_slowkey = nil -- the timeline's Slow-mo key: slowkey.lua listens for the buttons
L.slowkey_label = nil -- what slow motion is on, and whether it is listening


-- The line's own id: given when it begins, kept when it is saved and loaded, so its takes stay with it.
function L.line_id()
    return line_uid
end
L.find_pad = function() return find_pad() end

-- Going back, counting down or testing: the line is not to be saved or replaced now.
function L.busy()
    return going_back() or count ~= nil or test ~= nil or (pending ~= nil and not pending.armed)
end

-- What a saved line keeps beside its steps: where it started, and where it was retaken and bailed.
function L.info()
    local function copy(t)
        local out = {}
        for _, value in t do table.insert(out, value) end
        return out
    end
    local now_line = reskate.tas.line() -- as it is now, not as the last tick saw it
    return {phase = now_line.phase, length = now_line.length, start = start, joins = copy(joins), bails = copy(bails)}
end

-- A saved line, loaded back by ReSkate.dll: where it starts and its marks again. Its path is read back from its steps.
function L.adopt(meta)
    local s = meta.start or {}
    line_uid = meta.line_id or line_uid or os.date("%Y%m%d-%H%M%S")
    start = {position = vector.create(s.x or 0, s.y or 0, s.z or 0), heading = s.heading or 0, on_board = s.on_board ~= false}
    if s.sensor == false then start.sensor = false end
    joins, bails, marks = {}, {}, {}
    for _, step in meta.joins or {} do table.insert(joins, step) end
    for _, step in meta.bails or {} do table.insert(bails, step) end
    line = reskate.tas.line()
    for step = 0, line.length, MARK_EVERY do
        local ok, place = pcall(reskate.tas.line_position, step)
        if ok and place then table.insert(marks, {step = step, position = place, air = false}) end
    end
    pending, count, probe, filming = nil, nil, nil, nil
    previous_phase = line.phase
    hint_until = U.now() + HINT_MS
    hint_text = "Line loaded.  F11: timeline"
    if player then
        player.cursor, player.following, player.ghost, player.confirm = line.length, true, nil, false
    end
    R.line(string.format("[line] loaded %q, %s, %d retakes", tostring(meta.name), clock_text(line.length), #joins))
end

-- What the report's recorder takes every frame: cheap, no copies.
local pad_seen, pad_at = nil, -math.huge
function L.live()
    local now = U.now()
    if now - pad_at > 1000 then pad_seen, pad_at = find_pad(), now end
    return {line = line, slowed = slowed, clock = clock_now, speed = eased_speed, timeline = player ~= nil, counting = count ~= nil,
        going_to = pending and pending.to, pad = pad_seen}
end

-- Everything ReTake knows, for a report.
function L.snapshot()
    local state = {
        phase = line.phase, length = line.length, step = line.step, since_spawn = line.since_spawn, previous_phase = previous_phase,
        slowed = slowed, clock = clock_now, game_speed = applied_speed, slowmo_on = slowmo_on, slowmo_speed = slowmo_speed,
        catch_up = catch_up, bails_off = no_bail, hint = hint_text, screen = string.format("%dx%d", width, height),
        ease_on = ease_on, eased_speed = eased_speed,
        marks = #marks, retakes = #joins, bails = #bails, pad = find_pad(), filming_rows = filming and #filming.rows,
        probe_rows = probe and #probe.rows,
    }
    if pending then
        state.pending = {to = pending.to, hand_over = pending.hand_over, retries = pending.retries, armed = pending.armed,
            air_soon = pending.air_soon, ms_since_asked = U.now() - pending.asked_at, ms_running = pending.run_at and U.now() - pending.run_at}
    end
    if count then state.countdown = {ms_left = count.ends - U.now(), how = count.how} end
    if test then state.slow_test = {to = test.to, take = test.index, running = test.run ~= nil, rows = #test.rows} end
    if player then
        state.timeline = {cursor = player.cursor, following = player.following, opened_in_flight = player.was_air,
            ms_open = U.now() - player.opened, preview_shown = player.shown}
    end
    return {state = state, start = start, marks = marks, joins = joins, bails = bails}
end

reskate.ui.screen(SCREEN, function() end, {panel = false})

L.version = VERSION

return L
