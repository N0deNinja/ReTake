-- Research, for exact replays: the skater's memory at every step of a line as it was skated, and again as it is
-- replayed. A going back puts back the board and the body each step (motion_snapshot); what the game keeps beside
-- them (the trick, the grind, timers, contacts) it does not. Played back in the session it was skated in, a line comes
-- out the same; loaded after the game is restarted, it can go another way on a rail. So: what is the same skated and
-- replayed in the session, but not replayed after a restart, is what a replay also has to put back.
-- retake statetest: a new line, its memory taken as it records. retake statetest again: the line stops, is saved to
-- My lines ("State test <time>"), and is played whole twice, its memory taken each time.
-- retake statetest replay: the line there is (the saved one, loaded after a restart) played once, its memory taken.
-- Files: <game>\logs\tas_state\statetest-<time>-skated / -replay1 / -replay2 / -loaded-<when>.tasd
local R = require("report")
local U = require("util")
local L = require("line")
local S = {}

local EVERY = 1        -- every step: about 77 KB each, 64 MB at most, so about 14 s of line
local PLAY_MS = 120000 -- a whole play, at most
local SAVE_MS = 15000  -- saving the line, at most

local library = nil -- library.lua: the line is saved there, and a loaded one says which test it was
local run = nil     -- {stage=, stamp=, play=1|2|"loaded-...", single=, began=, seen_playing=, wait_until=}

function S.set_library(lib)
    library = lib
end

local function say(text, kind)
    reskate.console.print("ReTake: " .. text)
    R.toast(text, kind)
    R.line("[statetest] " .. text)
end

local function finish(why)
    local r = run
    run = nil
    if not r then return end
    if why then
        say("state test stopped: " .. why, "warn")
    elseif r.single then
        say("state test done: logs\\tas_state\\statetest-" .. r.stamp .. "-" .. r.play .. ".tasd")
    else
        say("state test done: logs\\tas_state\\statetest-" .. r.stamp .. "-*.tasd. The line is saved in My lines as State test " .. r.stamp
            .. ": restart the game, load it, and type retake statetest replay")
    end
    R.flush()
end

function S.running()
    return run ~= nil
end

local function play(r)
    local ok, why = reskate.tas.dump(EVERY)
    if not ok then return finish("the memory could not be taken: " .. tostring(why)) end
    ok, why = L.play_whole()
    if not ok then return finish("the line would not play: " .. tostring(why)) end
    r.stage, r.began, r.seen_playing = "playing", U.now(), false
    if r.single then say("playing the line, hands off (the console closed)") else say(string.format("playing the line, take %d of 2, hands off (the console closed)", r.play)) end
end

-- The line there is, played once with its memory taken: for a line loaded after a restart.
local function replay_loaded()
    local _, length = L.phase()
    if not length or length == 0 then return false, "there is no line: load the state test's line from My lines first" end
    if library and library.busy() then return false, "a line is being saved or loaded: wait for it" end
    if L.busy() then return false, "wait for the countdown" end
    local source = library and library.source()
    local stamp = source and source.statetest
    if not stamp then return false, "the line there is not a state test's: load State test <time> from My lines" end
    run = {stage = "halting", stamp = stamp, play = "loaded-" .. os.date("%Y%m%d-%H%M%S"), single = true, wait_until = U.now()}
    reskate.tas.line_halt()
    say("state test: close the console: the loaded line plays once, its memory taken")
    return true
end

-- retake statetest: first a line to skate, then its plays. retake statetest replay: the loaded line, once.
function S.command(mode)
    if U.in_session() then return false, "ReTake is offline only" end
    if not reskate.tas.dump or not reskate.tas.dump_save then return false, "this ReSkate.dll cannot take the memory" end
    if mode == "replay" then
        S.on_line_loaded() -- a test still waiting for its line to be skated gives way
        if run then return false, "a state test is playing the line: wait for it" end
        return replay_loaded()
    end
    if not run then
        L.stop_all()
        local ok, why = reskate.tas.dump(EVERY)
        if not ok then return false, why end
        ok, why = L.new_line()
        if not ok then return false, why end
        run = {stage = "skating", stamp = os.date("%Y%m%d-%H%M%S"), play = 1}
        say("state test: skate about 10 s, over a rail, then type retake statetest again and close the console")
        return true
    end
    if run.stage ~= "skating" then return false, "the state test is playing the line: wait for it" end
    local _, length = L.phase()
    if length == 0 then return false, "nothing recorded yet" end
    -- The line stops here: what was skated is what is compared.
    reskate.tas.line_halt()
    local ok, why = reskate.tas.dump_save("statetest-" .. run.stamp .. "-skated")
    if not ok then return finish("the memory could not be saved: " .. tostring(why)) end
    run.wait_until = U.now() + 500 -- the halt reaches the line on its next step
    run.stage = "halting"
    run.save_line = true
    return true
end

-- A saved line loaded in place of the one a test is waiting to have skated: that test is over, quietly.
function S.on_line_loaded()
    if run and run.stage == "skating" then
        run = nil
        R.line("[statetest] the line being skated for the test was replaced: that test is dropped")
    end
end

function S.stop(why)
    if run then finish(why or "stopped") end
end

-- retake warmtest (research): the game's sensor block, which only starts once the skater is ridden, started by
-- writing what it holds when it has (reskate.tas.sensor_start). Then: does it stay started? A replay of a loaded line
-- needs it (line.lua refuses one without).
local warm = nil -- {at=, writes=}: checking whether the write held

function S.warm()
    if not reskate.tas.sensor_start then return false, "this ReSkate.dll cannot start the sensor" end
    local s = reskate.tas.status()
    if s.sensor_started == nil then return false, "the skater's sensor can't be read now" end
    if s.sensor_started then
        say("warm test: the sensor is already started (you've ridden since the game started): nothing to do")
        return true
    end
    local ok, why = reskate.tas.sensor_start()
    if not ok then return false, why end
    warm = {at = U.now(), writes = s.sensor_writes or 0}
    say("warm test: starting the sensor without riding…")
    return true
end

function S.warm_tick(now)
    if not warm or now - warm.at < 500 then return end
    local w = warm
    warm = nil
    local s = reskate.tas.status()
    local wrote = (s.sensor_writes or 0) > w.writes
    if s.sensor_started then
        say("warm test: the sensor is started and stayed so. Now: retake statetest replay")
    elseif wrote then
        say("warm test: written, but the game put it back: it did not stay started", "warn")
    else
        say("warm test: it could not be written", "warn")
    end
end

function S.tick(now)
    local r = run
    if not r then return end
    local phase = L.phase()
    if r.stage == "halting" then
        if now < r.wait_until or (phase ~= "played" and phase ~= "off") then return end
        if r.save_line and library then
            -- Kept in My lines, to load after a restart (retake statetest replay).
            r.save_line = false
            local ok, why = library.save("State test " .. r.stamp, {statetest = r.stamp})
            if not ok then return finish("the line could not be saved: " .. tostring(why)) end
            r.stage, r.wait_until = "saving", now + SAVE_MS
            return
        end
        play(r)
    elseif r.stage == "saving" then
        if library.busy() then
            if now > r.wait_until then finish("the line took too long to save") end
            return
        end
        play(r)
    elseif r.stage == "playing" then
        if phase == "running_up" or phase == "seeking" or phase == "counting" then r.seen_playing = true end
        if r.seen_playing and phase == "played" then
            local ok, why = reskate.tas.dump_save("statetest-" .. r.stamp .. "-" .. (r.single and r.play or "replay" .. r.play))
            if not ok then return finish("the memory could not be saved: " .. tostring(why)) end
            if r.single or r.play >= 2 then return finish() end
            r.play += 1
            r.stage, r.wait_until = "halting", now + 500
        elseif now - r.began > PLAY_MS then
            finish("the line did not finish playing")
        end
    end
end

return S
