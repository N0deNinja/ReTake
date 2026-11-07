#pragma once
#include "pad_output.h"
#include <cstddef>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// One controller's values by physics step, latched: while a script runs the game's reads get one value
// from one step to the next, the controller's when recording and the script's when playing. So the
// game sees the same values at the same steps either way: a recording and its replays differ in nothing
// the input can cause. It costs a recording up to one step of input lag. PadOutputs' replacement lasts
// by the clock and follows the client tick, so its value reaches the game some way into a step that
// differs from run to run. No plugin code runs on these threads.
namespace dingosdk::input {
class StepScript {
public:
    enum class Mode : unsigned char { off, recording, playing };
    struct Status {
        Mode mode{Mode::off};
        std::size_t step{}, length{};
        std::string owner, stopped;
        // Steps of this run the game read nothing before: an input that reached it a step late or never.
        std::size_t unread{};
        std::vector<std::size_t> first_unread;
        bool holding{}; // a line waiting: no step counts
    };
    static constexpr std::size_t unread_kept = 64;
    static constexpr std::size_t max_steps = 36000; // ten minutes at the game's 60 steps a second
    static constexpr int max_lead = 8;

    // Client thread: starts recording this controller, replacing the script held.
    std::string record(std::string_view owner, unsigned controller, std::size_t steps) {
        if (controller > PadOutputs::playstation) return "controller is 0 to 3, or playstation";
        if (steps == 0 || steps > max_steps) return "a script is 1 to 36000 steps";
        std::lock_guard lock(mutex_);
        if (const auto why = taken(owner); !why.empty()) return why;
        frames_.clear();
        frames_.reserve(steps);
        limit_ = steps;
        latest_ = {};
        latched_ = {};
        begin(owner, controller, Mode::recording, 0);
        return {};
    }
    // Client thread: gives the script back from its first step. `lead` reads that many steps ahead.
    std::string play(std::string_view owner, unsigned controller, int lead) {
        if (controller > PadOutputs::playstation) return "controller is 0 to 3, or playstation";
        if (lead < -max_lead || lead > max_lead) return "a lead is -8 to 8 steps";
        std::lock_guard lock(mutex_);
        if (const auto why = taken(owner); !why.empty()) return why;
        if (frames_.empty()) return "no script is recorded";
        begin(owner, controller, Mode::playing, lead);
        return {};
    }
    // Physics thread: whatever a line is doing ends; what it holds stays to go back to.
    void halt() {
        std::lock_guard lock(mutex_);
        if (mode_ != Mode::off) end("stopped");
    }
    // Client thread: ends what `owner` runs. What was recorded stays to be played.
    void stop(std::string_view owner) {
        std::lock_guard lock(mutex_);
        if (mode_ != Mode::off && owner_ == owner) end("stopped");
        if (owner_ == owner) line_ = false;
    }
    // Client thread: records as a line, which can be gone back in. Losing the input (the game's own menu)
    // ends the recording as it ends any, and what was skated stays to go back to.
    std::string record_line(std::string_view owner, unsigned controller, std::size_t steps) {
        auto why = record(owner, controller, steps);
        if (why.empty()) {
            std::lock_guard lock(mutex_);
            line_ = true;
        }
        return why;
    }
    // Physics thread: a line holds: no step counts and the game reads a neutral controller, until it runs
    // up. What was recorded stays. False with nothing recorded and nothing running.
    bool hold() {
        std::lock_guard lock(mutex_);
        if (mode_ == Mode::off && frames_.empty()) return false;
        mode_ = Mode::recording;
        holding_ = true;
        run_to_ = 0;
        step_ = frames_.size();
        return true;
    }
    // Physics thread: plays from step `from` up to step `to`. Then, with `hand_over`, what came after `to` is
    // forgotten and it records on from there with the last value it played, until go(); without, it ends as a
    // playing does.
    void run_up(std::size_t from, std::size_t to, bool hand_over) {
        std::lock_guard lock(mutex_);
        to = to < frames_.size() ? to : frames_.size();
        holding_ = false;
        lead_ = 0;
        reads_ = 1;
        unread_ = 0;
        first_unread_.clear();
        hand_over_ = hand_over;
        if (from >= to) {
            finish_run_up(to);
            return;
        }
        mode_ = Mode::playing;
        step_ = from;
        run_to_ = to;
    }
    // After a run up: the controller's from the next step on.
    void go() {
        std::lock_guard lock(mutex_);
        use_last_ = false;
    }
    // The timeline is open: the input being taken costs a line nothing, the game reading a neutral controller.
    void set_paused(bool paused) {
        std::lock_guard lock(mutex_);
        paused_ = paused;
    }
    // Until go(): what the game last read, whatever the controller does, as after a run up.
    void hold_input() {
        std::lock_guard lock(mutex_);
        use_last_ = true;
        latched_ = frames_.empty() ? PadOutput{} : frames_.back();
    }
    // Physics thread, once a step of the local skater.
    void step() {
        std::lock_guard lock(mutex_);
        if (holding_) return;
        if (mode_ != Mode::off && reads_ == 0) {
            ++unread_;
            if (first_unread_.size() < unread_kept) first_unread_.push_back(step_);
        }
        reads_ = 0;
        if (mode_ == Mode::recording) {
            if (use_last_) latched_ = frames_.empty() ? PadOutput{} : frames_.back();
            else latched_ = latest_;
            frames_.push_back(latched_);
            step_ = frames_.size();
            if (frames_.size() >= limit_) end("recorded");
        } else if (mode_ == Mode::playing) {
            ++step_;
            if (run_to_) {
                if (step_ >= run_to_) finish_run_up(run_to_);
            } else if (step_ > frames_.size()) {
                end("played");
            }
        }
    }
    // Input threads, at each read the game makes: what the game should see instead, if anything.
    // `real` is what the controller reads. Not allowed (a menu, another window, a session) ends the run,
    // so an old input is never played after it.
    std::optional<PadOutput> on_read(unsigned controller, const PadOutput& real, bool allowed) {
        std::lock_guard lock(mutex_);
        if (mode_ == Mode::off) return std::nullopt;
        if (!allowed) {
            lose();
            return std::nullopt;
        }
        if (controller != controller_) return std::nullopt;
        ++reads_;
        latest_ = real; // a run up hands over to the controller as it is by then
        if (mode_ == Mode::recording) {
            if (holding_) return PadOutput{};
            return use_last_ ? without_menus(latched_) : latched_;
        }
        // Neutral until the first step, as a recording's reads are.
        const auto frame = frame_at(step_, lead_, frames_.size());
        return frame ? without_menus(frames_[*frame]) : PadOutput{};
    }
    // Input threads: a read the game was kept from, by a menu or the overlay.
    void interrupt() {
        std::lock_guard lock(mutex_);
        if (mode_ != Mode::off) lose();
    }
    // A running script answers this controller's reads.
    bool replacing(unsigned controller) {
        std::lock_guard lock(mutex_);
        return mode_ != Mode::off && controller_ == controller;
    }
    Status status() {
        std::lock_guard lock(mutex_);
        return {mode_, step_, frames_.size(), owner_, stopped_, unread_, first_unread_, holding_};
    }
    // A copy of what is recorded, a value a step, for a bug report.
    std::vector<PadOutput> recorded() {
        std::lock_guard lock(mutex_);
        return frames_;
    }

    // The frame for the reads after `step` steps have run: frame N was latched at step N + 1. Empty
    // before the script's first frame.
    static std::optional<std::size_t> frame_at(std::size_t step, int lead, std::size_t size) noexcept {
        const auto at = static_cast<std::ptrdiff_t>(step) - 1 + lead;
        if (at < 0 || size == 0) return std::nullopt;
        return static_cast<std::size_t>(at) < size ? static_cast<std::size_t>(at) : size - 1;
    }

private:
    // What is replayed never opens anything: the D-pad, Start and Back open the game's menus and its replay, and
    // a press kept in a recording would open them again at every replay of it.
    static constexpr std::uint16_t menu_buttons = 0x003f;
    static PadOutput without_menus(PadOutput pad) noexcept {
        pad.buttons = static_cast<std::uint16_t>(pad.buttons & ~menu_buttons);
        return pad;
    }
    std::string taken(std::string_view owner) const {
        return mode_ != Mode::off && owner_ != owner ? owner_ + " runs a script" : std::string{};
    }
    void begin(std::string_view owner, unsigned controller, Mode mode, int lead) {
        owner_ = std::string(owner);
        controller_ = controller;
        mode_ = mode;
        lead_ = lead;
        step_ = 0;
        holding_ = false;
        line_ = false;
        use_last_ = false;
        run_to_ = 0;
        reads_ = 0;
        unread_ = 0;
        first_unread_.clear();
        stopped_.clear();
    }
    void end(const char* why) {
        mode_ = Mode::off;
        holding_ = false;
        run_to_ = 0;
        stopped_ = why;
    }
    // Over, so an old input is never played after it; what was recorded stays. A line waiting to go back, or with
    // the timeline open, has nothing to lose.
    void lose() {
        if (line_ && paused_) {
            latest_ = {}; // what the game reads meanwhile
            return;
        }
        if (line_ && holding_) return;
        end("the game lost the input");
    }
    void finish_run_up(std::size_t to) {
        run_to_ = 0;
        if (!hand_over_) {
            step_ = to;
            end("played");
            return;
        }
        if (to < frames_.size()) frames_.resize(to);
        step_ = to;
        latched_ = frames_.empty() ? PadOutput{} : frames_.back();
        use_last_ = true;
        mode_ = Mode::recording;
    }

    std::mutex mutex_;
    std::vector<PadOutput> frames_;
    PadOutput latest_{}, latched_{};
    std::string owner_, stopped_;
    std::vector<std::size_t> first_unread_;
    std::size_t step_{}, limit_{}, reads_{}, unread_{}, run_to_{};
    unsigned controller_{};
    int lead_{};
    Mode mode_{Mode::off};
    bool holding_{}, line_{}, hand_over_{}, use_last_{}, paused_{};
};
inline StepScript& step_script() { static auto* value = new StepScript; return *value; }
}
