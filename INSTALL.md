# Install

1. Close the game. Start with the pinned Gen1Recomp 0.2.36 source install from [DEPENDENCIES.md](DEPENDENCIES.md), with your own imported game data. Keep your existing installation and saves.
2. Extract this project and open a terminal here. Preview the exact file changes:

   `python3 install.py --game /path/to/game`

3. Apply that preview:

   `python3 install.py --game /path/to/game --apply`

The script checks the host and payload hashes, preserves exact originals in `mod-install-backups/` beside the game folder, and stops on unknown existing changes. It never downloads updates, edits saves/settings, or enables a disabled mod. Open the game's MODS menu to enable the mod yourself.

Manual installation: copy `source/FORTUNES_FAVOR` into a new host's `mods/` folder. The host still needs the compatibility changes listed in `install-manifest.json`; use the script to apply those exact changes safely. Copying only the mod folder is not the tested configuration.

Companion projects can be downloaded separately using the README links and installed with the same steps. Use the matching releases listed in DEPENDENCIES.md.
