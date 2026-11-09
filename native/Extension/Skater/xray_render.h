#pragma once
#include "Engine/Game/Abi/linear_transform.h"
#include <array>
#include <cstdint>
#include <vector>

// The local skater as the renderer draws it (Engine/Game/Build/20260929/skater_render.h): the
// skinning matrices its mesh was drawn with and the camera of the same picture, so the x-ray's
// skeleton (xray.h) lies exactly where the game draws the skater. Two hooks that only observe: the skinned
// draw packets, and the main view's camera.
namespace dingosdk::xray {
// Requires the validated build: verifies the layout and prepares both hooks, which patches nothing.
bool start_render(std::uintptr_t image_base) noexcept;
// Client tick: both hooks on or off. Each change holds the game's threads for a moment (a hitch), so
// xray.cpp puts them on once and leaves them. False when they could not be changed (logged; both stay as they were).
bool hook_render(bool on) noexcept;
// Client tick: while `wanted` (a plugin draws the x-ray), which render objects are the local skater's
// (no_bail.h no_bail_skater), riding and walking; otherwise both hooks pass every call straight on.
void follow_render(bool wanted) noexcept;

struct Picture {
    std::vector<game::LinearTransform> skin; // each render bone's skinning matrix: from model space into the world
    std::array<float, 16> camera{};          // the camera's world matrix: right, up, back, position rows
    float vertical_fov{};                    // degrees
};
// Render thread: the latest picture's, while the renderer draws the local skater.
bool latest_picture(Picture& picture) noexcept;
// Client tick: while true (and the hooks are on), the main view's camera is kept even with no x-ray,
// for drawing over the world where the frame puts it (render_camera).
void follow_camera(bool wanted) noexcept;
// Render thread: the camera the renderer last drew the main view with (right, up, back, position
// rows; degrees), while it is fresh.
bool render_camera(std::array<float, 16>& camera, float& vertical_fov) noexcept;
// Client tick: a ghost line's skater entity (0: none) whose draw packets are kept too, as the local
// skater's are; render thread: its skinning matrices as last drawn, while fresh.
void follow_ghost(std::uintptr_t entity) noexcept;
bool latest_ghost_skin(std::vector<game::LinearTransform>& skin) noexcept;
// Client tick: while true (and followed, follow_render), the local skater's draw packets go out
// not visible, so this screen does not draw it; while hidden there is no picture.
void hide_skater(bool hidden) noexcept;
}
