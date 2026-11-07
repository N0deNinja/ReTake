#pragma once
#include "Extension/Skater/no_bail.h"
#include <cstddef>
#include <string>

// What skate. works out from a skater's physics step length when it builds the skater, kept up with a step changed
// since. The game gives a skater its step when it builds it (at a spawn and at every teleport) and works out more
// from it then: copies of the step in the board's and the skeleton's physics and in each of the skeleton's joints,
// and limits of so many metres a step. Slow motion changes the step of a skater already built (game_speed.h), and
// with only the step changed all of those stay as they were for the step it was built with: in play the board
// slid sideways and lost speed, and the body went stiff, the more so the slower.
//
// Found by building the skater at full speed, at 0.05 and at 0.25 and comparing all of its memory
// (state_dump::graph, ReTake's `retake skatertest`, 2026-11-07, two runs): the values the same in every build at
// one speed, different between speeds, and in proportion to the step at all three. Each is written only when it
// holds what a build at the old step would have given it, so a value that is something else by then (another
// layout, a body the game rebuilt meanwhile) is left alone.
namespace dingosdk::step_fields {
struct Outcome {
    std::size_t changed{}; // values written for the new step
    std::size_t already{}; // values the game had already changed with the step itself
    std::size_t other{};   // values not as a build at the old step leaves them: left alone
    std::size_t missing{}; // values that could not be reached
    std::string written;   // the names of those written, for the log
};
// Game update thread, as the skater's step changes from `from` to `to` seconds.
Outcome follow(const NoBailSkater& skater, float from, float to) noexcept;
}
