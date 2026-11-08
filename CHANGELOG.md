# Changelog

## 0.0.4 (2026-11-08)

### My lines: save your lines and come back to them

- **Save a line and come back to it later, even after closing the game.** F11, **My lines** (top right of the timeline), **Save this line**. Your saved lines are listed there with their length, date and number of retakes, to **Load** or **Delete** (it asks "Sure?" first).
- **Loading a line** replaces the one you have. It is stopped at its end, as if you had just recorded it: open the timeline, pick any moment and retake it, retakes and all.
- **A line keeps its map.** Load one that was saved on another map and ReTake travels there first, the way the game's own travel does, then loads it. Lines saved on maps the game doesn't travel to (custom parks) aren't travelled to: ReTake tells you which map the line is on. ReTake asks for the **"travel"** permission for this, so ReSkate asks you to allow it again.
- **Console:** `retake save [name]` (with a name of your own), `retake lines` (numbered), `retake load <number>`, `retake delete <number>`.
- A line is saved whole: every step of the controller and of the skater (board and body), compressed, in `Mods\.reskate_plugin_data\ReTake\lines`. Saving and loading run in the background, so the game never stutters. A saved line only loads into the same ReTake `ReSkate.dll` build; another one refuses it and says why.

### Fixed

- **Going back starts the way your line started.** A line begun on foot (run, then hop on the board) is now replayed from on foot, and one begun on the board from the board: ReTake reads it from the recording. If the game doesn't put you in that state after the teleport, ReTake teleports again, and after three tries stops and tells you, instead of replaying the line onto a skater in the wrong state (who then jumped about on the spot).
- Reports log the step where the skater comes off the board during a fast-forward.

### Known

- **Lines are most reliable when they start on the board.** A line begun on foot can come out differently after the game is restarted, because ReTake can't hold a skater on foot to the recording (on foot, the stick moves you relative to the camera). Get on your board before New line.
- Replays can still drift on rails and jumps, saved lines or not. Pinning down what the game keeps beside the board and body is next.

### ReSkate.dll

- `reskate.tas.line_export(path)`, `reskate.tas.line_import(path, controller)` and `reskate.tas.line_file_status()`, in the background (zstd).

### Installer

- Knows 0.0.3's `ReSkate.dll`.

## 0.0.3 (2026-11-08)

Slow motion rides like the real game now. The 3, 2, 1 countdown, the timeline and L3 + R3 slow motion all use it, so retakes come out of the countdown the way they went in.

### Fixed

- **Slow motion no longer changes how the skater rides.** The slower it was, the worse it got: the board slid sideways (75° in one 0.15 s countdown), lost speed, and the body went stiff. Cause: slow motion runs the game in shorter physics steps. When skate. builds a skater it works out about 60 values from the step length (copies of it in the board's and the body's physics and in every joint, a power-of-two sub-step), and ReTake's slow motion only changed the step length itself. The game keeps most of those up to date on its own, but about a dozen stayed set for full speed. ReTake's `ReSkate.dll` now updates them whenever the step changes, and only writes a value that still holds exactly what the game's build left there. Found by building the skater at full speed and in slow motion and comparing all of its memory. The check: a skater slowed down now matches one the game built in slow motion, in every one of those values.
- **No more frozen skater after a retake near a jump.** Close to a takeoff the countdown used to run the whole game at 3 frames a second, which could leave the skater stuck in the pose of their last trick, with the board upside down, and launch them off the ground. That countdown is gone: there is one countdown, in smooth slow motion, everywhere.
- **No more fling when the countdown starts mid-jump.** A retake from a moment in the air could throw the board from 11 to 48 m/s. In a jump the game follows a path through the air measured in steps, which ReTake adjusts when the step length changes. Now every step length change goes in between two physics steps, together with that path, never in the middle of one; and in the air the speed changes in one go.
- **No more flicked arms when the game goes back to full speed.** Going from slow motion straight to full speed made each step 20 times longer at once and threw the skater's arms back. Slowing down and speeding up now ease in over about a sixth of a second (in the air, in one go). `retake ease off` switches the easing off, to compare.
- **Slow motion on L3 + R3** gets all of the above.
- The `retake ease` setting, the countdown and the slow-motion test all share one speed control, so nothing fights over the game's speed.

### Reports

- Every physics step in a report now has the board's facing (its axes and up), how fast it turns, the body's distance from the board and how fast the hands move against the body. Every frame has the fastest hand speed since the last frame and the body's distance from the board. A slide, a stiff body or a kick to the arms shows up in the numbers.
- "The replay was at most … m from the recording" is now measured in `ReSkate.dll`, before each recorded step is put back: the exact error of each step. The old figure compared positions a step or two apart and showed 1 to 2 m at high speed where the replay was really within centimetres. The old per-frame figure stays in reports as `drift_rough_m`.

### Tools for finding bugs

- `retake slowtest [m:ss]`: takes the same moment of your line five times, slowed to 1x, 0.5x, 0.25x, 0.1x and 0.05x as the countdown does, with the controller held as recorded, and saves how each one rode compared with the 1x one. It throws away the line after that moment, as a retake does.
- `retake skatertest`: standing still on your board, rebuilds the skater at full speed and in slow motion seven times and saves its memory each time (`results\core`), for comparing. You'll be teleported where you stand a few times.
- `retake ease [on|off]`: whether speed changes ease in (on, the default).

### ReSkate.dll

- `reskate.tas.skater_dump(path)` and `reskate.tas.skater_dump_status()`: the skater's memory as far as it reaches, written in the background.
- `reskate.tas.status()` has `replay_off` and `replay_off_at`: the last catch-up's largest error and its step.
- A changed physics step length is put in at the next physics step, with the values the skater was built with (`Extension/Skater/step_fields.cpp`) and the jump's path.
- Still sends no crash reports.

### Installer

- Knows 0.0.2's `ReSkate.dll` and the 0.0.3 test builds, so updating never backs one of them up as your original.

## 0.0.2 (2026-11-07)

- **Report a problem**, in the timeline (top right) or `retake report` in the console. Write what went wrong and press Save: ReTake saves one file, `Mods\.reskate_plugin_data\ReTake\reports\retake-report-<date>.txt`, with what you wrote and what the game and ReTake were doing in the 30 seconds before you opened the timeline (physics steps, frames, controller input, ReTake's state and log). Nothing is sent anywhere; you choose who gets the file.
- With a line recorded, the report also has the whole line, every step: the controller exactly as recorded and where the board was. So a replay that drifted can be replayed and compared.
- ReTake keeps a short recording of the game all the time for this, and logs how far each replay drifted from the recording.
- Installing over an installed ReTake updates it: it finds that folder by itself, asks nothing it doesn't need to, and never backs up an older ReTake `ReSkate.dll` as the one to go back to.
- ReSkate.dll: `reskate.tas.line_save(path, text)` for the report.

## 0.0.1 (2026-11-07)

The first public release.

- Record a line from a standing start, up to 10 minutes.
- F11 timeline with a ghost skater: pick any moment and replay from there, with a fast-forward catch-up and a 3, 2, 1 count-in.
- Play the whole line back as one run.
- Slow motion on L3 + R3, which works mid-air at full frame rate.
- Bails on and off, Stop all, and a catch-up speed setting.
- One-click installer and uninstaller.
- The ReSkate.dll build sends no crash reports.

Known issue: replays can drift from what you skated, mostly on rails and ledges.
