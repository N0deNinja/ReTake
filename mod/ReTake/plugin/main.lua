-- ReTake: mess up anywhere in your line, go back to any moment, and carry on from there.
-- F11 opens the timeline. Type `retake` in the console for everything else. Offline only.
--
-- ReTake loads in steps, a module at a time, each in a call of its own (reskate.time.after): ReSkate stops a plugin
-- whose load runs longer than 50 ms, and at the game's start, with the PC busy loading the game, ReTake's whole setup
-- in one call did go over (2026-11-09: F11 did nothing). retake.lua, last, sets up the command, binds and handlers.
local STEPS = {"util", "report", "clock", "ui", "line", "problem", "coretest", "library", "statetest", "takes", "ghosttest",
    "ghosts", "slowkey", "retake"}
local began = reskate.time.now()
local longest, longest_step = 0, ""

local function step(i)
    local at = reskate.time.now()
    local ok, result = pcall(require, STEPS[i])
    local took = reskate.time.now() - at
    if took > longest then longest, longest_step = took, STEPS[i] end
    if not ok then
        reskate.log("ReTake could not load (" .. STEPS[i] .. "): " .. tostring(result))
        return
    end
    if i < #STEPS then
        reskate.time.after(0, function() step(i + 1) end)
        return
    end
    reskate.log(string.format("ReTake %s ready: F11 opens the timeline, `retake` in the console for help (loaded in %d steps over %.0f ms; the longest, %s, %.1f ms)",
        tostring(result), #STEPS, reskate.time.now() - began, longest_step, longest))
end

reskate.time.after(0, function() step(1) end)
