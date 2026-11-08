ReTake 0.0.5: rewind and retake your lines in skate. (a ReSkate mod, offline only)
https://github.com/N0deNinja/ReTake

INSTALL
  You need skate. on PC with ReSkate 2.1.4-2 installed, and the game started with ReSkate at least once.
  1. Close skate. and the ReSkate launcher.
  2. Double-click "Install ReTake.bat". It finds your game, backs up your ReSkate.dll,
     installs ReTake, and asks to turn off the launcher's automatic updates
     (an update would put the official ReSkate.dll back and remove ReTake).
  3. Start skate. with the ReSkate launcher, play offline, and allow ReTake's permissions when asked.
  4. Press F11 and pick New line. F10 opens Ghost lines: lines other skaters sent you, to watch and try.

  If Windows SmartScreen warns about the .bat, choose "More info", then "Run anyway".
  The installer only touches the skate. folder: ReSkate.dll, Mods\ReTake, ReTake-backup,
  and the "updates" line in ReSkateLauncher.settings.json.

UPDATE
  Close the game and double-click "Install ReTake.bat" from the new version. It finds the
  folder ReTake is in and updates it, keeping your original ReSkate.dll backup.

UNINSTALL
  Close the game and double-click "Uninstall ReTake.bat". It puts your old ReSkate.dll back,
  removes Mods\ReTake, and turns launcher updates back on.

FOUND A BUG?
  Right after it happens, press F11 and click "Report a problem" (top right), write what went
  wrong, and press Save report. ReTake saves a file in
  Mods\.reskate_plugin_data\ReTake\reports with what you wrote and the last 30 seconds of the
  game. Send us that file. ReTake never sends anything by itself.

THIS IS AN EARLY VERSION
  Sometimes a replay drifts from what you skated, mostly on rails and ledges. We're working on it.
  If it happens, go back a little earlier and try again.

ReTake's ReSkate.dll is a modified build of ReSkate (GPL-3.0). Its full source is in the
repository above, in the native folder. It sends no crash reports. Not affiliated with EA or the ReSkate team.
