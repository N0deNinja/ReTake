#include "state_dump.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/skater_body.h"
#include "Engine/Game/Build/20260929/skater_movement.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include <array>
#include <atomic>
#include <cstring>
#include <deque>
#include <format>
#include <fstream>
#include <mutex>
#include <thread>
#include <unordered_set>
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

std::string graph(const NoBailSkater& skater, std::size_t most) {
    std::vector<unsigned char> out;
    out.reserve(most);
    const char magic[4] = {'R', 'T', 'K', 'G'};
    out.insert(out.end(), magic, magic + 4);
    // Pointers into the game's image are its code and tables, the same in every dump: not followed.
    const auto image = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
    std::uintptr_t image_end = image;
    IMAGE_DOS_HEADER dos{};
    IMAGE_NT_HEADERS64 headers{};
    if (memory::read(image, dos) && memory::read(image + static_cast<std::uintptr_t>(dos.e_lfanew), headers))
        image_end = image + headers.OptionalHeader.SizeOfImage;
    struct Block {
        std::string name;
        std::uintptr_t address{};
        std::uint32_t size{};
        int depth{};
    };
    std::deque<Block> queue;
    queue.push_back({"context", skater.context, 0x2000, 0});
    queue.push_back({"core", skater.core, 0x4200, 0});
    queue.push_back({"rig", skater.rig, 0x4700, 0});
    queue.push_back({"entity", skater.entity, 0x800, 0});
    queue.push_back({"base", skater.base, 0x800, 0});
    // Known to hold what a build sets from the step (skater_state.h: the jump block's dt), whole.
    const auto jump = pointer_at(skater.core + state::core_jump_block_offset);
    queue.push_back({"core+3e8", jump, 0x2000, 1});
    queue.push_back({"core+3e8+1100", pointer_at(jump + state::jump_block_request_offset), 0x200, 2});
    queue.push_back({"core+308", pointer_at(skater.core + state::core_air_state_offset), 0x800, 1});
    queue.push_back({"core+3c8", pointer_at(skater.core + body::core_step_input_offset), 0x200, 1});
    std::unordered_set<std::uintptr_t> seen;
    while (!queue.empty() && out.size() < most) {
        auto block = std::move(queue.front());
        queue.pop_front();
        if (block.address < 0x10000 || !seen.insert(block.address).second) continue;
        unsigned char probe[16];
        if (!memory::read_bytes(block.address, probe, sizeof(probe))) continue;
        const auto need = 2 + block.name.size() + 8 + 4 + block.size;
        if (out.size() + need > most) continue;
        append(out, static_cast<std::uint16_t>(block.name.size()));
        out.insert(out.end(), block.name.begin(), block.name.end());
        append(out, static_cast<std::uint64_t>(block.address));
        append(out, block.size);
        const auto at = out.size();
        out.resize(at + block.size, 0xCD);
        for (std::size_t done = 0; done < block.size; done += chunk) {
            const auto length = std::min<std::size_t>(chunk, block.size - done);
            (void)memory::read_bytes(block.address + done, out.data() + at + done, length);
        }
        if (block.depth >= 2) continue;
        for (std::uint32_t offset = 0; offset + 8 <= block.size; offset += 8) {
            std::uint64_t value{};
            std::memcpy(&value, out.data() + at + offset, sizeof(value));
            if (value < 0x10000 || value > memory::highest_user_address || (value & 7) != 0) continue;
            if ((value >= image && value < image_end) || (value >= block.address && value < block.address + block.size)) continue;
            if (seen.contains(value)) continue;
            queue.push_back({std::format("{}+{:x}", block.name, offset), static_cast<std::uintptr_t>(value), block.depth == 0 ? 0x1000u : 0x400u,
                             block.depth + 1});
        }
    }
    return std::string(reinterpret_cast<const char*>(out.data()), out.size());
}

std::string save(const std::filesystem::path& file) {
    auto& d = dump();
    d.armed.store(false, std::memory_order_release);
    // What was taken, out of the way at once (the next arm may come straight after); written on a thread of its own:
    // up to 64 MB is far past a plugin call's 50 ms.
    std::vector<unsigned char> bytes;
    {
        std::lock_guard lock(d.mutex);
        if (d.bytes.size() <= 4) return "nothing was taken";
        bytes.swap(d.bytes);
    }
    std::thread([bytes = std::move(bytes), file] {
        std::error_code error;
        std::filesystem::create_directories(file.parent_path(), error);
        std::ofstream stream(file, std::ios::binary | std::ios::trunc);
        stream.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    }).detach();
    return {};
}
}
