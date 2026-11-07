-- Small helpers shared by the probes.
local U = {}

U.UP = vector.create(0, 1, 0)

function U.now()
    return reskate.time.now()
end

function U.dist(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The angle between two rotations in degrees. Accepts {x=, y=, z=, w=} or a list of four.
function U.rotation_delta(a, b)
    if not a or not b then return nil end
    local ax, ay, az, aw = a.x or a[1], a.y or a[2], a.z or a[3], a.w or a[4]
    local bx, by, bz, bw = b.x or b[1], b.y or b[2], b.z or b[3], b.w or b[4]
    if not (ax and ay and az and aw and bx and by and bz and bw) then return nil end
    local dot = math.abs(ax * bx + ay * by + az * bz + aw * bw)
    return math.deg(2 * math.acos(math.min(dot, 1)))
end

function U.clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- Multiplayer is out of scope for this mod: every test refuses to start or continue in a session.
function U.in_session()
    return reskate.session.active() == true
end

return U
