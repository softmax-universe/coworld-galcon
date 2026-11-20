# Desktop replays

Open **replays** from the main menu to watch a saved match, import a `.replay`
file, or open the replay folder in Finder or File Explorer. Recordings with an
unsupported version stay visible but cannot be played. A replay that fails its
simulation checks returns to the browser with an error message.

**Save replay** in battle setup defaults to enabled. It is a local preference,
including in multiplayer rooms. Completed matches and partial matches are
saved to `Polyworld/Galcon/Replays` under the user's application data folder.
The game menu also offers a manual save when automatic saving is disabled.
Saving while viewing earlier ticks retains the complete recorded match.

Repeated saves reuse the same snapshot unless the recording has advanced or
its saved file was deleted. Failed exit saves remain available through
**Retry saving replay** on the menus. These pending recordings remain in
memory until saved or the game process exits.

The desktop library uses Polyworld's shared browser, storage, preferences, and
save lifecycle. Galcon supplies its visual style and version 23 recording codec.
Each game version accepts exactly one replay format. There are no old-format
decoders, upgrades, or historical simulation modes. Use the matching archived
game version to play older recordings. Browser builds omit the library and
save controls; their replay-viewer entry points are unchanged.

Use `--menu replays` to open the desktop library directly. The existing
`--record FILE` and `--replay FILE` command-line options remain available.
