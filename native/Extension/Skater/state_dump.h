#pragma once
#include "Extension/Skater/no_bail.h"
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>

// Research: the local skater's raw memory at chosen physics steps of a run, saved to a file for
// comparing runs. It finds what a restore must also put back for a run to repeat exactly. It only reads.
//
// The file is the magic "TASD", then records: u32 step, u32 block id, u64 address, u32 size, the bytes.
// Bytes that could not be read are left as 0xCD. Blocks are ids into state_dump::block_names.
namespace dingosdk::state_dump {
inline constexpr std::size_t max_bytes = 64u << 20;
// Client thread: the next run's steps are taken: the first few, then every `every` steps.
void arm(std::uint32_t every);
// Physics thread, in a step (a no_bail step listener): `step` counts from the run's start.
void on_step(const NoBailSkater& skater, std::size_t step) noexcept;
// Client thread: ends the taking and writes what was taken. Empty when it worked, else why not.
std::string save(const std::filesystem::path& file);
// Research: everything the local skater reaches, at once, for finding what its build works out from its step
// length (a skater built in slow motion against one built at full speed). Its own blocks and the known ones
// whole, every block one pointer away in part and two away in less, each named by the way to it from the
// skater ("core+3e8+1100", offsets in hex), so dumps of skaters built apart line up by name. The bytes are
// "RTKG", then records: u16 name length, the name, u64 address, u32 size, the bytes (0xCD where unreadable).
// At most `most` bytes. Client thread; it only reads, and what moves meanwhile is noise to compare away.
std::string graph(const NoBailSkater& skater, std::size_t most);
// Whether `step` of a run is one taken, by the rule arm() describes.
constexpr bool wanted(std::size_t step, std::uint32_t every) noexcept {
    return step <= 5 || (every != 0 && step % every == 0);
}
}
