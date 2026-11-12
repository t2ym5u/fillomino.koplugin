# Changelog

All notable changes to this project will be documented in this file.

## [1.5.1] - 2026-11-12

### Changed
- Picks up game-common 1.16.0: games for two readers (new Two readers
  category) and the shared Start / Join dialog.

## [1.5.0] - 2026-11-05

### Changed
- Easy, Medium and Hard are really different now. They used to give the
  very same grid for a given game, with about 70% of the cells filled in.
  Easy now fills in about half the cells, keeps a clue in every region and
  only needs simple steps; Medium shows fewer clues and needs more
  thinking (a cell whose space is too small for a number, a cell a group
  must grow through, regions with no clue at all); Hard shows the fewest.
- Every puzzle is checked by a new logic solver, the way a player reasons:
  it always has exactly one solution and never needs a guess. Before, about
  one grid in eight could not be finished by step-by-step logic alone.
- The Daily Challenge grid of the day changes once with this update.
- A progress bar shows while a large grid is being made.

### Fixed
- Any correct filling of the grid now wins, not only the one stored with
  the puzzle.

## [1.4.5] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.4.4] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Changed
- Redesigned play screen: the digits 1-9 form one even row of keys above a
  full-width Check/Hint/Erase/Undo bar, and the board fills the room they
  leave, with one edge around it.
- The status line reads "6×6 · Medium · Empty: 20" and wraps in landscape
  instead of being cut off.
- Title-bar menu: "Size: 6×6" and "Difficulty: Medium" instead of "Grid: 6×6"
  and "Diff: Medium".
- Once the puzzle is solved, the action bar shows "New game" in place of its
  buttons.

### Fixed
- Tapping Undo crashed ("attempt to call method 'undo'"): the board's undo
  stack field shadowed its `undo()` method.
- Digits overflowed their cells: game-common's font fit accepted every size,
  then DPI scaled it up again. They now fit their cell on every screen.
- An applied Hint no longer wipes the saved game (game-common saved it as
  nil). When a hint fills the last cell, the status now shows the win message.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.
- `i18n_fr.lua` shipped to the device but was never loaded: nothing called
  `i18n.extend()` on it, so the whole table was dead weight. main.lua now
  merges it in before the menu entry is built.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.

## [1.1.12] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_C / COLOR_GRAY_A), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_GRAY / COLOR_LIGHT_GRAY).

## [1.1.8] - 2026-07-29

### Fixed
- Solution generation could produce grids that broke fillomino's own rule:
  leftover cells left over after region-growing were each stamped as a
  fixed size-1 region, so two such cells ending up adjacent formed one
  real connected region while both displayed "1". Leftover cells are now
  grouped into their true connected components and a normalization pass
  guarantees every displayed value matches its region's actual size.
- Generated puzzles had no uniqueness verification — clues were revealed
  using a flat per-region ratio with no check that the puzzle actually
  had a single solution. Puzzle creation now starts fully revealed and
  hides cells one at a time, verifying after each hide (via a
  region-growing solver) that exactly one solution remains, reverting
  any hide that breaks uniqueness.
