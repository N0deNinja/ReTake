-- One sample per physics step, on a clock of game time. Game time rather than real time, so runs at
-- different speeds line up, and rather than a step count, so runs with different step lengths do too.
local U = require("util")
local C = {}

C.sim_t = 0
C.steps = 0
C.pose_names = nil -- what the first step offered, for the report

local listeners = {}
local jump = nil

function C.listen(fn)
    table.insert(listeners, fn)
end

-- Calls fn(sample) once, at the first step whose position is more than `threshold` metres from where
-- the last step's velocity would have put it. This is how a teleport's arrival is seen: the docs say
-- one takes up to a few seconds and returns nothing when it lands.
function C.watch_jump(threshold, fn)
    jump = {threshold = threshold, fn = fn, prev = nil}
end

function C.stop_watch()
    jump = nil
end

local function check_jump(sample)
    if not jump or not sample.x then return end
    local prev = jump.prev
    if prev and prev.src ~= sample.src then
        -- The body being read changed, as it does when a teleport rebuilds the skater.
        local fn = jump.fn
        jump = nil
        fn(sample)
        return
    end
    if prev then
        local gap = sample.t - prev.t
        local px = prev.x + (prev.vx or 0) * gap
        local py = prev.y + (prev.vy or 0) * gap
        local pz = prev.z + (prev.vz or 0) * gap
        if U.dist(sample.x, sample.y, sample.z, px, py, pz) > jump.threshold then
            local fn = jump.fn
            jump = nil
            fn(sample)
            return
        end
    end
    jump.prev = sample
end

reskate.on("physics_step", function(e)
    C.sim_t += e.seconds
    C.steps += 1

    local x, y, z, src
    local poses = e.poses
    -- The board's root when the runtime gives it: the pelvis sways with the skater's animation.
    local pose = e.board or (poses and poses.Pelvis)
    if pose and pose.transform then
        local m = pose.transform
        x, y, z = m[13], m[14], m[15]
        src = e.board and "board" or "pelvis"
    else
        local p = reskate.skater.position()
        if p then
            x, y, z = p.x, p.y, p.z
            src = "tick"
        end
    end

    if C.pose_names == nil and poses then
        local names = {}
        for name in poses do table.insert(names, name) end
        table.sort(names)
        C.pose_names = table.concat(names, ",")
    end

    local v = e.velocity
    local board_spin = e.board and e.board.spin
    -- Which way the board faces, for a slide: its transform's first and third rows are axes across the deck
    -- and along it (which one is the nose is not assumed), headings in degrees as the velocity's are.
    local across, along, up_y
    local bm = e.board and e.board.transform
    if bm then
        across = math.deg(math.atan2(bm[1], bm[3]))
        along = math.deg(math.atan2(bm[9], bm[11]))
        up_y = bm[6]
    end
    -- How far the pelvis is from the board: a body left behind by the board shows here.
    local body_gap
    local pelvis = poses and poses.Pelvis and poses.Pelvis.transform
    if pelvis and x and src == "board" then body_gap = U.dist(pelvis[13], pelvis[14], pelvis[15], x, y, z) end
    -- How fast the hands and forearms move against the pelvis, the fastest of them: a kick to the arms shows here.
    local hand_speed
    local pelvis_v = poses and poses.Pelvis and poses.Pelvis.velocity
    if pelvis_v then
        for _, name in {"Left hand", "Right hand", "Left forearm", "Right forearm"} do
            local w = poses[name] and poses[name].velocity
            if w then
                hand_speed = math.max(hand_speed or 0, math.sqrt((w[1] - pelvis_v[1]) ^ 2 + (w[2] - pelvis_v[2]) ^ 2 + (w[3] - pelvis_v[3]) ^ 2))
            end
        end
    end
    local sample = {
        hand_speed = hand_speed,
        across = across,
        along = along,
        up_y = up_y,
        yaw_rate = board_spin and board_spin[2],
        body_gap = body_gap,
        spin = board_spin and math.sqrt(board_spin[1] ^ 2 + board_spin[2] ^ 2 + board_spin[3] ^ 2),
        hash = e.hash,
        bhash = e.board_hash,
        t = C.sim_t,
        at = e.at,
        dt = e.seconds,
        x = x,
        y = y,
        z = z,
        vx = v and v[1],
        vy = v and v[2],
        vz = v and v[3],
        air = e.airborne,
        wipe = e.wipeout,
        rag = e.ragdoll,
        state = e.state,
        src = src,
    }
    C.last = sample
    check_jump(sample)
    for _, fn in listeners do fn(sample) end
end)

return C
