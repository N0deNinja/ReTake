-- ReTake: mess up anywhere in your line, go back to any moment, and carry on from there.
-- F11 opens the timeline. Type `retake` in the console for everything else. Offline only.
local U = require("util")
local R = require("report")
local L = require("line")
local P = require("problem")

-- Report a problem, in the timeline: its window sits over the timeline, which freezes the recorder as it opens.
L.on_report = function() return P.open(true) end
L.report_open = P.is_open
L.on_timeline = function(open)
    if open then P.freeze("you opened the timeline") elseif P.is_open() then P.drop() end
end

local function say(text)
    reskate.console.print(text)
end

local function answer(ok, why)
    if not ok then
        say("ReTake: " .. tostring(why))
        R.toast(tostring(why), "warn")
    end
end

local function help()
    say("ReTake " .. L.version .. ": mess up anywhere in your line, go back to any moment, and carry on from there.")
    say("F11                       open the timeline (again, or Esc, to close it)")
    say("Ctrl+R                    go back 1 second; press again to go further back")
    say("Click both sticks         slow motion on and off")
    say("retake new                start a new line where you stand")
    say("retake back [seconds]     go back that far (default 1)")
    say("retake whole              play the whole line as one take")
    say("retake slowmo [0.05-0.9]  slow motion on and off, or how slow (default 0.25)")
    say("retake speed [1-8]        how fast going back catches up (default 4)")
    say("retake bails              the game's bails off and on")
    say("retake stop               stop everything ReTake is doing")
    say("retake off                stop recording and forget the line")
    say("retake report             report a problem: say what went wrong, ReTake saves it with the game's state")
    say("retake files              open ReTake's log folder")
end

reskate.console.command("retake", "ReTake: rewind and retake your lines", function(args)
    local sub = args[1]
    if sub == "new" then
        answer(L.new_line())
    elseif sub == "back" then
        answer(L.back(tonumber(args[2]) or 1))
    elseif sub == "whole" then
        answer(L.play_whole())
    elseif sub == "slowmo" then
        if tonumber(args[2]) then L.set_slowmo_speed(tonumber(args[2])) else answer(L.toggle_slowmo()) end
    elseif sub == "speed" then
        L.set_catch_up(tonumber(args[2]) or 4)
    elseif sub == "bails" then
        answer(L.toggle_bails())
    elseif sub == "stop" then
        L.stop_all()
    elseif sub == "off" then
        L.stop()
    elseif sub == "report" then
        answer(P.open(false))
    elseif sub == "files" then
        R.flush()
        reskate.files.reveal("results")
    else
        help()
    end
end, {
    {name = "new", help = "Start a new line where you stand"},
    {name = "back", args = "[seconds]", help = "Go back in the line (default 1 second)"},
    {name = "whole", help = "Play the whole line as one take"},
    {name = "slowmo", args = "[0.05 to 0.9]", help = "Slow motion on and off, or how slow"},
    {name = "speed", args = "[1 to 8]", help = "How fast going back catches up"},
    {name = "bails", help = "The game's bails off and on"},
    {name = "stop", help = "Stop everything ReTake is doing"},
    {name = "off", help = "Stop recording and forget the line"},
    {name = "report", help = "Report a problem: what went wrong, saved with the game's state"},
    {name = "files", help = "Open ReTake's log folder"},
})

reskate.input.bind("retake_timeline", "F11")
reskate.input.bind("retake_back", "Ctrl+R")
reskate.input.bind("retake_slowmo", "Pad.L3+Pad.R3")

reskate.on("action", function(name)
    if name == "retake_timeline" then
        answer(L.toggle_player())
    elseif name == "retake_back" then
        answer(L.back(1))
    elseif name == "retake_slowmo" then
        answer(L.toggle_slowmo())
    end
end)

reskate.on("screen_closed", function(title)
    L.on_screen_closed(title)
    P.on_screen_closed(title)
end)

reskate.on("bail", function(e)
    L.on_bail(e)
end)

reskate.on("tick", function()
    L.tick(false)
    P.tick(U.now())
    R.tick(U.now())
end)

reskate.on("draw", function(d)
    L.draw(d)
    P.draw(d)
end)

reskate.on("unload", function()
    R.flush()
end)

R.load()
reskate.log("ReTake " .. L.version .. " ready: F11 opens the timeline, `retake` in the console for help")
