#include "xray.h"
#include "xray_render.h"
#include <Windows.h>
#include <atomic>
#include <cmath>
#include <mutex>
#include <set>
#include <string>

namespace dingosdk::xray {
namespace {
// The picture is followed this long after the last frame that drew the x-ray.
constexpr std::uint64_t follow_ms = 1000;
struct State {
    std::atomic<bool> ready{};
    std::mutex mutex;
    std::set<std::string, std::less<>> owners; // client thread
    std::set<std::string, std::less<>> hiders; // client thread: plugins hiding the local skater
    bool hooked{}, hook_tried{};               // client thread
    std::atomic<std::uint64_t> drawn_at{};     // render thread -> client tick
    std::atomic<std::uint64_t> camera_at{};    // render thread -> client tick: the overlay asked for the camera
    std::atomic<std::uintptr_t> ghost_entity{}; // a ghost line's skater (set_ghost)
    std::atomic<std::uint64_t> ghost_at{};      // render thread -> client tick: the overlay asked for its head
};
State& state() {
    static auto* value = new State; // the renderer's hooks may call in until exit
    return *value;
}
}

bool start(std::uintptr_t base) noexcept {
    auto& s = state();
    if (s.ready.load(std::memory_order_acquire)) return true;
    if (!start_render(base)) return false; // logged
    s.ready.store(true, std::memory_order_release);
    return true;
}
bool available() noexcept { return state().ready.load(std::memory_order_acquire); }

void prepare(std::string_view owner, bool on) {
    auto& s = state();
    std::lock_guard lock(s.mutex);
    if (on) {
        s.owners.emplace(owner);
        prepare_skeleton(); // once, in the background
    } else if (const auto found = s.owners.find(owner); found != s.owners.end()) {
        s.owners.erase(found);
    }
}
bool hide(std::string_view owner, bool on) {
    auto& s = state();
    std::lock_guard lock(s.mutex);
    if (!on) {
        if (const auto found = s.hiders.find(owner); found != s.hiders.end()) s.hiders.erase(found);
        return true;
    }
    if (!s.ready.load(std::memory_order_acquire)) return false;
    s.hiders.emplace(owner);
    return true;
}

void tick() noexcept {
    auto& s = state();
    if (!s.ready.load(std::memory_order_acquire)) return;
    try {
        bool xray{}, hiding{};
        {
            std::lock_guard lock(s.mutex);
            xray = !s.owners.empty();
            hiding = !s.hiders.empty();
        }
        const auto now = GetTickCount64();
        const bool drawn = now - s.drawn_at.load(std::memory_order_acquire) < follow_ms;
        const bool camera = now - s.camera_at.load(std::memory_order_acquire) < follow_ms;
        follow_render((xray && drawn) || hiding);
        follow_camera(camera);
        const bool ghost = now - s.ghost_at.load(std::memory_order_acquire) < follow_ms;
        follow_ghost(ghost ? s.ghost_entity.load(std::memory_order_acquire) : 0);
        hide_skater(hiding);
        // Putting the renderer's hooks on or off patches its code, which holds every thread of the game for a moment:
        // a hitch the player sees. They went on and off with the x-ray and with labels over the world, and the game
        // hitched as a label came and went. So they go on once, at the first tick (the game still loading in), and
        // stay on: idle, each passes the call straight on (follow_render, follow_camera).
        const bool wanted = xray || hiding || camera;
        if (!s.hooked && (wanted || !s.hook_tried)) {
            s.hook_tried = true;
            s.hooked = hook_render(true);
        }
    } catch (...) {
    }
}

bool camera(std::array<float, 16>& world, float& vertical_fov) noexcept {
    auto& s = state();
    if (!s.ready.load(std::memory_order_acquire)) return false;
    s.camera_at.store(GetTickCount64(), std::memory_order_release);
    return render_camera(world, vertical_fov);
}

void set_ghost(std::uintptr_t entity) noexcept {
    auto& s = state();
    if (!s.ready.load(std::memory_order_acquire)) return;
    if (s.ghost_entity.exchange(entity, std::memory_order_acq_rel) != entity && entity) prepare_skeleton(); // once, in the background
}

bool ghost_head(std::array<float, 3>& head) noexcept {
    auto& s = state();
    if (!s.ready.load(std::memory_order_acquire) || !s.ghost_entity.load(std::memory_order_acquire)) return false;
    s.ghost_at.store(GetTickCount64(), std::memory_order_release);
    static std::vector<LinearTransform> skin; // render thread only: reused frame to frame
    const auto mesh = skeleton_mesh();
    if (!mesh || !latest_ghost_skin(skin) || skin.size() < mesh->bone_count) return false;
    // The middle of the head's vertices, posed as the renderer drew them.
    constexpr std::uint8_t head_part = 1; // skater_body::names: "Head"
    std::array<double, 3> sum{};
    std::size_t count{};
    for (std::size_t i = 0; i < mesh->vertices.size() && i < mesh->parts.size(); ++i) {
        if (mesh->parts[i] != head_part) continue;
        const auto& vertex = mesh->vertices[i];
        for (std::size_t slot = 0; slot < max_influences && vertex.weights[slot] > 0; ++slot) {
            if (vertex.bones[slot] >= skin.size()) return false;
            const auto p = game::place(vertex.position, skin[vertex.bones[slot]]);
            for (std::size_t axis = 0; axis < 3; ++axis) sum[axis] += static_cast<double>(p[axis]) * vertex.weights[slot];
        }
        ++count;
    }
    if (!count) return false;
    for (std::size_t axis = 0; axis < 3; ++axis) head[axis] = static_cast<float>(sum[axis] / static_cast<double>(count));
    return std::isfinite(head[0]) && std::isfinite(head[1]) && std::isfinite(head[2]);
}

bool latest(Pose& pose) {
    auto& s = state();
    if (!s.ready.load(std::memory_order_acquire)) return false;
    s.drawn_at.store(GetTickCount64(), std::memory_order_release);
    auto mesh = skeleton_mesh();
    Picture picture;
    PosedSkeleton posed;
    if (!mesh || !latest_picture(picture) || !pose_skeleton(*mesh, picture.skin, posed)) return false;
    pose.camera = picture.camera;
    pose.vertical_fov = picture.vertical_fov;
    pose.positions = std::move(posed.positions);
    pose.normals = std::move(posed.normals);
    pose.mesh = std::move(mesh);
    return true;
}
}
