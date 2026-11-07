#include "virtual_time.h"
#include "Engine/Core/Hooks/hooks.h"
#include "Engine/Core/Log/logging.h"
#include <Windows.h>
#include <atomic>
#include <mutex>

namespace dingosdk::virtual_time {
namespace {
using QueryCounter = BOOLEAN(NTAPI*)(LARGE_INTEGER*);

struct Clock {
    QueryCounter real{};
    std::atomic<bool> on{};
    std::atomic<std::int64_t> now{};          // what is read while on
    std::atomic<std::int64_t> offset{};       // real minus what is read, while off
    std::atomic<std::int64_t> last_advance{}; // the real clock when `now` last moved
    std::atomic<std::uint64_t> reads{};
    std::int64_t step{}, frequency{}, stall{};
    bool hooked{};
    std::mutex mutex;
};
Clock& clock() {
    static auto* value = new Clock;
    return *value;
}
std::int64_t read_real() noexcept {
    LARGE_INTEGER value{};
    clock().real(&value);
    return value.QuadPart;
}
// Any thread, as often as the game likes: no locks.
BOOLEAN NTAPI counter_hook(LARGE_INTEGER* out) {
    auto& c = clock();
    const auto result = c.real(out);
    if (!result || !out) return result;
    c.reads.fetch_add(1, std::memory_order_relaxed);
    const auto real = out->QuadPart;
    if (!c.on.load(std::memory_order_acquire)) {
        out->QuadPart = real - c.offset.load(std::memory_order_relaxed);
        return result;
    }
    // No step for a while: a load or a pause. One thread at a time moves time on, by whole steps.
    auto last = c.last_advance.load(std::memory_order_relaxed);
    if (real - last > c.stall && c.last_advance.compare_exchange_strong(last, real, std::memory_order_acq_rel))
        c.now.fetch_add(c.step, std::memory_order_acq_rel);
    out->QuadPart = c.now.load(std::memory_order_acquire);
    return result;
}
bool install() noexcept {
    auto& c = clock();
    if (c.hooked) return true;
    LARGE_INTEGER frequency{};
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) return false;
    const auto ntdll = GetModuleHandleW(L"ntdll.dll");
    const auto target = ntdll ? reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlQueryPerformanceCounter")) : nullptr;
    if (!target) return false;
    c.frequency = frequency.QuadPart;
    c.step = ticks_per_step(frequency.QuadPart);
    c.stall = frequency.QuadPart / 10; // a tenth of a second with no step
    void* original{};
    {
        HookBatch batch;
        if (hook_prepare(target, reinterpret_cast<void*>(&counter_hook), &original) != HookOk) return false;
        c.real = reinterpret_cast<QueryCounter>(original);
        if (hook_enable(target) != HookOk) return false;
    }
    c.hooked = true;
    logging::write(logging::Level::info, logging::Channel::skater, "Virtual time: the performance counter is hooked.");
    return true;
}
}

bool set(bool on) noexcept {
    auto& c = clock();
    try {
        std::lock_guard lock(c.mutex);
        if (!install()) return false;
        if (on == c.on.load(std::memory_order_acquire)) return true;
        const auto real = read_real();
        if (on) {
            c.now.store(real - c.offset.load(std::memory_order_relaxed), std::memory_order_release);
            c.last_advance.store(real, std::memory_order_release);
        } else {
            c.offset.store(real - c.now.load(std::memory_order_acquire), std::memory_order_release);
        }
        c.on.store(on, std::memory_order_release);
        return true;
    } catch (...) {
        return false;
    }
}

bool active() noexcept { return clock().on.load(std::memory_order_acquire); }

void on_step() noexcept {
    auto& c = clock();
    if (!c.on.load(std::memory_order_acquire)) return;
    c.now.fetch_add(c.step, std::memory_order_acq_rel);
    // Held to real time, in the odd case the game is running ahead of it. Never for long.
    const auto last = c.last_advance.load(std::memory_order_acquire);
    const auto due = last + c.step;
    auto real = read_real();
    const auto give_up = real + c.step * 2;
    while (real < due && real < give_up) {
        if (due - real > c.frequency / 500) Sleep(1);
        else YieldProcessor();
        real = read_real();
    }
    c.last_advance.store(real, std::memory_order_release);
}

std::uint64_t reads() noexcept { return clock().reads.load(std::memory_order_relaxed); }
}
