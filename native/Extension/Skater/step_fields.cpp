#include "step_fields.h"
#include "Engine/Core/Platform/memory.h"
#include <Windows.h>
#include <array>
#include <cmath>
#include <cstdint>

namespace dingosdk::step_fields {
namespace {
enum class Root : std::uint8_t { context, core, rig, entity };
// dt: the step times a constant (1, -1, 60, 91, ...). pow2: a power of two below the step, which moves by the
// power of two nearest the change (1/128 at 1/60, 1/2048 at 1/1200, 1/512 at 1/240).
enum class Kind : std::uint8_t { dt, pow2 };
struct Field {
    Root root;
    std::uint8_t hops;                  // offsets, all but the last a pointer to follow
    std::array<std::uint32_t, 3> offset;
    Kind kind;
    float times; // dt: the value over the step, as built
    const char* name; // its way from the skater
};
// From the comparison of builds (the comment beside each is its way from the skater, offsets in hex). The step input's
// own length (core+3c8+20) is game_speed's to write. Left out: values that also depend on where the skater stands, and clocks
// that only looked like it in the comparison, read at the same step count after each build (core+1ac and context+18ac
// are minus the time since the build, core+30b0 to +30c0 and core+3f60+ac count time too: 2026-11-07, a build at full
// speed slowed afterwards had them at its own age, not at 91 steps).
constexpr Field fields[] = {
    {Root::context, 3, {0x14a8, 0x890, 0x1c0}, Kind::dt, 1.0000f, "context+14a8+890+1c0"},
    {Root::context, 3, {0x14a8, 0x890, 0x20}, Kind::dt, 1.0000f, "context+14a8+890+20"},
    {Root::context, 3, {0x14a8, 0x890, 0x360}, Kind::dt, 1.0000f, "context+14a8+890+360"},
    {Root::context, 1, {0x17ec}, Kind::dt, 1.0000f, "context+17ec"},
    {Root::core, 2, {0x3a8, 0xf40}, Kind::dt, 1.0000f, "core+3a8+f40"},
    {Root::core, 3, {0x3b8, 0x18, 0x0}, Kind::dt, 1.0000f, "core+3b8+18+0"},
    {Root::core, 1, {0x3f50}, Kind::dt, 1.0000f, "core+3f50"},
    {Root::core, 3, {0x488, 0x48, 0x1f0}, Kind::dt, 1.0000f, "core+488+48+1f0"},
    {Root::core, 3, {0x488, 0x48, 0x350}, Kind::dt, 1.0000f, "core+488+48+350"},
    {Root::core, 3, {0x488, 0x48, 0x90}, Kind::dt, 1.0000f, "core+488+48+90"},
    {Root::core, 2, {0x490, 0x1b0}, Kind::dt, 1.0000f, "core+490+1b0"},
    {Root::core, 3, {0x608, 0x5b0, 0x88}, Kind::dt, 1.0000f, "core+608+5b0+88"},
    {Root::core, 3, {0x608, 0x5d0, 0x68}, Kind::dt, 1.0000f, "core+608+5d0+68"},
    {Root::core, 3, {0x610, 0x18, 0x64}, Kind::dt, 60.0000f, "core+610+18+64"},
    {Root::core, 3, {0x610, 0x68, 0x104}, Kind::dt, 60.0000f, "core+610+68+104"},
    {Root::core, 1, {0xb70}, Kind::pow2, 0.0078125f, "core+b70"},
    {Root::core, 3, {0xc48, 0x5b0, 0x340}, Kind::dt, 1.0000f, "core+c48+5b0+340"},
    {Root::core, 2, {0xec8, 0xad0}, Kind::dt, 1.0000f, "core+ec8+ad0"},
    {Root::core, 2, {0xec8, 0xb90}, Kind::dt, 1.0000f, "core+ec8+b90"},
    {Root::entity, 2, {0x470, 0x440}, Kind::dt, 1.0000f, "entity+470+440"},
    {Root::entity, 2, {0xf8, 0xbb0}, Kind::dt, 1.0000f, "entity+f8+bb0"},
    {Root::entity, 2, {0xf8, 0xc40}, Kind::dt, 1.0000f, "entity+f8+c40"},
    {Root::entity, 2, {0xf8, 0xd98}, Kind::dt, 1.0000f, "entity+f8+d98"},
    {Root::entity, 2, {0xf8, 0xd9c}, Kind::dt, 1.0000f, "entity+f8+d9c"},
    {Root::rig, 2, {0x2e90, 0xffc}, Kind::dt, 1.0000f, "rig+2e90+ffc"},
    {Root::rig, 2, {0x2e98, 0xfac}, Kind::dt, 1.0000f, "rig+2e98+fac"},
    {Root::rig, 2, {0x2e98, 0xfb0}, Kind::dt, -1.0000f, "rig+2e98+fb0"},
    {Root::rig, 2, {0x2ea0, 0xf5c}, Kind::dt, 1.0000f, "rig+2ea0+f5c"},
    {Root::rig, 2, {0x2ea0, 0xf60}, Kind::dt, -1.0000f, "rig+2ea0+f60"},
    {Root::rig, 2, {0x2ea8, 0xf0c}, Kind::dt, 1.0000f, "rig+2ea8+f0c"},
    {Root::rig, 2, {0x2ea8, 0xf10}, Kind::dt, -1.0000f, "rig+2ea8+f10"},
    {Root::rig, 2, {0x2eb0, 0xebc}, Kind::dt, 1.0000f, "rig+2eb0+ebc"},
    {Root::rig, 2, {0x2eb0, 0xec0}, Kind::dt, -1.0000f, "rig+2eb0+ec0"},
    {Root::rig, 2, {0x2eb8, 0xe6c}, Kind::dt, 1.0000f, "rig+2eb8+e6c"},
    {Root::rig, 2, {0x2eb8, 0xe70}, Kind::dt, -1.0000f, "rig+2eb8+e70"},
    {Root::rig, 2, {0x2ec0, 0xe1c}, Kind::dt, 1.0000f, "rig+2ec0+e1c"},
    {Root::rig, 2, {0x2ec0, 0xe20}, Kind::dt, -1.0000f, "rig+2ec0+e20"},
    {Root::rig, 2, {0x2ec8, 0xdcc}, Kind::dt, 1.0000f, "rig+2ec8+dcc"},
    {Root::rig, 2, {0x2ec8, 0xdd0}, Kind::dt, -1.0000f, "rig+2ec8+dd0"},
    {Root::rig, 2, {0x2ed0, 0xd7c}, Kind::dt, 1.0000f, "rig+2ed0+d7c"},
    {Root::rig, 2, {0x2ed0, 0xd80}, Kind::dt, -1.0000f, "rig+2ed0+d80"},
    {Root::rig, 2, {0x2ed8, 0xd2c}, Kind::dt, 1.0000f, "rig+2ed8+d2c"},
    {Root::rig, 2, {0x2ed8, 0xd30}, Kind::dt, -1.0000f, "rig+2ed8+d30"},
    {Root::rig, 2, {0x2ee0, 0xcdc}, Kind::dt, 1.0000f, "rig+2ee0+cdc"},
    {Root::rig, 2, {0x2ee0, 0xce0}, Kind::dt, -1.0000f, "rig+2ee0+ce0"},
    {Root::rig, 2, {0x2ee8, 0xc8c}, Kind::dt, 1.0000f, "rig+2ee8+c8c"},
    {Root::rig, 2, {0x2ee8, 0xc90}, Kind::dt, -1.0000f, "rig+2ee8+c90"},
    {Root::rig, 2, {0x2ef0, 0xc3c}, Kind::dt, 1.0000f, "rig+2ef0+c3c"},
    {Root::rig, 2, {0x2ef0, 0xc40}, Kind::dt, -1.0000f, "rig+2ef0+c40"},
    {Root::rig, 2, {0x2ef8, 0xbec}, Kind::dt, 1.0000f, "rig+2ef8+bec"},
    {Root::rig, 2, {0x2ef8, 0xbf0}, Kind::dt, -1.0000f, "rig+2ef8+bf0"},
    {Root::rig, 1, {0x4624}, Kind::dt, 1.0000f, "rig+4624"},
    {Root::rig, 1, {0x4640}, Kind::dt, 1.0000f, "rig+4640"},
};

bool write(std::uintptr_t address, float value) noexcept {
    __try {
        *reinterpret_cast<volatile float*>(address) = value;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

std::uintptr_t root_of(const NoBailSkater& skater, Root root) noexcept {
    switch (root) {
    case Root::context: return skater.context;
    case Root::core: return skater.core;
    case Root::rig: return skater.rig;
    case Root::entity: return skater.entity;
    }
    return 0;
}

// Where the field is now: its pointers followed. 0 when one of them is not there.
std::uintptr_t address_of(const NoBailSkater& skater, const Field& field) noexcept {
    std::uintptr_t at = root_of(skater, field.root);
    for (std::uint8_t hop = 0; hop + 1 < field.hops; ++hop) {
        std::uintptr_t next{};
        if (!at || !memory::read(at + field.offset[hop], next) || next < 0x10000) return 0;
        at = next;
    }
    return at ? at + field.offset[field.hops - 1] : 0;
}
}

Outcome follow(const NoBailSkater& skater, float from, float to) noexcept {
    Outcome outcome;
    if (!std::isfinite(from) || !std::isfinite(to) || from < 1e-5f || to < 1e-5f || from == to) return outcome;
    const double ratio = static_cast<double>(to) / from;
    const double power_of_two = std::exp2(std::round(std::log2(ratio)));
    for (const auto& field : fields) {
        const auto address = address_of(skater, field);
        float value{};
        if (!address || !memory::read(address, value) || !std::isfinite(value)) {
            ++outcome.missing;
            continue;
        }
        double next{};
        if (field.kind == Kind::dt) {
            // As a build at `from` leaves it, to a thousandth.
            const double built = static_cast<double>(field.times) * from;
            const double wanted = static_cast<double>(field.times) * to;
            if (std::fabs(value - wanted) <= 1e-3 * std::fabs(wanted)) {
                ++outcome.already; // the game keeps this one with the step itself
                continue;
            }
            if (std::fabs(value - built) > 1e-3 * std::fabs(built)) {
                ++outcome.other;
                continue;
            }
            next = static_cast<double>(field.times) * to;
        } else {
            int exponent{};
            const double mantissa = std::frexp(static_cast<double>(value), &exponent);
            if (mantissa != 0.5 || value > from) {
                ++outcome.other;
                continue;
            }
            next = value * power_of_two;
        }
        if (write(address, static_cast<float>(next))) {
            ++outcome.changed;
            try {
                if (!outcome.written.empty()) outcome.written += ", ";
                outcome.written += field.name;
            } catch (...) {
            }
        } else {
            ++outcome.missing;
        }
    }
    return outcome;
}
}
