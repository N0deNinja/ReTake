#pragma once
#include "native_skater.h"
namespace dingosdk::multiplayer {
std::optional<Appearance> capture_cosmetics(std::uintptr_t base, const NativeFrame &, std::string &detail);
// Only called for the owned remote actor on the verified client update thread. `dress_gaps` (a
// ghost line's skater): an item not installed here that leaves a slot empty puts the default
// outfit on the empty slots it fits (CosmeticMemory::dress_gaps).
void apply_cosmetic_recipe(std::uintptr_t base, std::uintptr_t entity, std::uintptr_t local_entity,
                           const CosmeticRecipe &, bool dress_gaps = false);
} // namespace dingosdk::multiplayer
