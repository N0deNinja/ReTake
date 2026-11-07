-- What ReTake did, for a bug report: the game's log, and files in Mods/.reskate_plugin_data/ReTake/results/.
local R = {}

local REPORT = "results/report.txt"
local MAX_FILE = 1024 * 1024
local ROTATE_AT = 900 * 1024

local text = ""
local dirty = false
local last_flush = 0

function R.load()
    local existing = reskate.files.read(REPORT)
    text = existing or ""
end

function R.flush()
    if not dirty then return end
    dirty = false
    if #text > ROTATE_AT then
        reskate.files.write("results/report-" .. os.date("%Y%m%d-%H%M%S") .. ".txt", text)
        text = ""
    end
    local ok, why = reskate.files.write(REPORT, text)
    if not ok then reskate.log("could not save the report: " .. tostring(why), "warn") end
end

function R.tick(now)
    if dirty and now - last_flush > 2000 then
        last_flush = now
        R.flush()
    end
end

function R.line(message)
    reskate.log(message) -- the log and the file, not the console: a player has no use for them there
    text ..= os.date("%H:%M:%S ") .. message .. "\n"
    dirty = true
end

function R.heading(message)
    R.line("")
    R.line("=== " .. message .. " (" .. os.date("%Y-%m-%d") .. ") ===")
end

function R.data(path, contents)
    if #contents > MAX_FILE then contents = string.sub(contents, 1, MAX_FILE) end
    local ok, why = reskate.files.write(path, contents)
    if not ok then reskate.log("could not save " .. path .. ": " .. tostring(why), "warn") end
    return ok
end

function R.toast(message, level)
    reskate.ui.toast(message, level)
end

return R
