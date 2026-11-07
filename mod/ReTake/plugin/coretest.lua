-- Research: what the game works out from the skater's step length when it builds the skater. Slow motion makes the
-- steps shorter by changing that one length in a skater already built (Extension/Skater/game_speed.h), so anything
-- the build worked out from it stays as it was for full speed. Here the skater is built again where it stands, at
-- full speed and in slow motion in turn, and its memory saved after each build: what is the same in every full
-- speed build and in every slow one, but differs between them, is what the build works out from the step.
local C = require("clock")
local R = require("report")
local U = require("util")
local T = {}

-- Each build: its speed, and its name in the files. Full speed first and last, so the skater ends as the game builds it.
-- The last is the check: built at full speed, then slowed as slow motion slows it, without a build. With ReSkate.dll
-- following the step (step_fields.h), it matches the 0.05x builds wherever the build worked something out from the step.
local STAGES = {{1, "a-1x"}, {0.05, "b-0.05x"}, {1, "c-1x"}, {0.05, "d-0.05x"}, {0.25, "e-0.25x"}, {1, "f-1x"},
    {1, "g-1x-then-slowed-0.05x", 0.05}}
local SETTLE_TICKS = 20  -- after the speed is asked for, before the teleport: the game's settings change on its tick
local SETTLED_STEPS = 90 -- physics steps after the build before its memory is read
local STAGE_MS = 90000   -- longer than that and something is wrong (a teleport in slow motion takes 20 times as long)

local run = nil -- {stage=, folder=, wait=, ticks=, built=, asked_at=, notes=}

local function finish(why)
    local r = run
    run = nil
    reskate.time.slow(1)
    if not r then return end
    table.insert(r.notes, why and ("stopped: " .. why) or "done")
    R.data(r.folder .. "/notes.txt", table.concat(r.notes, "\n") .. "\n")
    R.line("[coretest] " .. (why and ("stopped: " .. why) or "done") .. ", in " .. r.folder)
    R.flush()
    reskate.console.print("ReTake: skater test " .. (why and ("stopped: " .. why) or "done") .. ". Files in results/" .. r.folder:gsub("^results/", ""))
    if why then R.toast("Skater test stopped: " .. why, "warn") else R.toast("Skater test done") end
end

function T.running()
    return run ~= nil
end

-- Starts it: the skater must stand still on its board, and the line is stopped first (the caller does that).
function T.start()
    if U.in_session() then return false, "ReTake is offline only" end
    if run then return false, "the skater test is already running" end
    if not reskate.tas.skater_dump or not reskate.tas.skater_dump_status then return false, "this ReSkate.dll has no skater_dump: install ReTake's DLL from this version" end
    local s = reskate.skater.get()
    if not s then return false, "there is no skater yet" end
    if s.airborne or s.speed > 0.5 then return false, "stand still on your board, on flat ground, then run it" end
    run = {stage = 1, folder = "results/core/" .. os.date("%Y%m%d-%H%M%S"), wait = "speed", ticks = 0, asked_at = U.now(),
        notes = {"ReTake skater test, " .. os.date("%Y-%m-%d %H:%M:%S")}}
    reskate.time.slow(STAGES[1][1])
    R.line("[coretest] started")
    return true
end

function T.stop(why)
    if run then finish(why or "stopped") end
end

-- Once a tick.
function T.tick()
    local r = run
    if not r then return end
    local speed, name = STAGES[r.stage][1], STAGES[r.stage][2]
    if U.now() - r.asked_at > STAGE_MS then return finish("build " .. name .. " did not finish in time (" .. r.wait .. ")") end
    if r.wait == "speed" then
        r.ticks += 1
        if r.ticks < SETTLE_TICKS then return end
        local s = reskate.skater.get()
        if not s then return finish("the skater went away") end
        local before = reskate.tas.line().since_spawn
        local ok, why = reskate.skater.teleport(s.position, s.heading, {on_board = true})
        if not ok then
            -- At most two a second: the next tick tries again.
            r.ticks = SETTLE_TICKS - 10
            table.insert(r.notes, name .. ": teleport refused, again: " .. tostring(why))
            return
        end
        r.wait, r.built = "build", before
    elseif r.wait == "build" then
        -- The core counts its steps since its build: back near 0 is the new build.
        local since = reskate.tas.line().since_spawn
        if since < r.built then r.wait = "settle" end
        r.built = math.max(r.built, since)
    elseif r.wait == "settle" then
        if reskate.tas.line().since_spawn < SETTLED_STEPS then return end
        local then_speed = STAGES[r.stage][3]
        if then_speed and not r.slowed_at then
            -- Slowed now, the skater as it was built: as many steps more before it is read.
            reskate.time.slow(then_speed)
            r.slowed_at = reskate.tas.line().since_spawn
            return
        end
        if r.slowed_at and reskate.tas.line().since_spawn < r.slowed_at + SETTLED_STEPS then return end
        local path = r.folder .. "/" .. name .. ".bin"
        local ok, why = reskate.tas.skater_dump(path)
        if not ok then return finish("the dump failed: " .. tostring(why)) end
        local s = reskate.skater.get()
        table.insert(r.notes, string.format("%s: speed %g, step %.7f s, %d steps since the build, moving %.2f m/s, %s", name, speed,
            C.last and C.last.dt or -1, reskate.tas.line().since_spawn, s and s.speed or -1, path))
        -- It is written on a thread of its own: the next build waits for it.
        r.wait = "saving"
    elseif r.wait == "saving" then
        local status = reskate.tas.skater_dump_status()
        if status == "writing" then return end
        if status ~= "saved" then return finish("the dump failed: " .. tostring(status)) end
        r.stage += 1
        r.slowed_at = nil
        if r.stage > #STAGES then
            -- Full speed, and once more onto the board where it stands: the quick teleports can leave the skater on foot.
            reskate.time.slow(1)
            r.wait, r.ticks, r.stage = "board", 0, #STAGES
            return
        end
        r.wait, r.ticks, r.asked_at = "speed", 0, U.now()
        reskate.time.slow(STAGES[r.stage][1])
    elseif r.wait == "board" then
        r.ticks += 1
        if r.ticks < 60 then return end
        local s = reskate.skater.get()
        if s then
            local ok = reskate.skater.teleport(s.position, s.heading, {on_board = true})
            if not ok and r.ticks < 180 then return end
        end
        finish()
    end
end

-- On the screen while it runs.
function T.draw(d, style)
    if not run then return end
    local size = d:size()
    local text = string.format("Skater test: build %d of %d (%s). Hands off.", run.stage, #STAGES, STAGES[run.stage][2])
    local m = d:measure(text, style)
    d:text(vector.create(size.x / 2 - m.x / 2, size.y * 0.24), text, style)
end

return T
