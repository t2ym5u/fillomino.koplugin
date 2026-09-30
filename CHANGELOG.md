# Changelog

All notable changes to this project will be documented in this file.

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
