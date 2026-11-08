-- ReTake: mess up anywhere in your line, go back to any moment, and carry on from there.
-- F11 opens the timeline. Type `retake` in the console for everything else. Offline only.
-- How long each part of the load takes, for the log: the game stops a plugin whose load runs over 50 ms.
local load_began, load_times = reskate.time.now(), {}
local function took(what)
    table.insert(load_times, string.format("%s %.1f", what, reskate.time.now() - load_began))
end
local U = require("util")
local R = require("report")
local L = require("line")
took("line")
local P = require("problem")
local T = require("coretest")
local LIB = require("library")
took("library")
local ST = require("statetest")
local TK = require("takes")
local GH = require("ghosttest")
local GHO = require("ghosts")
local K = require("slowkey")
took("modules")

-- Report a problem and My lines, in the timeline: their windows sit over the timeline, which waits under them (and
-- freezes the recorder as it opens).
L.on_report = function() return P.open(true) end
L.on_lines = function() return LIB.open(true) end
-- The slow-motion button: the timeline's Slow-mo key chip listens for the buttons.
L.on_slowkey = function() return K.press() end
L.slowkey_label = function()
    if K.is_listening() then return "Press now", true end
    return K.label(), false
end
L.report_open = function() return P.is_open() or LIB.is_open() end
L.on_stop_all = function()
    T.stop("Stop all")
    GH.stop()
    GHO.stop("Stop all")
end
GHO.set_library(LIB)
-- Takes: a retake keeps the line as it was; the timeline steps between them.
TK.set_library(LIB)
ST.set_library(LIB)
L.on_retake = TK.on_retake
L.takes_status = TK.status
L.on_take_step = TK.step
L.on_new_line = function(id)
    LIB.on_new_line()
    local saved = {}
    for _, e in LIB.list() do
        if e.meta.line_id then saved[e.meta.line_id] = true end
    end
    TK.on_new_line(id, saved)
end
LIB.on_loaded = function()
    TK.on_loaded(L.line_id())
    ST.on_line_loaded()
end
L.on_timeline = function(open)
    if open then
        GHO.stop("the timeline opened")
        P.freeze("you opened the timeline")
    else
        if P.is_open() then P.drop() end
        if LIB.is_open() then LIB.drop() end
    end
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
    say("retake save [name]        save the line, to come back to it after closing the game")
    say("retake lines              your saved lines, numbered (also: F11, My lines)")
    say("retake load <number>      load a saved line, in place of the one you have")
    say("retake delete <number>    delete a saved line")
    say("F10                       ghost lines: other skaters' lines to watch and try (also: retake ghosts)")
    say("retake ghost make [name]  make a ghost line of your line, to share (it plays once, hands off)")
    say("retake ghost watch <n>    watch a ghost line through its skater's eyes (retake ghosts numbers them)")
    say("retake ghost try <n>      try a ghost line, its skater riding beside you")
    say("retake ghost stop         stop watching or trying")
    say("retake name [name]        the name on the ghost lines you make; alone, says it")
    say("retake back [seconds]     go back that far (default 1)")
    say("retake whole              play the whole line as one take")
    say("retake slowmo [0.05-0.9]  slow motion on and off, or how slow (default 0.25)")
    say("retake slowmo key [combo] the slow-motion button: Pad.LB+Pad.RB, Ctrl+K, off or default (L3 + R3); alone, says it")
    say("                          (or in the timeline: click Slow-mo key and press the buttons you want)")
    say("retake speed [1-8]        how fast going back catches up (default 4)")
    say("retake bails              the game's bails off and on")
    say("retake stop               stop everything ReTake is doing")
    say("retake off                stop recording and forget the line")
    say("retake report             report a problem: say what went wrong, ReTake saves it with the game's state")
    say("retake files              open ReTake's log folder")
    say("retake slowtest [m:ss]    test slow motion at that moment of the line (it replaces what comes after)")
    say("retake skatertest         stand still: the skater is rebuilt at full speed and in slow motion, and saved each time")
    say("retake ghosttest          research: a skater model like you, copying you, 3 m to the side (again: off)")
    say("retake statetest          research: skate a short line, then again to replay it twice, the memory taken each time")
    say("retake statetest replay   research: the state test's line, loaded after a restart, played once with the memory taken")
    say("retake warmtest           research: start the game's sensor without riding, for a loaded line's replay")
    say("retake ease [on|off]      slowing down eases in (on, the default) or happens at once; alone, says which")
end

-- "24.98", "0:24.98" or nothing.
local function seconds_of(text)
    if not text then return nil end
    local minutes, seconds = string.match(text, "^(%d+):(%d+%.?%d*)$")
    if minutes then return tonumber(minutes) * 60 + tonumber(seconds) end
    return tonumber(text)
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
        if args[2] == "key" then
            local ok, why = true, "Slow motion is on " .. K.label()
            if args[3] then ok, why = K.set(args[3]) end
            if ok then say("ReTake: " .. tostring(why)) else answer(ok, why) end
        elseif tonumber(args[2]) then L.set_slowmo_speed(tonumber(args[2])) else answer(L.toggle_slowmo()) end
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
    elseif sub == "slowtest" then
        if args[2] and not seconds_of(args[2]) then
            answer(false, "slowtest takes a moment of the line, like 0:24.98")
        else
            answer(L.slow_test(seconds_of(args[2])))
        end
    elseif sub == "ease" then
        local on = nil
        if args[2] == "on" then on = true elseif args[2] == "off" then on = false end
        say(L.ease(on) and "ReTake: easing is ON, slowing down and speeding up ease in (retake ease off: at once)"
            or "ReTake: easing is OFF, speed changes are at once (retake ease on: they ease in)")
    elseif sub == "save" then
        local name = table.concat(args, " ", 2)
        local ok, why = LIB.save(name)
        answer(ok, why)
        if ok then say("ReTake: saving the line…") end
    elseif sub == "lines" then
        local entries = LIB.list()
        if #entries == 0 then say("ReTake: no lines saved yet. retake save saves the one you have") end
        for index, e in entries do
            local seconds = (e.meta.length or 0) / 60
            say(string.format("%3d  %s  (%d:%05.2f, saved %s)", index, tostring(e.meta.name), math.floor(seconds / 60), seconds % 60, tostring(e.meta.saved)))
        end
    elseif sub == "load" or sub == "delete" then
        local entry = LIB.list()[tonumber(args[2]) or 0]
        if not entry then
            answer(false, "which one? retake lines numbers them")
        elseif sub == "load" then
            answer(LIB.load(entry.id))
        else
            local ok, why = LIB.delete(entry.id)
            answer(ok, why)
            if ok then say("ReTake: deleted " .. tostring(entry.meta.name)) end
        end
    elseif sub == "ghosts" then
        local entries = GHO.list(true)
        if #entries == 0 then say("ReTake: no ghost lines yet. retake ghost make makes one of your line; F10, Open folder, for ones sent to you") end
        for index, e in entries do
            local seconds = (e.meta.length or 0) / 60
            say(string.format("%3d  %s by %s  (%d:%05.2f)", index, tostring(e.meta.name), tostring(e.meta.author or "someone"), math.floor(seconds / 60), seconds % 60))
        end
    elseif sub == "ghost" then
        local what = args[2]
        if what == "make" then
            answer(GHO.make(table.concat(args, " ", 3)))
        elseif what == "watch" or what == "try" then
            local entry = GHO.list(true)[tonumber(args[3]) or 0]
            if not entry then answer(false, "which one? retake ghosts numbers them") else answer(GHO.go(entry, what)) end
        elseif what == "stop" then
            GHO.stop("stopped from the console")
        else
            answer(false, "retake ghost make [name], watch <n>, try <n> or stop")
        end
    elseif sub == "name" then
        local text = table.concat(args, " ", 2)
        if text ~= "" then
            local ok, why = GHO.set_name(text)
            answer(ok, why)
            if ok then say("ReTake: your ghost lines are signed " .. tostring(GHO.name())) end
        else
            say("ReTake: your ghost lines are signed " .. tostring(GHO.name() or "a skater") .. ". retake name <name> changes it")
        end
    elseif sub == "ghosttest" then
        answer(GH.toggle())
    elseif sub == "statetest" then
        answer(ST.command(args[2]))
    elseif sub == "warmtest" then
        answer(ST.warm())
    elseif sub == "skatertest" then
        if T.running() then
            T.stop("stopped from the console")
        else
            L.stop_all() -- the line, the slow motion and the bails, all off: the test sets the speed itself
            answer(T.start())
        end
    else
        help()
    end
end, {
    {name = "new", help = "Start a new line where you stand"},
    {name = "save", args = "[name]", help = "Save the line, to come back to it after closing the game"},
    {name = "lines", help = "Your saved lines, numbered"},
    {name = "load", args = "<number>", help = "Load a saved line, in place of the one you have"},
    {name = "delete", args = "<number>", help = "Delete a saved line"},
    {name = "ghosts", help = "Ghost lines: other skaters' lines to watch and try, numbered"},
    {name = "ghost", args = "make [name] | watch <n> | try <n> | stop", help = "Make, watch or try a ghost line"},
    {name = "name", args = "[name]", help = "The name on the ghost lines you make"},
    {name = "back", args = "[seconds]", help = "Go back in the line (default 1 second)"},
    {name = "whole", help = "Play the whole line as one take"},
    {name = "slowmo", args = "[0.05 to 0.9 | key [combo|off]]", help = "Slow motion on and off, how slow, or its button"},
    {name = "speed", args = "[1 to 8]", help = "How fast going back catches up"},
    {name = "bails", help = "The game's bails off and on"},
    {name = "stop", help = "Stop everything ReTake is doing"},
    {name = "off", help = "Stop recording and forget the line"},
    {name = "report", help = "Report a problem: what went wrong, saved with the game's state"},
    {name = "files", help = "Open ReTake's log folder"},
    {name = "slowtest", args = "[m:ss]", help = "Test slow motion at a moment of the line (replaces what comes after)"},
    {name = "ghosttest", help = "Research: a skater model like you copies you, 3 m to the side"},
    {name = "statetest", help = "Research: skate a line, then again to replay it twice, taking the memory each time"},
    {name = "warmtest", help = "Research: start the game's sensor without riding first"},
    {name = "ease", args = "[on|off]", help = "Slowing down eases in (on) or happens at once (off); alone, says which"},
    {name = "skatertest", help ="Standing still: rebuild the skater at full speed and in slow motion, saving it each time"},
})

reskate.input.bind("retake_timeline", "F11")
reskate.input.bind("retake_back", "Ctrl+R")
K.load() -- retake_slowmo: L3 + R3, or the button chosen in the timeline
reskate.input.bind("retake_ghosts", "F10")

reskate.on("action", function(name)
    if T.running() then
        T.stop("a key was pressed") -- the test sets the speed and rebuilds the skater: nothing else meanwhile
        return
    end
    if name == "retake_timeline" then
        answer(L.toggle_player())
    elseif name == "retake_back" then
        answer(L.back(1))
    elseif name == "retake_slowmo" then
        answer(L.toggle_slowmo())
    elseif name == "retake_ghosts" then
        if U.in_session() then return answer(false, "ReTake is offline only") end
        answer(GHO.toggle())
    end
end)

reskate.on("screen_closed", function(title)
    L.on_screen_closed(title)
    P.on_screen_closed(title)
    LIB.on_screen_closed(title)
    GHO.on_screen_closed(title)
    K.cancel()
end)

reskate.on("bail", function(e)
    L.on_bail(e)
end)

reskate.on("tick", function()
    L.tick(T.running())
    T.tick()
    ST.tick(U.now())
    ST.warm_tick(U.now())
    TK.tick(U.now())
    GH.tick()
    LIB.tick(U.now())
    GHO.tick(U.now())
    K.tick()
    P.tick(U.now())
    R.tick(U.now())
end)

reskate.on("draw", function(d)
    L.draw(d)
    T.draw(d, {colour = "#ffffffd0", size = 26 * d:size().y / 1080, shadow = true, font = "heading"})
    P.draw(d)
    LIB.draw(d)
    GHO.draw(d)
end)

reskate.on("unload", function()
    GHO.stop("unloading")
    R.flush()
end)

R.load()
took("ready")
reskate.log("ReTake " .. L.version .. " ready: F11 opens the timeline, `retake` in the console for help (loaded in ms: " .. table.concat(load_times, ", ") .. ")")
