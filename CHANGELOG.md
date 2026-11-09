# Changelog

## 0.0.6 (2026-11-09)

Ghost lines get your Steam name and a naming step, floating labels you can turn down or off and that hold still, and default clothes and board parts for mods you don't have. Also fixes Watch breaking ReTake, ReTake not loading at game start, and "ride for a moment first" when you had.

### Ghost lines

- **Your real name over your ghost.** Offline, ghost lines were signed "a skater". ReTake now signs them with your Steam name, read the same way ReSkate's own name tags read it, and saved lines get it too.
- **Name it when you make it.** **Make a ghost of my line** first asks for a **Title** and **Your name**, both filled in already. Type over either one; Tab switches fields, Enter makes it, Esc goes back. If your Steam name can't be read, the name field is empty and asks you to type one. A name you type is kept for your next ghost lines.
- **Fewer floating labels, if you want.** A new **Floating labels** setting at the bottom of the F10 window goes round **All**, **Near only** (just the starts within 40 m, where F10 starts them) and **Off** (no names over the starts or the ghosts). Also: `retake ghosts labels all|near|off`. Far-off pins are drawn a little smaller.
- **Labels hold still.** The names over ghost line starts and over a ghost's skater no longer shake while the camera moves: they're placed with the camera the game's renderer drew that frame with. The name over a ghost follows its head as the game draws it, so it stays on the skater while it moves, and it sits closer to the head.
- **Mod clothes and boards you don't have.** A ghost line made with clothes or board parts from a cosmetics mod you don't have shows the default for each one you're missing, as multiplayer already did. On the board: a blank natural deck, plain black grip, basic trucks and white wheels, and no sticker where a modded one was. And if a missing piece leaves the ghost underdressed (a modded full-body costume, say), it wears the default outfit instead: a black tee, olive chinos and black slip-ons.

### Fixes

- **Watch broke ReTake.** Showing a ghost builds a skater model, and ReSkate counted that against ReTake's 50 ms a tick, so it stopped ReTake as the ghost first showed: two skaters, the ghost twitching in place, and no hotkeys. Building and taking down the ghost no longer count against ReTake. And if ReTake is ever stopped mid-watch, ReSkate now takes its ghost down.
- **ReTake didn't load (F11 did nothing).** ReSkate stops a plugin whose load takes longer than 50 ms, and with the PC busy starting the game, ReTake's setup went over. It now loads a module at a time over the game's first ticks, each step well inside the limit. The log says how long the longest step took.
- **"Ride for a moment first" when you had.** ReTake refused every replay while the game's sensor block was off, even for a line skated with it off, which replays just the same. Now it only refuses a line skated with the block on, replayed with it off (the case that goes off on rails). Lines remember which it was, saved ones too. Each time the block switches, ReTake's log says so, to find what turns it off mid-session.

### ReSkate.dll

- `reskate.tas.player_name()`: your Steam name, offline too (nil when it isn't known).
- `d:follow(world_position)`: draw a tag about a point in the world that keeps to it while the camera moves (the overlay moves it with the camera of the frame being drawn). Returns where the point is on screen, or nil behind the camera; `d:follow()` ends it.
- `d:follow(position, {ghost_head = metres})`: the tag keeps that far above the middle of the ghost line skater's head as the renderer drew it this frame (the position stands in until then).
- Followed tags and world shapes (`d:world_text`, `d:world_line`, …) are projected with the camera the renderer drew the frame with, taken by the x-ray's view hook (on only while something is drawn over the world), so they stay put while the camera moves.
- Ghost lines' outfits: a missing item that would leave a slot empty puts the default outfit on the empty slots.
- Building and taking down a ghost (`ghost_frame` with show, `ghost_hide`) no longer counts against a plugin's time limit, and a plugin that is stopped or unloaded has its ghost taken down and its ghost recording stopped.
- Still sends no crash reports.

### Installer

- Knows 0.0.5's `ReSkate.dll` and the 0.0.6 test builds, so updating never backs one of them up as your original.

## 0.0.5 (2026-11-08)

Ghost lines: share a line with friends, who watch it through your eyes and then try it with your skater beside them. Also: every try kept as a take, sharing your lines, slow motion on any button, and a new look in the game's own style.

### Ghost lines: watch someone's line, then try it with them

- **F10 opens Ghost lines**: other skaters' lines to watch and try. A line can't be retaken or changed here: it's theirs to match.
- **Making one:** skate a line (retakes and all), then **F10, Make a ghost of my line** (or `retake ghost make [name]`). The line plays once, hands off, while ReTake keeps your skater's pose at every step, your outfit and your camera. It's saved as a `.ghost` file in `Mods\.reskate_plugin_data\ReTake\ghosts` (**Open folder**): send that file to share it. `retake name <name>` sets the name shown over your skater.
- **Finding them:** a pin floats over the start of each ghost line on the map you're on, with its name and distance. Near one, ReTake tells you it's there. The window lists them nearest first, with a map of the ones around you. One on another map travels there first.
- **Watch:** you see the line as its skater saw it, through their camera, with their skater in their outfit and their name above them.
- **Try it:** you start where they started, at their speed, after 3, 2, 1. Their skater rides beside you as a ghost with their name over them. It keeps to the game's own steps, so pausing or slow motion holds it too. When it ends, F10 tries again.
- The ghost is a real skater model, shown the way ReSkate's multiplayer shows another player. It doesn't collide with you. Offline only.
- Watching or trying a ghost line keeps your own line: a line being recorded ends where it was, and nothing is forgotten.

### A new look, in the game's own style

- **ReTake now looks like the rest of skate.'s menus**: the timeline, My lines, Ghost lines and Report a problem use the game's hand-cut tiles, its fonts and its big capitals, with ReTake's teal where the game uses blue. What is chosen turns white, keys show as keycaps (Enter, Esc, F10), settings show their name on the left and their value in teal on the right, as in the game's own settings, and the paused state sits on a sticky note.
- The 3, 2, 1 countdown is in the game's marker font, like its trick callouts.
- The tags over ghost lines and over a ghost's skater are paper tiles with a point down to where it is, and the distance beside them.
- The report box is white with dark text, like the game's own text boxes.
- Nothing about how anything works has changed: every button is where it was.

### Slow motion on any button, or none

- **Pick your own slow-motion button.** In the timeline, click **Slow-mo key**, then press the button or buttons you want together and let go: any controller buttons (triggers and the D-pad too) or a key. L3 + R3 is still the default, for anyone who doesn't use them for the camera.
- **Turn it off:** click **Slow-mo key** twice. Slow motion then has no button (`retake slowmo` still turns it on).
- Pressing nothing for 10 seconds, or Esc, keeps the button you had. F10, F11 and Ctrl+R are ReTake's own and can't be used.
- Console: `retake slowmo key` says which it is; `retake slowmo key Pad.LB+Pad.RB`, `Ctrl+K`, `off` or `default` sets it.
- Your choice is kept between games (`slowmo_key.txt`). A button set for ReTake's slow motion in ReSkate's own Binds page still wins over it.

### Takes: every try is kept

- **A retake no longer throws away what it cuts.** Just before a retake records over a line, the line as it was is kept as a take. The timeline header then shows **< Take 2 of 3 >**: click the arrows to switch to an earlier try and carry on from it. The one you are skating is kept first, so switching never loses anything.
- **Combining the best parts:** a take branches where it was retaken. Go to the try whose ending you like, pick a moment, and retake from there.
- A line keeps up to 60 takes (the oldest go first). A line's takes are deleted when you start a new line, unless the line is saved in My lines, in which case they stay with it.

### Share a line

- **My lines → Share** shows the line's file in its folder (`Mods\.reskate_plugin_data\ReTake\lines`). Send that `.retake` file to anyone with ReTake.
- **Receiving one:** drop the `.retake` file into that folder (**Open folder** in My lines). It shows up in My lines with who made it, and loads like your own lines: it travels to its map, and you can play it, retake it and save your own version. Your version says which line it was **built on**.
- Lines are now saved as `.retake` files that carry their own name, map and author, so a single file is all you need to send. Lines saved by 0.0.4 still load.
- A shared line replays from its recording, so it plays back for anyone. Retaking it means skating it yourself, and tricks from mods the other player has and you don't won't come out the same.

### Fixed

- **A loaded line no longer goes off at its first rail.** Played straight after starting the game, before you had skated, a loaded line took rails the other way, every time: a part of the game that only starts once the skater is ridden had not started, and a replay alone never starts it. Now ReTake asks you to ride for a moment first when it hasn't started. Played after riding, the same line replays as it was skated.

### Research (console)

- `retake statetest`: the first time, starts a line. The second time, it ends the line, saves it to My lines as "State test <time>", and plays it back twice, writing a snapshot of the game's skater state for the run and each replay to `logs\tas_state`. `retake statetest replay`, after restarting the game and loading that line, plays it once more and writes its snapshot too. A line replays exactly in the session it was skated in, but can drift once loaded after a restart, so the difference between those snapshots shows what a replay still has to put back.
- `retake ghosttest`: tries showing a real skater model in your outfit 3 m to your side, copying you live (it uses the same code multiplayer uses to show other players). If it works, the timeline's ghost can be your skater rather than a skeleton. Run it again to turn it off.
- `retake warmtest`: tries starting that part of the game without riding, so a loaded line could play straight away. It says whether the game kept it started.

### ReSkate.dll

- Saved lines carry a note (version 2 of the line file; version 1 still loads): `reskate.tas.line_export(path, note)`, `reskate.tas.line_note(path)`.
- `reskate.tas.ghost_probe(show, x, y, z)`.
- `reskate.tas.status()` has `sensor_started` (whether the skater has been ridden since the game started) and `sensor_writes`; `reskate.tas.sensor_start()` (research).
- State snapshots are written in the background.
- Ghost lines (`Extension/Plugins/ghost_file.h`): `reskate.tas.ghost_record(on)`, `ghost_capture(step)`, `ghost_status()`, `ghost_export(path, note)`, `ghost_note(path)`, `ghost_load(path)` (saving and loading in the background), `ghost_frame(step)`, `ghost_show(step)` and `ghost_hide()`. A ghost keeps a pose a step as multiplayer encodes it (each the difference from the one before, every 60th whole), the camera, and the outfit; it is shown in the last multiplayer player slot, offline only.
- Still sends no crash reports.

### Installer

- Knows 0.0.4's `ReSkate.dll` and the 0.0.5 test builds, so updating never backs one of them up as your original.

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
