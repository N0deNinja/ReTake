#pragma once
#include "xray_skeleton.h"
#include <array>
#include <cstdint>
#include <memory>
#include <string_view>
#include <vector>

// The local skater's x-ray, for plugins (reskate.skater.xray, the draw handler's d:skeleton): skate.'s
// own skeleton mesh (xray_skeleton.h) posed by the renderer's skinning matrices as it drew the skater
// (xray_render.h), seen by the camera of that same picture. The overlay draws it, each body in the
// colour a plugin gives it (Extension/UI/Overlay/xray_overlay.cpp).
//
// The renderer's two hooks go on at the first tick and stay on (putting them on or off holds the game's threads
// for a moment, a hitch); idle they pass each call straight on, and the picture is read only while one draws it.
namespace dingosdk::xray {
// Requires the validated build: prepares the renderer's hooks, which patches nothing.
bool start(std::uintptr_t image_base) noexcept;
bool available() noexcept;
// Client thread: a plugin wants the x-ray ready (true) or no longer (false). The mesh is read in the
// background the first time.
void prepare(std::string_view owner, bool on);
// Client thread, every tick: the hooks on from the first (and kept on); the picture read while it was
// drawn lately, the camera kept while the overlay asks for it.
void tick() noexcept;

// The skeleton as the renderer last drew the skater, in world space, with that picture's camera.
struct Pose {
    std::array<float, 16> camera{}; // world matrix: right, up, back, position rows
    float vertical_fov{};           // degrees
    std::vector<game::Vec3> positions, normals; // one per vertex
    std::shared_ptr<const SkeletonMesh> mesh;   // its triangles, and each vertex's body
};
// Render thread, as a plugin draws it: false while there is no picture of the skater.
bool latest(Pose& pose);
// Client thread: the local skater not drawn on this screen while any plugin asks (reskate.skater.hide),
// through the same renderer hook. False when the renderer's hooks are unavailable.
bool hide(std::string_view owner, bool on);
// Render thread: the camera the renderer drew the last frame's main view with (world matrix: right,
// up, back, position rows; degrees), for drawing over the world exactly where the frame has it; false
// until there is one. Asking keeps the renderer's view hook on for a second (the next ticks).
bool camera(std::array<float, 16>& world, float& vertical_fov) noexcept;
// Client thread: a ghost line's skater entity, as it is shown (0: none).
void set_ghost(std::uintptr_t entity) noexcept;
// Render thread: the middle of that skater's head as the renderer drew it this frame, so a name over it
// moves with the model, not a tick off it; false until there is a picture. Asking keeps it followed
// for a second.
bool ghost_head(std::array<float, 3>& head) noexcept;
}
