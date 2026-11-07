#pragma once
#include "Extension/Skater/no_bail.h"
#include "Engine/Game/Abi/linear_transform.h"
#include <array>
#include <cstdint>

// The exact motion of the local skater's physics bodies, taken and put back: every body's world matrix,
// velocity and spin, board and skeleton. It does not hold what the game keeps beside the bodies (the
// animation graph, the trick and state machines, contacts), so a restore puts the bodies back and leaves
// those as they are. Physics thread, inside a step (a no_bail step listener): the game's body
// synchronizer applies a restore at the next step.
namespace dingosdk::motion_snapshot {
struct Body {
    std::array<float, 16> transform{};
    game::Vec3 velocity{}, spin{};
};
struct Snapshot {
    std::array<Body, 9> board{};
    std::array<Body, 26> skeleton{};
    bool valid{};
};
// False when a body could not be read or does not hold the layout expected.
bool capture(const NoBailSkater& skater, Snapshot& snapshot) noexcept;
// `skeleton`: the skeleton's bodies too, not only the board's. False when nothing was written.
// A flight's path goes on at the speed of the skater's step: its frame time becomes `step`, and its frame count
// the one that is the same time along the path. Nothing is written while they agree. Physics thread.
void match_flight_step(const NoBailSkater& skater, float step) noexcept;
bool restore(const NoBailSkater& skater, const Snapshot& snapshot, bool skeleton) noexcept;
}
