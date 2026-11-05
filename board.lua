local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")
local Hint      = require("hint")
local Solver    = lrequire("solver")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

local DEFAULT_N          = 6
local DEFAULT_DIFFICULTY = "medium"

-- Must match MAX_DIGIT in screen.lua: the digit keypad only offers 1..9,
-- so no generated region may end up bigger than that or the player would
-- have no way to type its value back in.
local MAX_VALUE = 9

local DIRS = { {-1,0},{1,0},{0,-1},{0,1} }

-- ---------------------------------------------------------------------------
-- Generate a valid Fillomino solution
-- ---------------------------------------------------------------------------

-- Flood-fill: expand a region of target size k starting from (sr,sc).
-- Returns list of {r,c} or nil if can't reach size k.
local function expandRegion(free, n, sr, sc, k)
    local cells = { {sr, sc} }
    local frontier = { {sr, sc} }
    local inRegion = {}
    inRegion[sr * 100 + sc] = true

    while #cells < k and #frontier > 0 do
        -- Build candidate list from frontier neighbors
        local cands = {}
        for _, cell in ipairs(frontier) do
            for _, d in ipairs(DIRS) do
                local nr, nc = cell[1] + d[1], cell[2] + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                    and free[nr][nc]
                    and not inRegion[nr * 100 + nc] then
                    cands[#cands + 1] = {nr, nc}
                    inRegion[nr * 100 + nc] = true
                end
            end
        end
        if #cands == 0 then break end
        shuffle(cands)
        local pick = cands[1]
        cells[#cells + 1] = pick
        frontier = { pick }
        -- keep inRegion set correct
    end

    return cells
end

-- Repeatedly recompute maximal same-value connected components and relabel
-- each one with its own true size, until stable. This is the fixpoint that
-- guarantees the fillomino invariant (component size == displayed value)
-- regardless of how the input grid was built: any independently-placed
-- regions that happen to be adjacent-and-equal-sized are, by definition,
-- actually one bigger component -- so relabeling to the true size and
-- re-checking (since that new size might now collide with a further
-- neighbor) converges to a fully valid grid. Values only ever grow across
-- iterations (merges make components bigger, never smaller) and are capped
-- at n*n, so this always terminates.
local function normalizeToValid(solution, n)
    local changed = true
    while changed do
        changed = false
        local seen = emptyBoolGrid(n)
        for r = 1, n do
            for c = 1, n do
                if not seen[r][c] then
                    local v     = solution[r][c]
                    local stack = { {r, c} }
                    seen[r][c] = true
                    local cells = { {r, c} }
                    while #stack > 0 do
                        local cell = table.remove(stack)
                        local cr, cc = cell[1], cell[2]
                        for _, d in ipairs(DIRS) do
                            local nr, nc = cr + d[1], cc + d[2]
                            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                                and not seen[nr][nc]
                                and solution[nr][nc] == v then
                                seen[nr][nc] = true
                                cells[#cells + 1] = {nr, nc}
                                stack[#stack + 1] = {nr, nc}
                            end
                        end
                    end
                    if #cells ~= v then
                        changed = true
                        for _, cell in ipairs(cells) do
                            solution[cell[1]][cell[2]] = #cells
                        end
                    end
                end
            end
        end
    end
    return solution
end

local function generateSolutionOnce(n)
    local solution = emptyGrid(n)
    local free     = emptyBoolGrid(n)
    -- All cells start free
    for r = 1, n do
        for c = 1, n do free[r][c] = true end
    end

    -- Build list of all cells in random order
    local cells = {}
    for r = 1, n do
        for c = 1, n do cells[#cells + 1] = {r, c} end
    end
    shuffle(cells)

    for _, start in ipairs(cells) do
        local sr, sc = start[1], start[2]
        if free[sr][sc] then
            -- Pick a random size 1..min(5,n)
            local max_k = math.min(5, n)
            local k = math.random(1, max_k)
            local region = expandRegion(free, n, sr, sc, k)
            -- Mark as used
            for _, cell in ipairs(region) do
                free[cell[1]][cell[2]] = false
                solution[cell[1]][cell[2]] = #region
            end
        end
    end

    -- Fill any remaining free cells using the same bounded-size growth as
    -- the main loop above, instead of dumping every leftover connected
    -- component into a single stamped blob. An unbounded blob can span
    -- dozens of cells, producing a clue value the digit keypad (1..9) can
    -- never let the player type back in.
    local max_k = math.min(5, n)
    for r = 1, n do
        for c = 1, n do
            if free[r][c] then
                local k = math.random(1, max_k)
                local region = expandRegion(free, n, r, c, k)
                for _, cell in ipairs(region) do
                    free[cell[1]][cell[2]] = false
                    solution[cell[1]][cell[2]] = #region
                end
            end
        end
    end

    return normalizeToValid(solution, n)
end

-- Bounding every region's initial growth to <=5 (above) keeps the common
-- case within the keypad's 1..9 range, but normalizeToValid's merges can
-- rarely still push a region past 9 (e.g. two adjacent size-5 regions
-- coalescing into 10) since merges are only ever discovered after the fact.
-- Retry generation outright when that happens rather than trying to patch
-- an already-merged grid.
local function generateSolution(n)
    for _ = 1, 200 do
        local solution = generateSolutionOnce(n)
        local max_v = 0
        for r = 1, n do
            for c = 1, n do
                if solution[r][c] > max_v then max_v = solution[r][c] end
            end
        end
        if max_v <= MAX_VALUE then return solution end
    end
    return generateSolutionOnce(n)
end

-- ---------------------------------------------------------------------------
-- Create puzzle from solution: dig with the logic solver as the gate.
-- Starts fully revealed and hides cells one at a time in a random order; a
-- hide stays only if the solver (solver.lua, no trial) still fills the whole
-- grid with the steps allowed at that point. A puzzle the solver fills is
-- unique -- also when a region ends up with no clue at all -- and never
-- needs a guess.
--
-- The dig runs in three phases, each going on from the previous one, so
-- every level's puzzle is a prefix of one list of hides:
--   phase 1  tier 1 (borders, single exits, groups that can only complete
--            one way), random order, until HIDE_SHARE[1] of the cells are
--            hidden -- every region keeps a clue
--   phase 2  tier 2 (also "too small a space", "must pass through here"),
--            cells of the regions with the most clues left first, until
--            HIDE_SHARE[2]
--   phase 3  tier 3 (also small pockets that fill only one way), random
--            order, as far as logic goes
-- Easy keeps the phase-1 hides, Medium phases 1-2, Hard all three. When a
-- phase adds nothing (logic ran out early), the level below gives back a
-- few hides, so Easy shows more clues than Medium and Medium more than
-- Hard: a seed never gives two levels the same puzzle.
--
-- Work is bounded by solver runs, never by time: each phase tries each
-- still-given cell at most once, so at most 3*n*n quick runs, plus the final
-- checks.
-- ---------------------------------------------------------------------------

local LEVEL_TIER = { easy = 1, medium = 2, hard = 3 }
local HIDE_SHARE = { 0.48, 0.58, 1 }

-- Regions of the solution: region[r][c] = id, size[id] = cells.
local function solutionRegions(solution, n)
    local region, size = emptyGrid(n), {}
    for r = 1, n do
        for c = 1, n do
            if region[r][c] == 0 then
                local id = #size + 1
                local v, stack, cnt = solution[r][c], { {r, c} }, 0
                region[r][c] = id
                while #stack > 0 do
                    local cell = table.remove(stack)
                    cnt = cnt + 1
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cell[1] + d[1], cell[2] + d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                            and region[nr][nc] == 0 and solution[nr][nc] == v then
                            region[nr][nc] = id
                            stack[#stack + 1] = {nr, nc}
                        end
                    end
                end
                size[id] = cnt
            end
        end
    end
    return region, size
end

-- One phase: try to hide still-given cells while fewer than `cap` are
-- hidden, each cell at most once, and none phase 2 failed when `skip_failed`
-- (phase 3). `rich`: try first the cells whose region keeps the most clues
-- (the likeliest to go), else follow the random order. `probe`: stop at the
-- first hide. The quick test of a hide stops the solver as soon as it
-- deduces the hidden cell again -- from there it knows at least what the
-- previous, verified, puzzle gave it.
local function digPhase(D, tier, cap, rich, probe, skip_failed)
    local puzzle, solution, n = D.puzzle, D.solution, D.n
    local region, clues, kept, failed = D.region, D.clues, D.kept, D.failed
    local tried, found = {}, 0
    while #kept < cap do
        local cell, best
        for _, cand in ipairs(D.order) do
            local r, c = cand[1], cand[2]
            if puzzle[r][c] ~= 0 and not tried[cand]
                and not (skip_failed and failed[cand]) then
                local cl = clues[region[r][c]]
                if not best or cl > best then cell, best = cand, cl end
                if not rich then break end
            end
        end
        if not cell then break end
        tried[cell] = true
        if D.tick then D.tick() end
        local r, c = cell[1], cell[2]
        puzzle[r][c] = 0
        if Solver.solve(puzzle, n, tier, cell) then
            kept[#kept + 1] = cell
            clues[region[r][c]] = clues[region[r][c]] - 1
            found = found + 1
            if probe then break end
        else
            puzzle[r][c] = solution[r][c]
            if tier == 2 then failed[cell] = true end
        end
    end
    return found
end

local function sameGrid(a, b, n)
    for r = 1, n do
        for c = 1, n do
            if a[r][c] ~= b[r][c] then return false end
        end
    end
    return true
end

local function createPuzzle(solution, n, difficulty, on_progress)
    local level = LEVEL_TIER[difficulty] or 2
    local N = n * n
    local back = math.max(2, math.floor(N * 0.06))

    local puzzle = emptyGrid(n)
    for r = 1, n do
        for c = 1, n do puzzle[r][c] = solution[r][c] end
    end
    local order = {}
    for r = 1, n do
        for c = 1, n do order[#order + 1] = {r, c} end
    end
    shuffle(order)

    local tries, expect = 0, N * (level == 3 and 3 or 2.2)
    local tick = on_progress and function()
        tries = tries + 1
        on_progress(math.min(0.95, tries / expect))
    end

    -- Phases 1 and 2 are the same for every level; Hard goes on with
    -- phase 3, Easy and Medium only probe it (does it add a hide at all?
    -- That doesn't depend on the order the cells are tried in.)
    -- Phase 3 skips the cells phase 2 failed to hide: the grid has only
    -- lost clues since, so tier 2 would fail them again, and the pockets of
    -- tier 3 rarely make the difference -- these runs were most of the time.
    local region, clues = solutionRegions(solution, n)
    local kept, h = {}, {}
    local D = {
        puzzle = puzzle, solution = solution, n = n, order = order,
        region = region, clues = clues, kept = kept, failed = {}, tick = tick,
    }
    digPhase(D, 1, math.floor(N * HIDE_SHARE[1]), false)
    h[1] = #kept
    digPhase(D, 2, math.floor(N * HIDE_SHARE[2]), true)
    h[2] = #kept
    local want
    if level == 3 then
        digPhase(D, 3, N, false, false, true)
        want = #kept
    else
        local more = digPhase(D, 3, h[2] + 1, true, true, true) > 0
        local len2 = more and h[2] or math.max(0, h[2] - back)
        if level == 2 then
            want = len2
        else
            want = (len2 > h[1]) and h[1] or math.max(0, len2 - back)
        end
    end
    for j = #kept, want + 1, -1 do
        local cell = kept[j]
        puzzle[cell[1]][cell[2]] = solution[cell[1]][cell[2]]
        kept[j] = nil
    end

    -- Never ship an unverified puzzle: solve it in full, to the very
    -- solution; should that ever fail, give back the latest hides one at a
    -- time until it passes (the full grid always does).
    while #kept > 0 do
        local ok, grid = Solver.solve(puzzle, n, level)
        if ok and sameGrid(grid, solution, n) then break end
        local cell = kept[#kept]
        puzzle[cell[1]][cell[2]] = solution[cell[1]][cell[2]]
        kept[#kept] = nil
    end
    if on_progress then on_progress(1) end
    return puzzle
end

-- ---------------------------------------------------------------------------
-- FillominoBoard
-- ---------------------------------------------------------------------------

local FillominoBoard = {}
FillominoBoard.__index = FillominoBoard

function FillominoBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local obj = setmetatable({
        n               = n,
        difficulty      = opts.difficulty or DEFAULT_DIFFICULTY,
        puzzle          = emptyGrid(n),
        solution        = emptyGrid(n),
        user            = emptyGrid(n),
        given           = emptyBoolGrid(n),
        wrong_marks     = emptyBoolGrid(n),
        selected        = nil,
        undo            = UndoStack:new{ max_size = 300 },
    }, self)
    return obj
end

-- `on_progress(fraction)`, optional, for the screen's progress bar.
function FillominoBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    self.undo:clear()
    local n = self.n

    local solution = generateSolution(n)
    local puzzle   = createPuzzle(solution, n, self.difficulty, on_progress)

    self.solution    = solution
    self.puzzle      = puzzle
    self.user        = emptyGrid(n)
    self.given       = emptyBoolGrid(n)
    self.wrong_marks = emptyBoolGrid(n)
    self.selected    = nil

    for r = 1, n do
        for c = 1, n do
            if puzzle[r][c] > 0 then
                self.given[r][c]  = true
                self.user[r][c]   = puzzle[r][c]
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Cell access
-- ---------------------------------------------------------------------------

function FillominoBoard:isGiven(r, c)
    return self.given[r] and self.given[r][c] == true
end

function FillominoBoard:selectCell(r, c)
    self.selected = { r = r, c = c }
end

function FillominoBoard:setCell(r, c, v)
    if self:isGiven(r, c) then return false, "given" end
    local prev = self.user[r][c]
    if prev == v then return true end
    self.undo:push{ r = r, c = c, prev = prev }
    self.user[r][c] = v
    self.wrong_marks[r][c] = false
    return true
end

function FillominoBoard:clearCell(r, c)
    return self:setCell(r, c, 0)
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function FillominoBoard:canUndo() return self.undo:canUndo() end

function FillominoBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end
    self.user[entry.r][entry.c]        = entry.prev
    self.wrong_marks[entry.r][entry.c] = false
    return true
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

-- Returns region_id grid and list of regions
local function computeUserRegions(user, n)
    local region_id = emptyGrid(n)
    local regions   = {}
    for r = 1, n do
        for c = 1, n do
            if region_id[r][c] == 0 and user[r][c] > 0 then
                local rid   = #regions + 1
                local v     = user[r][c]
                local cells = {}
                local stack = { {r, c} }
                region_id[r][c] = rid
                while #stack > 0 do
                    local cell = table.remove(stack)
                    local cr, cc = cell[1], cell[2]
                    cells[#cells + 1] = {cr, cc}
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cr + d[1], cc + d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                            and region_id[nr][nc] == 0
                            and user[nr][nc] == v then
                            region_id[nr][nc] = rid
                            stack[#stack + 1] = {nr, nc}
                        end
                    end
                end
                regions[rid] = { value = v, cells = cells }
            end
        end
    end
    return region_id, regions
end

function FillominoBoard:checkProgress()
    local n = self.n
    local _, regions = computeUserRegions(self.user, n)
    for r = 1, n do
        for c = 1, n do
            self.wrong_marks[r][c] = false
        end
    end
    -- Mark cells whose group size doesn't match the number
    for _, reg in pairs(regions) do
        if #reg.cells ~= reg.value then
            for _, cell in ipairs(reg.cells) do
                self.wrong_marks[cell[1]][cell[2]] = true
            end
        end
    end
    -- Mark cells adjacent to same-value different-region cells
    local region_id = {}
    for rid, reg in pairs(regions) do
        for _, cell in ipairs(reg.cells) do
            if not region_id[cell[1]] then region_id[cell[1]] = {} end
            region_id[cell[1]][cell[2]] = rid
        end
    end
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] > 0 then
                local rid1 = region_id[r] and region_id[r][c]
                local sz1  = regions[rid1] and #regions[rid1].cells or 0
                for _, d in ipairs(DIRS) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                        local rid2 = region_id[nr] and region_id[nr][nc]
                        if rid2 and rid1 ~= rid2 then
                            local sz2 = regions[rid2] and #regions[rid2].cells or 0
                            if self.user[r][c] == self.user[nr][nc] and sz1 == sz2
                                and sz1 == self.user[r][c] then
                                -- Two completed same-size regions adjacent
                                self.wrong_marks[r][c]   = true
                                self.wrong_marks[nr][nc] = true
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Any valid filling wins, not only the stored solution: every cell filled
-- and every group of equal numbers exactly as big as its number (two equal
-- groups that touch are one group, so they come out too big). Givens can't
-- be edited, so they always match.
function FillominoBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == 0 then return false end
        end
    end
    local _, regions = computeUserRegions(self.user, n)
    for _, reg in ipairs(regions) do
        if #reg.cells ~= reg.value then return false end
    end
    return true
end

function FillominoBoard:getRemainingCells()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == 0 then count = count + 1 end
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

Hint.install(FillominoBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b:isGiven(r, c) end,
    setCell     = function(b, r, c, v) return b:setCell(r, c, v) end,
    clearCell   = function(b, r, c) return b:clearCell(r, c) end,
})

function FillominoBoard:serialize()
    local n = self.n
    local given_out = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            given_out[r][c] = self.given[r][c] and true or false
        end
    end
    return {
        n            = n,
        difficulty   = self.difficulty,
        puzzle       = copyGrid(self.puzzle, n),
        solution     = copyGrid(self.solution, n),
        user         = copyGrid(self.user, n),
        given        = given_out,
        wrong_marks  = copyGrid(self.wrong_marks, n),
        undo         = self.undo:serialize(),
    }
end

function FillominoBoard:load(data)
    if type(data) ~= "table" or not data.puzzle or not data.solution then
        return false
    end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.puzzle     = copyGrid(data.puzzle, n)
    self.solution   = copyGrid(data.solution, n)
    self.user       = copyGrid(data.user or {}, n)

    self.given = emptyBoolGrid(n)
    if data.given then
        for r = 1, n do
            for c = 1, n do
                local v = data.given[r] and data.given[r][c]
                self.given[r][c] = (v == true or v == 1)
            end
        end
    end

    self.wrong_marks = emptyBoolGrid(n)
    if data.wrong_marks then
        for r = 1, n do
            for c = 1, n do
                local v = data.wrong_marks[r] and data.wrong_marks[r][c]
                self.wrong_marks[r][c] = (v == true or v == 1)
            end
        end
    end

    self.selected = nil
    self.undo = UndoStack:new{ max_size = 300 }
    if data.undo then self.undo:load(data.undo) end
    return true
end

return FillominoBoard
