# Changelog

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
