#pragma once
#include "Engine/Game/Input/pad_output.h"
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

// A line saved to a file, to load again after the game has been closed (reskate.tas.line_export and line_import):
// the controller as recorded, a value a step, and the skater's motion at every step, which a going back puts back
// step by step. The bytes are as this build keeps them in memory: a file only loads into the build that wrote it,
// the sizes in the header saying so. The file is the header, then the payload, compressed (the runtime's).
namespace dingosdk::line_file {
inline constexpr char magic[4] = {'R', 'T', 'K', 'L'};
// 1: the header, then the payload. 2: the header, a u32 note size and the note (what ReTake keeps of the line, its
// name and where it starts, as text), then the payload: one file is a whole line, to send to someone.
inline constexpr std::uint32_t version = 2;
inline constexpr std::uint32_t most_note = 1u << 20;

#pragma pack(push, 1)
struct Header {
    char magic[4];
    std::uint32_t version;
    std::uint32_t pad_size;      // sizeof(PadOutput) when written
    std::uint32_t snapshot_size; // sizeof the motion snapshot when written
    std::uint32_t inputs;        // steps of controller
    std::uint32_t frames;        // steps of motion
    std::uint64_t raw_size;      // the payload, uncompressed
    std::uint64_t packed_size;   // the payload as it follows the header
};
#pragma pack(pop)

// The payload: the inputs, then the frames, byte for byte.
template <class Snapshot> std::string pack(const std::vector<input::PadOutput>& inputs, const std::vector<Snapshot>& frames) {
    static_assert(std::is_trivially_copyable_v<Snapshot>);
    std::string raw(inputs.size() * sizeof(input::PadOutput) + frames.size() * sizeof(Snapshot), '\0');
    if (!inputs.empty()) std::memcpy(raw.data(), inputs.data(), inputs.size() * sizeof(input::PadOutput));
    if (!frames.empty()) std::memcpy(raw.data() + inputs.size() * sizeof(input::PadOutput), frames.data(), frames.size() * sizeof(Snapshot));
    return raw;
}

template <class Snapshot> Header header_for(std::size_t inputs, std::size_t frames, std::size_t raw_size, std::size_t packed_size) {
    Header h{};
    std::memcpy(h.magic, magic, sizeof(magic));
    h.version = version;
    h.pad_size = sizeof(input::PadOutput);
    h.snapshot_size = sizeof(Snapshot);
    h.inputs = static_cast<std::uint32_t>(inputs);
    h.frames = static_cast<std::uint32_t>(frames);
    h.raw_size = raw_size;
    h.packed_size = packed_size;
    return h;
}

// Where the payload starts: after the header, and in version 2 the note.
inline std::size_t payload_at(const Header& h, std::uint32_t note_size) {
    return sizeof(Header) + (h.version >= 2 ? sizeof(std::uint32_t) + note_size : 0);
}

// Empty when the header is one this build can load, else why not. `note_size` is the note's, read after the header
// (version 2), else 0.
template <class Snapshot> std::string check(const Header& h, std::size_t file_size, std::size_t most_steps, std::uint32_t note_size = 0) {
    if (std::memcmp(h.magic, magic, sizeof(magic)) != 0) return "it is not a ReTake line";
    if (h.version != 1 && h.version != 2) return "it was saved by another version of ReTake";
    if (note_size > most_note) return "its note is too long";
    if (h.pad_size != sizeof(input::PadOutput) || h.snapshot_size != sizeof(Snapshot)) return "it was saved by another build of ReTake's ReSkate.dll";
    if (h.inputs == 0 || h.inputs > most_steps || h.frames > most_steps) return "its length is not a line's";
    const auto raw = static_cast<std::uint64_t>(h.inputs) * sizeof(input::PadOutput) + static_cast<std::uint64_t>(h.frames) * sizeof(Snapshot);
    if (h.raw_size != raw) return "its sizes do not add up";
    if (file_size < payload_at(h, note_size) || h.packed_size != file_size - payload_at(h, note_size)) return "the file is cut short";
    return {};
}

// The payload back. False when it is not the size the header says.
template <class Snapshot> bool unpack(std::string_view raw, const Header& h, std::vector<input::PadOutput>& inputs, std::vector<Snapshot>& frames) {
    static_assert(std::is_trivially_copyable_v<Snapshot>);
    if (raw.size() != h.raw_size) return false;
    inputs.resize(h.inputs);
    frames.resize(h.frames);
    std::memcpy(inputs.data(), raw.data(), inputs.size() * sizeof(input::PadOutput));
    if (!frames.empty()) std::memcpy(frames.data(), raw.data() + inputs.size() * sizeof(input::PadOutput), frames.size() * sizeof(Snapshot));
    return true;
}
}
