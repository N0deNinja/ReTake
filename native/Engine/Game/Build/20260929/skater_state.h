#pragma once
#include "client_source_spawn.h"
#include <array>
#include <cstdint>

namespace dingosdk::game::build::v20260929::skater_state {
// Supported SHA-256 fbce74d5e28ef525dbba2cb4adbebc13405bdbd88f31bc940bca45e4ae88b8f9.
// The skater's live state, read-only (Extension/Skater/skater_physics.h).

// The physics state the core's selector chose this step (no_bail.h: choose_physics_state; its
// offboard_physics_state is the one on foot and through a whole bail).
inline constexpr std::uintptr_t physics_state_offset = 0x1414; // uint32, context
inline constexpr std::array<std::uint32_t, 2> board_air_states{200, 201}; // PHYSICS_AIR, KNOWN_AIR

// The core's trick state (its vtable slot +0xb0 returns core+0x3b8) holds the offboard state
// at +0x78: the skater on foot and in a ragdoll (the script native GetOffboardScoring copies
// it out). Each offboard substate class raises exactly one substate flag of it from its vtable
// (0x1465e8c28 on, each beside its name and id); the three ragdoll ones, FollowRagdoll (3)
// 0x14482d970, FollowAnimatedRagdoll (4) 0x14482d3b0 and FollowSimulatedRagdoll (5) 0x14482db00,
// the same one. In the air is the substate's own +0x150, copied over. Flags are one byte, 0 or 1.
inline constexpr std::uintptr_t trick_state_offset = 0x3b8;   // core
inline constexpr std::uintptr_t offboard_state_offset = 0x78; // trick state
inline constexpr std::uintptr_t ragdoll_offset = 0x18c;       // offboard state
inline constexpr std::uintptr_t in_the_air_offset = 0x180;    // offboard state

// How fast the skater moves: the linear velocity of its physics bodies, read as the SDK's noclip
// reads and writes them (Extension/Skater/client_noclip.cpp). The board's physics: core+0x430 ->
// +0x18 (vtable board_physics_vtable); the skeleton's: the rig (core+0x438) -> +0x2f10 (vtable
// rig_physics_vtable). Each keeps its bodies at +0x20: their count (uint32) at the start, body n at
// n * 0x130, each pointing back to its owner at +0x10 with its velocity (float[3], m/s) at +0x70 and
// its spin (angular velocity, float[3], radians per second) at +0x90. 0x140fc06b0 syncs a body with
// the physics world: by its pending flags (+0x60) it sets the velocity (8, 0x1425da600) from +0x70
// and the spin (0x20, 0x1425d8530) from +0x90. Flag 1 sets rotation and position from the world matrix
// at +0x20 (0x1425dcbf0); flag 4 sets the position from +0x50, keeping the rotation the physics has
// (0x1425dc000). Read in the disassembly, 2026-11-06.
// The board has 9, body 0 its root; the skeleton 26, body n the ragdoll's body n (skater_body.h).
// core + core_steps_since_built (uint32) counts the core's physics steps from its last build, at a spawn
// or a teleport: one a step in every run compared on 2026-11-06. The core keeps its address across a
// teleport, so the address does not show one.
inline constexpr std::uintptr_t core_steps_since_built = 0x190;
inline constexpr std::uintptr_t body_flags_offset = 0x60;
inline constexpr std::uint32_t body_flag_rotation = 1, body_flag_position = 4, body_flag_velocity = 8, body_flag_spin = 0x20;
// A flight on the board (no_bail.cpp, 2.7): the air state (core+0x308, its launch block at +0x30, the core's at core+0x3e8)
// counts its frames at +0x4dc, one a step (0x48256b0), and reads the block's path at t = frame * dt (0x474ea20). The block's
// dt (+0x18b4) is set when the skater is built (0x4753f94), so it does not follow a step changed since.
inline constexpr std::uintptr_t core_jump_block_offset = 0x3e8;
inline constexpr std::uintptr_t core_air_state_offset = 0x308;
inline constexpr std::uintptr_t air_state_block_offset = 0x30;
inline constexpr std::uintptr_t air_state_frame_offset = 0x4dc; // int32
inline constexpr std::uintptr_t jump_block_dt_offset = 0x18b4;  // float, seconds
// The block's current jump request (+0x1100, 0x4750ea0) has a frame time of its own, read at frame * dt by the air state
// for its velocity and placing (0x4818ec5, 0x481e8cb, 0x4824981), and the flight's length in frames: every step the
// air state takes frame / frames as how far along it is (0x4825831).
inline constexpr std::uintptr_t jump_block_request_offset = 0x1100;
inline constexpr std::uintptr_t request_frames_offset = 0x80;  // int32
inline constexpr std::uintptr_t request_dt_offset = 0xe4;      // float, seconds
inline constexpr std::uintptr_t board_holder_offset = 0x430;  // core
inline constexpr std::uintptr_t board_physics_offset = 0x18;  // board holder
inline constexpr std::uintptr_t rig_physics_offset = 0x2f10;  // rig
inline constexpr std::uintptr_t physics_bodies_offset = 0x20; // board or rig physics
inline constexpr std::uintptr_t physics_body_size = 0x130;
inline constexpr std::uintptr_t body_owner_offset = 0x10;
inline constexpr std::uintptr_t body_velocity_offset = 0x70;
inline constexpr std::uintptr_t body_spin_offset = 0x90;
inline constexpr std::uint32_t board_body_count = 9, rig_body_count = 26;
inline constexpr std::size_t board_root_body = 0;
inline constexpr std::uintptr_t board_physics_vtable = client_source_spawn::board_physics_vtable;
inline constexpr std::uintptr_t rig_physics_vtable = client_source_spawn::rig_physics_vtable;
}
