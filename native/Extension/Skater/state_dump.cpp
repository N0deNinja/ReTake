#include "state_dump.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/skater_body.h"
#include "Engine/Game/Build/20260929/skater_movement.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include <array>
#include <atomic>
#include <cstring>
#include <fstream>
#include <mutex>
#include <vector>

namespace dingosdk::state_dump {
namespace {
namespace body = addr::skater_body;
namespace state = addr::skater_state;
namespace movement = addr::skater_movement;

constexpr std::size_t chunk = 0x100;

struct Dump {
    std::mutex mutex;
    std::vector<unsigned char> bytes;
    std::atomic<bool> armed{};
    std::uint32_t every{};
};
Dump& dump() {
    static auto* value = new Dump;
    return *value;
}
template <class T> void append(std::vector<unsigned char>& out, const T& value) {
    const auto* raw = reinterpret_cast<const unsigned char*>(&value);
    out.insert(out.end(), raw, raw + sizeof(T));
}
// Unreadable chunks stay 0xCD: a block's size is a generous guess at the object's, and may run past it.
void add_block(std::vector<unsigned char>& out, std::uint32_t step, std::uint32_t id, std::uintptr_t address, std::uint32_t size) {
    if (address < 0x10000) return;
    append(out, step);
    append(out, id);
    append(out, static_cast<std::uint64_t>(address));
    append(out, size);
    const auto at = out.size();
    out.resize(at + size, 0xCD);
    for (std::size_t done = 0; done < size; done += chunk) {
        const auto length = std::min<std::size_t>(chunk, size - done);
        (void)memory::peek_bytes(address + done, out.data() + at + done, length);
    }
}
std::uintptr_t pointer_at(std::uintptr_t address) noexcept {
    std::uintptr_t value{};
    return memory::peek(address, value) ? value : 0;
}
}

void arm(std::uint32_t every) {
    auto& d = dump();
    std::lock_guard lock(d.mutex);
    d.bytes.clear();
    d.bytes.reserve(16u << 20);
    const char magic[4] = {'T', 'A', 'S', 'D'};
    d.bytes.insert(d.bytes.end(), magic, magic + 4);
    d.every = every;
    d.armed.store(true, std::memory_order_release);
}

void on_step(const NoBailSkater& skater, std::size_t step) noexcept {
    auto& d = dump();
    if (!d.armed.load(std::memory_order_acquire)) return;
    try {
        std::lock_guard lock(d.mutex);
        if (!wanted(step, d.every) || d.bytes.size() >= max_bytes) return;
        auto& out = d.bytes;
        const auto number = static_cast<std::uint32_t>(step);
        // The ids stay as they are: the comparing script names them.
        add_block(out, number, 0, skater.context, 0x2000);
        add_block(out, number, 1, skater.core, 0x4200);
        add_block(out, number, 2, skater.rig, 0x4700);
        add_block(out, number, 3, pointer_at(skater.core + state::trick_state_offset), 0x800);
        add_block(out, number, 4, pointer_at(skater.core + movement::skater_parent), 0x400);
        const auto board_holder = pointer_at(skater.core + state::board_holder_offset);
        add_block(out, number, 5, board_holder, 0x400);
        const auto board_physics = pointer_at(board_holder + state::board_physics_offset);
        add_block(out, number, 6, board_physics, 0x100);
        add_block(out, number, 7, pointer_at(board_physics + state::physics_bodies_offset),
            state::board_body_count * static_cast<std::uint32_t>(state::physics_body_size) + 0x20);
        const auto rig_physics = pointer_at(skater.rig + state::rig_physics_offset);
        add_block(out, number, 8, rig_physics, 0x2000);
        add_block(out, number, 9, pointer_at(rig_physics + state::physics_bodies_offset),
            state::rig_body_count * static_cast<std::uint32_t>(state::physics_body_size) + 0x20);
        add_block(out, number, 10, pointer_at(rig_physics + body::contact_struct_offset), 0x2000);
        add_block(out, number, 11, pointer_at(skater.core + body::core_step_input_offset), 0x100);
        add_block(out, number, 12, skater.entity, 0x800);
    } catch (...) {
    }
}

std::string save(const std::filesystem::path& file) {
    auto& d = dump();
    d.armed.store(false, std::memory_order_release);
    std::lock_guard lock(d.mutex);
    if (d.bytes.size() <= 4) return "nothing was taken";
    std::error_code error;
    std::filesystem::create_directories(file.parent_path(), error);
    if (error) return "the folder could not be made: " + error.message();
    std::ofstream stream(file, std::ios::binary | std::ios::trunc);
    stream.write(reinterpret_cast<const char*>(d.bytes.data()), static_cast<std::streamsize>(d.bytes.size()));
    d.bytes.clear();
    return stream.good() ? std::string{} : std::string("the file could not be written");
}
}
