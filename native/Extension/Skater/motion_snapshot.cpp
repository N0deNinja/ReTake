#include "motion_snapshot.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/skater_body.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include <Windows.h>
#include <cmath>
#include <cstring>

namespace dingosdk::motion_snapshot {
namespace {
namespace body = addr::skater_body;
namespace state = addr::skater_state;

bool poke_bytes(std::uintptr_t address, const void* data, std::size_t size) noexcept {
    __try {
        std::memcpy(reinterpret_cast<void*>(address), data, size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}
bool usable(const Body& value) noexcept {
    for (const float v : value.transform)
        if (!std::isfinite(v)) return false;
    for (const float v : value.velocity)
        if (!std::isfinite(v)) return false;
    for (const float v : value.spin)
        if (!std::isfinite(v)) return false;
    return true;
}
// Where a physics object's bodies start, when it is what it should be.
std::uintptr_t bodies_of(std::uintptr_t physics, std::uintptr_t vtable, std::uint32_t count) noexcept {
    std::uintptr_t type{}, bodies{};
    std::uint32_t found{};
    if (!memory::peek(physics, type) || type != vtable || !memory::peek(physics + state::physics_bodies_offset, bodies) ||
        !memory::peek(bodies, found) || found != count)
        return 0;
    return bodies;
}
struct Holders {
    std::uintptr_t board{}, skeleton{};
};
bool holders(const NoBailSkater& skater, Holders& result) noexcept {
    std::uintptr_t holder{}, board{}, rig{};
    if (!memory::peek(skater.core + state::board_holder_offset, holder) || !memory::peek(holder + state::board_physics_offset, board) ||
        !memory::peek(skater.rig + state::rig_physics_offset, rig))
        return false;
    result.board = bodies_of(board, skater.base + state::board_physics_vtable, state::board_body_count);
    result.skeleton = bodies_of(rig, skater.base + state::rig_physics_vtable, state::rig_body_count);
    return result.board && result.skeleton;
}
template <std::size_t N> bool read_group(std::uintptr_t bodies, std::array<Body, N>& group) noexcept {
    for (std::size_t i = 0; i < N; ++i) {
        const auto at = bodies + i * state::physics_body_size;
        auto& b = group[i];
        if (!memory::peek(at + body::body_transform_offset, b.transform) || !memory::peek(at + state::body_velocity_offset, b.velocity) ||
            !memory::peek(at + state::body_spin_offset, b.spin) || !usable(b))
            return false;
    }
    return true;
}
template <std::size_t N> bool write_group(std::uintptr_t bodies, const std::array<Body, N>& group) noexcept {
    for (std::size_t i = 0; i < N; ++i) {
        const auto at = bodies + i * state::physics_body_size;
        const auto& b = group[i];
        std::uint32_t flags{};
        if (!memory::peek(at + state::body_flags_offset, flags) ||
            !poke_bytes(at + body::body_transform_offset, b.transform.data(), sizeof(b.transform)) ||
            !poke_bytes(at + state::body_velocity_offset, b.velocity.data(), sizeof(b.velocity)) ||
            !poke_bytes(at + state::body_spin_offset, b.spin.data(), sizeof(b.spin)))
            return false;
        flags |= state::body_flag_rotation | state::body_flag_position | state::body_flag_velocity | state::body_flag_spin;
        if (!poke_bytes(at + state::body_flags_offset, &flags, sizeof(flags))) return false;
    }
    return true;
}
}

bool board_place(const NoBailSkater& skater, std::array<float, 3>& place) noexcept {
    Holders at;
    std::array<float, 16> transform{};
    if (!holders(skater, at) || !memory::peek(at.board + body::body_transform_offset, transform)) return false;
    place = {transform[12], transform[13], transform[14]};
    return std::isfinite(place[0]) && std::isfinite(place[1]) && std::isfinite(place[2]);
}

bool capture(const NoBailSkater& skater, Snapshot& snapshot) noexcept {
    snapshot.valid = false;
    Holders at;
    if (!holders(skater, at) || !read_group(at.board, snapshot.board) || !read_group(at.skeleton, snapshot.skeleton)) return false;
    snapshot.valid = true;
    return true;
}

void match_flight_step(const NoBailSkater& skater, float step) noexcept {
    if (!std::isfinite(step) || step < 1e-5f || step > 0.1f) return;
    std::uintptr_t block{}, air{}, air_block{};
    float dt{};
    if (!memory::peek(skater.core + state::core_jump_block_offset, block) || !block || !memory::peek(skater.core + state::core_air_state_offset, air) || !air ||
        !memory::peek(air + state::air_state_block_offset, air_block) || air_block != block || !memory::peek(block + state::jump_block_dt_offset, dt))
        return;
    if (dt == step || !std::isfinite(dt) || dt < 1e-5f || dt > 0.1f) return;
    // All of it together, at the same time along the path: the frame, the flight's length, and both frame times.
    const double ratio = static_cast<double>(dt) / step;
    const auto scaled = [&](std::int32_t value) { return static_cast<std::int32_t>(std::lround(static_cast<double>(value) * ratio)); };
    std::int32_t frame{}, frames{}, new_frame{}, new_frames{};
    float request_dt{}, new_request_dt{};
    std::uintptr_t request{};
    if (memory::peek(air + state::air_state_frame_offset, frame) && frame > 0 && frame < 10000000) {
        new_frame = scaled(frame);
        (void)poke_bytes(air + state::air_state_frame_offset, &new_frame, sizeof(new_frame));
    }
    if (memory::peek(block + state::jump_block_request_offset, request) && request) {
        if (memory::peek(request + state::request_frames_offset, frames) && frames > 0 && frames < 10000000) {
            new_frames = scaled(frames);
            (void)poke_bytes(request + state::request_frames_offset, &new_frames, sizeof(new_frames));
        }
        if (memory::peek(request + state::request_dt_offset, request_dt) && std::isfinite(request_dt) && request_dt >= 1e-5f && request_dt <= 0.1f) {
            new_request_dt = static_cast<float>(request_dt / ratio);
            (void)poke_bytes(request + state::request_dt_offset, &new_request_dt, sizeof(new_request_dt));
        }
    }
    (void)poke_bytes(block + state::jump_block_dt_offset, &step, sizeof(step));
    try {
        logging::log(logging::Level::info, logging::Channel::skater, "Flight step {} -> {} s: frame {} -> {}, frames {} -> {}, request step {} -> {}.",
            dt, step, frame, new_frame, frames, new_frames, request_dt, new_request_dt);
    } catch (...) {
    }
}

bool restore(const NoBailSkater& skater, const Snapshot& snapshot, bool skeleton) noexcept {
    Holders at;
    if (!snapshot.valid || !holders(skater, at)) return false;
    return write_group(at.board, snapshot.board) && (!skeleton || write_group(at.skeleton, snapshot.skeleton));
}
}
