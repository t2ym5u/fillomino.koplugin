local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")
local Hint      = require("hint")

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
-- Uniqueness counter: MRV-over-regions (mirrors nurikabe's island-growing
-- solver). Grows each given-clue-seeded region -- target size = its clue
-- value, known up front -- one frontier cell at a time, rather than guessing
-- a raw value per empty cell (which is intractably slow here since regions
-- can run past 20 cells once merges cascade). Deliberate approximation: only
-- grows regions that already have >=1 given clue; it does not consider an
-- alternate completion that invents a brand-new region with zero clues
-- anywhere in it. createPuzzle always keeps >=1 given cell per region while
-- digging (losing a region's last clue makes this solver unable to claim
-- those cells at all, so it naturally reports "not unique" and the digger
-- reverts that hide), so this bias only affects exotic phantom-region
-- completions, never the puzzle's own intended solution.
-- ---------------------------------------------------------------------------

local function countSolutions(puzzle, given, n, limit, node_budget)
    local color = {}
    for r = 1, n do color[r] = {}; for c = 1, n do color[r][c] = 0 end end

    local regions = {}
    local gseen = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            if given[r][c] and not gseen[r][c] then
                local v = puzzle[r][c]
                local idx = #regions + 1
                local stack = { {r, c} }
                gseen[r][c] = true
                color[r][c] = idx
                local cells = { {r, c} }
                while #stack > 0 do
                    local cur = table.remove(stack)
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cur[1] + d[1], cur[2] + d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n and given[nr][nc]
                            and puzzle[nr][nc] == v and not gseen[nr][nc] then
                            gseen[nr][nc] = true
                            color[nr][nc] = idx
                            cells[#cells + 1] = {nr, nc}
                            stack[#stack + 1] = {nr, nc}
                        end
                    end
                end
                regions[idx] = { target = v, cells = cells }
            end
        end
    end
    local num_regions = #regions

    local total_cells = n * n
    local claimed = 0
    for r = 1, n do for c = 1, n do if given[r][c] then claimed = claimed + 1 end end end

    local solutions, nodes, exhausted = 0, 0, false

    local function frontierFor(idx)
        local reg = regions[idx]
        local cands, seen = {}, {}
        for _, cell in ipairs(reg.cells) do
            for _, d in ipairs(DIRS) do
                local nr, nc = cell[1] + d[1], cell[2] + d[2]
                local key = nr * 1000 + nc
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and color[nr][nc] == 0 and not seen[key] then
                    local conflict = false
                    for _, d2 in ipairs(DIRS) do
                        local mr, mc = nr + d2[1], nc + d2[2]
                        if mr >= 1 and mr <= n and mc >= 1 and mc <= n then
                            local ov = color[mr][mc]
                            if ov > 0 and ov ~= idx and regions[ov].target == reg.target then
                                conflict = true; break
                            end
                        end
                    end
                    if not conflict then seen[key] = true; cands[#cands + 1] = {nr, nc} end
                end
            end
        end
        return cands
    end

    local function search()
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end

        local best_idx, best_frontier, best_len = nil, nil, math.huge
        for i = 1, num_regions do
            if #regions[i].cells < regions[i].target then
                local frontier = frontierFor(i)
                if #frontier < best_len then
                    best_len, best_frontier, best_idx = #frontier, frontier, i
                    if best_len == 0 then break end
                end
            end
        end

        if not best_idx then
            if claimed == total_cells then solutions = solutions + 1 end
            return
        end
        if best_len == 0 then return end

        local reg = regions[best_idx]
        for _, cell in ipairs(best_frontier) do
            local cr, cc = cell[1], cell[2]
            color[cr][cc] = best_idx
            reg.cells[#reg.cells + 1] = cell
            claimed = claimed + 1
            search()
            claimed = claimed - 1
            reg.cells[#reg.cells] = nil
            color[cr][cc] = 0
            if solutions >= limit or exhausted then return end
        end
    end
    search()
    return solutions, exhausted
end

-- Scale the search node budget down for larger grids, mirroring nurikabe's
-- uniquenessBudgetFor -- larger n means both a bigger CSP and more digging
-- attempts, so keep per-call cost bounded.
local function nodeBudgetFor(n)
    if n <= 6 then return 60000 end
    if n <= 7 then return 40000 end
    return 25000
end

-- ---------------------------------------------------------------------------
-- Create puzzle from solution: dig-with-verification. Starts fully revealed
-- and hides cells one at a time in random order, verifying uniqueness with
-- countSolutions after each tentative hide and reverting if it broke
-- uniqueness -- the same pattern already used by sudoku-common and now most
-- of this fleet. The old behavior picked a flat per-region reveal ratio with
-- zero uniqueness verification.
-- ---------------------------------------------------------------------------

local function createPuzzle(solution, n, difficulty)
    -- Find all regions, only to compute how many cells the old flat-ratio
    -- scheme would have revealed -- used as the total-hide budget below so
    -- difficulty still controls roughly how sparse the puzzle is.
    local visited = emptyBoolGrid(n)
    local regions = {}

    for r = 1, n do
        for c = 1, n do
            if not visited[r][c] then
                local v     = solution[r][c]
                local stack = { {r, c} }
                local cells = {}
                visited[r][c] = true
                while #stack > 0 do
                    local cell = table.remove(stack)
                    local cr, cc = cell[1], cell[2]
                    cells[#cells + 1] = {cr, cc}
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cr + d[1], cc + d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                            and not visited[nr][nc]
                            and solution[nr][nc] == v then
                            visited[nr][nc] = true
                            stack[#stack + 1] = {nr, nc}
                        end
                    end
                end
                regions[#regions + 1] = { value = v, cells = cells }
            end
        end
    end

    local target_reveal = 0
    for _, reg in ipairs(regions) do
        local k = #reg.cells
        local reveal_count
        if difficulty == "easy" then
            reveal_count = math.max(1, math.floor(k * 0.5))
        elseif difficulty == "hard" then
            reveal_count = 1
        else
            reveal_count = math.max(1, math.floor(k * 0.3))
        end
        target_reveal = target_reveal + math.min(reveal_count, k)
    end
    local target_hide = n * n - target_reveal

    local puzzle = emptyGrid(n)
    local given  = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            puzzle[r][c] = solution[r][c]
            given[r][c]  = true
        end
    end

    local order = {}
    for r = 1, n do
        for c = 1, n do order[#order + 1] = {r, c} end
    end
    shuffle(order)

    local budget = nodeBudgetFor(n)
    local hidden = 0
    for _, cell in ipairs(order) do
        if hidden >= target_hide then break end
        local r, c = cell[1], cell[2]
        given[r][c] = false
        local solutions, exhausted = countSolutions(puzzle, given, n, 2, budget)
        if solutions == 1 and not exhausted then
            hidden = hidden + 1
        else
            given[r][c] = true
        end
    end

    for r = 1, n do
        for c = 1, n do
            if not given[r][c] then puzzle[r][c] = 0 end
        end
    end

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

function FillominoBoard:generate(difficulty)
    self.difficulty = difficulty or self.difficulty
    self.undo:clear()
    local n = self.n

    local solution = generateSolution(n)
    local puzzle   = createPuzzle(solution, n, self.difficulty)

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

function FillominoBoard:isSolved()
    local n = self.n
    -- All cells must be filled
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == 0 then return false end
        end
    end
    -- Verify via solution
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] ~= self.solution[r][c] then return false end
        end
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
