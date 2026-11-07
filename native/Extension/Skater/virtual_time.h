#pragma once
#include <cstdint>

// Research: the process's performance counter driven by the skater's physics steps. While on, the time
// any thread reads moves only when a physics step runs, by the same amount each step, so what the game
// works out from the clock between steps (a frame's length, for filters and animation) is the same in every
// run. Each step is held back to real time, so the game runs at its usual speed. If no step comes (a load,
// a pause), time creeps on from the real clock, so nothing waiting on it waits for ever.
namespace dingosdk::virtual_time {
// Pure: the counter ticks a step moves time by. A step of the game's fixed 60 a second, rounded up and one
// more, so that a frame's time never falls short of its step.
constexpr std::int64_t ticks_per_step(std::int64_t frequency) noexcept {
    return (frequency + 59) / 60 + 1;
}
// Client thread. The hook goes in at the first use and stays; off, it gives the real clock on from where
// the virtual one reached, so time never runs backwards. False when the hook could not go in.
bool set(bool on) noexcept;
bool active() noexcept;
// Physics thread, once a step.
void on_step() noexcept;
// Reads of the clock answered since the game started, whether on or off: 0 means the hook sees nothing.
std::uint64_t reads() noexcept;
}
