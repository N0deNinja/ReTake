#pragma once
#include "Extension/Multiplayer/Net/pose_codec.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// A ghost line (reskate.tas.ghost_*): a line as other players see it, to ride beside. Each step of it keeps the skater's
// pose as multiplayer sends it (Extension/Multiplayer/Net/pose_codec.h: every bone, rounded, as the difference from the
// pose before, every 60th whole) and the camera the line was seen through; once, the outfit, as a cosmetics packet. A
// ghost is shown as multiplayer shows another player: a real skater in that outfit, posed step by step. A minute of
// it is about a megabyte.
//
// The file: the header, the note (what ReTake keeps of it: its name, who made it, its map and start, as text), then
// the payload, compressed (the runtime's zstd). Unlike a line file, nothing in it is this build's memory: a ghost
// loads into any build whose poses have the same bones.
namespace dingosdk::ghost_file {
inline constexpr char magic[4] = {'R', 'T', 'K', 'G'};
inline constexpr std::uint32_t version = 1;
inline constexpr std::uint32_t most_note = 1u << 20;
inline constexpr std::size_t whole_every = 60;            // a whole pose this often, to start showing from anywhere
inline constexpr std::size_t most_samples = 60 * 60 * 30; // half an hour of steps
inline constexpr std::uint64_t most_raw = 512ull << 20;

#pragma pack(push, 1)
struct Header {
    char magic[4];
    std::uint32_t version;
    std::uint32_t note_size;
    std::uint64_t raw_size;    // the payload, uncompressed
    std::uint64_t packed_size; // the payload as it follows the note
};
#pragma pack(pop)

struct Camera {
    std::array<float, 3> position{}, forward{0, 0, 1}, up{0, 1, 0};
    float fov{};
    bool operator==(const Camera&) const = default;
};
struct Sample {
    std::uint32_t step{};
    Camera camera;
    std::vector<std::uint8_t> pose; // pose_codec: whole, or the difference from the sample before
    bool operator==(const Sample&) const = default;
};
struct Track {
    std::vector<std::uint8_t> appearance; // a cosmetics packet (multiplayer::encode), empty for none
    std::vector<Sample> samples;          // steps only ever rise
    bool operator==(const Track&) const = default;
};

inline Header header_for(std::size_t note_size, std::size_t raw_size, std::size_t packed_size) {
    Header h{};
    std::memcpy(h.magic, magic, sizeof(magic));
    h.version = version;
    h.note_size = static_cast<std::uint32_t>(note_size);
    h.raw_size = raw_size;
    h.packed_size = packed_size;
    return h;
}
// Empty when the header is one this build reads, else why not.
inline std::string check(const Header& h, std::uint64_t file_size) {
    if (std::memcmp(h.magic, magic, sizeof(magic)) != 0) return "it is not a ghost line";
    if (h.version != version) return "it was made by another version of ReTake";
    if (h.note_size > most_note) return "its note is too long";
    if (h.raw_size == 0 || h.raw_size > most_raw) return "its size is not a ghost line's";
    if (file_size < sizeof(Header) + h.note_size || h.packed_size != file_size - sizeof(Header) - h.note_size) return "the file is cut short";
    return {};
}

// ---- the payload ----------------------------------------------------------------------------------------------
// u32 outfit size, the outfit; u32 samples; each: u32 step, 10 floats of camera, u32 pose size, the pose.
namespace detail {
inline void put(std::string& out, const void* data, std::size_t size) { out.append(static_cast<const char*>(data), size); }
template <class T> void put(std::string& out, T value) { put(out, &value, sizeof(value)); }
struct Reader {
    std::string_view in;
    bool ok = true;
    bool get(void* data, std::size_t size) {
        if (!ok || in.size() < size) return ok = false;
        std::memcpy(data, in.data(), size);
        in.remove_prefix(size);
        return true;
    }
    template <class T> T get() {
        T value{};
        get(&value, sizeof(value));
        return value;
    }
};
} // namespace detail

inline std::string pack(const Track& track) {
    std::string out;
    detail::put(out, static_cast<std::uint32_t>(track.appearance.size()));
    detail::put(out, track.appearance.data(), track.appearance.size());
    detail::put(out, static_cast<std::uint32_t>(track.samples.size()));
    for (const auto& s : track.samples) {
        detail::put(out, s.step);
        detail::put(out, s.camera.position.data(), sizeof(float) * 3);
        detail::put(out, s.camera.forward.data(), sizeof(float) * 3);
        detail::put(out, s.camera.up.data(), sizeof(float) * 3);
        detail::put(out, s.camera.fov);
        detail::put(out, static_cast<std::uint32_t>(s.pose.size()));
        detail::put(out, s.pose.data(), s.pose.size());
    }
    return out;
}
// The payload back: false when it is not one (cut short, steps not rising, a sample with no pose).
inline bool unpack(std::string_view raw, Track& track) {
    detail::Reader r{raw};
    track = {};
    const auto outfit = r.get<std::uint32_t>();
    if (!r.ok || outfit > r.in.size()) return false;
    track.appearance.resize(outfit);
    r.get(track.appearance.data(), outfit);
    const auto count = r.get<std::uint32_t>();
    if (!r.ok || count == 0 || count > most_samples) return false;
    track.samples.reserve(count);
    for (std::uint32_t i = 0; i < count && r.ok; ++i) {
        Sample s;
        s.step = r.get<std::uint32_t>();
        r.get(s.camera.position.data(), sizeof(float) * 3);
        r.get(s.camera.forward.data(), sizeof(float) * 3);
        r.get(s.camera.up.data(), sizeof(float) * 3);
        s.camera.fov = r.get<float>();
        const auto size = r.get<std::uint32_t>();
        if (!r.ok || size == 0 || size > r.in.size()) return false;
        s.pose.resize(size);
        r.get(s.pose.data(), size);
        if (!track.samples.empty() && s.step <= track.samples.back().step) return false;
        track.samples.push_back(std::move(s));
    }
    return r.ok && r.in.empty() && multiplayer::pose_codec::whole(track.samples.front().pose);
}

// ---- recording ------------------------------------------------------------------------------------------------
// One sample a step: the pose at a step seen again (a frame drawn twice in a step, slow motion) replaces the one
// there, so each step keeps its last.
class Recorder {
public:
    void clear() {
        track = {};
        last_.reset();
        before_last_.reset();
    }
    // False when `step` comes before the last one, or the ghost is full.
    bool add(std::uint32_t step, const multiplayer::Pose& pose, const Camera& camera) {
        namespace pc = multiplayer::pose_codec;
        auto quant = pc::quantize(pose);
        if (!track.samples.empty() && step < track.samples.back().step) return false;
        const bool again = !track.samples.empty() && step == track.samples.back().step;
        if (again) {
            track.samples.pop_back();
            last_ = before_last_;
        } else if (track.samples.size() >= most_samples) {
            return false;
        }
        const bool whole = !last_ || track.samples.size() % whole_every == 0 || last_->skater != quant.skater || last_->board != quant.board;
        Sample s{step, camera, whole ? pc::encode_whole(quant) : pc::encode_delta(quant, *last_)};
        track.samples.push_back(std::move(s));
        before_last_ = std::move(last_);
        last_ = std::move(quant);
        return true;
    }
    Track track;

private:
    std::optional<multiplayer::pose_codec::QuantPose> last_, before_last_;
};

// ---- showing --------------------------------------------------------------------------------------------------
// The pose and camera at any step, between two samples in proportion. Samples decode in order from the nearest
// whole one before; the last two decoded are kept, so showing step after step decodes each sample once.
class Player {
public:
    explicit Player(Track track) : track_(std::move(track)) {}
    struct Frame {
        multiplayer::Pose pose;
        Camera camera;
        bool ended{}; // `step` is at or after the last sample
    };
    const Track& track() const { return track_; }
    std::uint32_t first_step() const { return track_.samples.empty() ? 0 : track_.samples.front().step; }
    std::uint32_t last_step() const { return track_.samples.empty() ? 0 : track_.samples.back().step; }
    // Nothing when the ghost has no samples or a pose would not decode.
    std::optional<Frame> at(double step) {
        namespace mp = multiplayer;
        const auto& samples = track_.samples;
        if (samples.empty() || !std::isfinite(step)) return std::nullopt;
        Frame frame;
        const auto after = std::upper_bound(samples.begin(), samples.end(), step,
            [](double value, const Sample& s) { return value < static_cast<double>(s.step); });
        if (after == samples.begin() || after == samples.end()) {
            const std::size_t i = after == samples.begin() ? 0 : samples.size() - 1;
            const auto* q = decoded(i);
            if (!q) return std::nullopt;
            frame.pose = mp::pose_codec::restore(*q);
            frame.camera = samples[i].camera;
            frame.ended = after == samples.end();
            return frame;
        }
        const std::size_t b = static_cast<std::size_t>(after - samples.begin()), a = b - 1;
        const auto* qa = decoded(a);
        if (!qa) return std::nullopt;
        const auto pa = mp::pose_codec::restore(*qa);
        const auto* qb = decoded(b);
        if (!qb) return std::nullopt;
        const auto pb = mp::pose_codec::restore(*qb);
        const float t = static_cast<float>((step - samples[a].step) / static_cast<double>(samples[b].step - samples[a].step));
        if (pa.skater.size() != pb.skater.size() || pa.board.size() != pb.board.size()) {
            frame.pose = t < 0.5f ? pa : pb;
        } else {
            frame.pose.root = mp::interpolate(pa.root, pb.root, t);
            frame.pose.skater.resize(pa.skater.size());
            frame.pose.board.resize(pa.board.size());
            for (std::size_t j = 0; j < pa.skater.size(); ++j) frame.pose.skater[j] = mp::interpolate(pa.skater[j], pb.skater[j], t);
            for (std::size_t j = 0; j < pa.board.size(); ++j) frame.pose.board[j] = mp::interpolate(pa.board[j], pb.board[j], t);
        }
        const auto& ca = samples[a].camera;
        const auto& cb = samples[b].camera;
        const auto mix = [t](const std::array<float, 3>& x, const std::array<float, 3>& y) {
            return std::array<float, 3>{x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t};
        };
        frame.camera = {mix(ca.position, cb.position), mix(ca.forward, cb.forward), mix(ca.up, cb.up), ca.fov + (cb.fov - ca.fov) * t};
        return frame;
    }

private:
    struct Decoded {
        std::size_t index = static_cast<std::size_t>(-1);
        multiplayer::pose_codec::QuantPose pose;
    };
    const multiplayer::pose_codec::QuantPose* decoded(std::size_t i) {
        namespace pc = multiplayer::pose_codec;
        for (auto& d : cache_)
            if (d.index == i) return &d.pose;
        // From the sample before when it is kept, else from the nearest whole one before.
        std::size_t from = i;
        std::optional<pc::QuantPose> pose;
        for (auto& d : cache_)
            if (i > 0 && d.index == i - 1) {
                pose = d.pose;
                from = i;
            }
        if (!pose) {
            from = i;
            while (from > 0 && !pc::whole(track_.samples[from].pose)) --from;
            if (!pc::whole(track_.samples[from].pose)) return nullptr;
        }
        for (std::size_t k = from; k <= i; ++k) {
            auto next = pc::decode(track_.samples[k].pose, pose ? &*pose : nullptr);
            if (!next) return nullptr;
            pose = std::move(next);
        }
        // Into the slot not holding the one before, so the pair stays.
        auto& slot = cache_[0].index == i - 1 ? cache_[1] : cache_[0];
        slot.index = i;
        slot.pose = std::move(*pose);
        return &slot.pose;
    }
    Track track_;
    std::array<Decoded, 2> cache_{};
};
} // namespace dingosdk::ghost_file
