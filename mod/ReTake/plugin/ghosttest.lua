-- Research, for a ghost that is the skater itself rather than lines: retake ghosttest shows a real skater model in
-- the player's outfit beside the skater, copying it live, through the same native code multiplayer shows another
-- player with (reskate.tas.ghost_probe). Again, it goes. If it shows, the timeline's ghost can be one: the pose kept
-- with each step of a line, and shown at the moment picked.
local R = require("report")
local G = {}

local OFFSET = {3, 0, 0} -- metres beside the skater
local on = false
local last = nil -- the last answer, so the log has each change once

function G.running()
    return on
end

function G.toggle()
    if not reskate.tas.ghost_probe then return false, "this ReSkate.dll has no ghost test" end
    on = not on
    if not on then
        reskate.tas.ghost_probe(false)
        last = nil
        R.line("[ghosttest] off")
        reskate.console.print("ReTake: ghost test off")
    else
        R.line("[ghosttest] on")
        reskate.console.print("ReTake: ghost test on: a skater like you should appear 3 m to the side and copy you. retake ghosttest again: off")
    end
    return true
end

function G.stop()
    if on then G.toggle() end
end

function G.tick()
    if not on then return end
    local ok, why = reskate.tas.ghost_probe(true, OFFSET[1], OFFSET[2], OFFSET[3])
    local answer = ok and "shown" or tostring(why)
    if answer ~= last then
        last = answer
        R.line("[ghosttest] " .. answer)
        R.flush()
    end
end

return G
