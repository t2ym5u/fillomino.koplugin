local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

local DEFAULT_N          = 6
local DEFAULT_DIFFICULTY = "medium"

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

local function generateSolution(n)
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

    -- Fill any remaining free cells as size-1 regions
    for r = 1, n do
        for c = 1, n do
            if solution[r][c] == 0 then
                solution[r][c] = 1
            end
        end
    end

    return solution
end

-- ---------------------------------------------------------------------------
-- Verify no two same-sized adjacent regions share a border
-- ---------------------------------------------------------------------------

local function checkAdjacency(solution, n)
    -- Find connected components (regions) in solution
    local region_id = emptyGrid(n)
    local next_id   = 0
    for r = 1, n do
        for c = 1, n do
            if region_id[r][c] == 0 then
                next_id = next_id + 1
                local v     = solution[r][c]
                local stack = { {r, c} }
                region_id[r][c] = next_id
                while #stack > 0 do
                    local cell = table.remove(stack)
                    local cr, cc = cell[1], cell[2]
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cr + d[1], cc + d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                            and region_id[nr][nc] == 0
                            and solution[nr][nc] == v then
                            region_id[nr][nc] = next_id
                            stack[#stack + 1] = {nr, nc}
                        end
                    end
                end
            end
        end
    end

    -- Check: no two different regions with same size share an edge
    for r = 1, n do
        for c = 1, n do
            local id1 = region_id[r][c]
            local sz1 = solution[r][c]
            for _, d in ipairs(DIRS) do
                local nr, nc = r + d[1], c + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                    local id2 = region_id[nr][nc]
                    local sz2 = solution[nr][nc]
                    if id1 ~= id2 and sz1 == sz2 then
                        return false
                    end
                end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Create puzzle from solution: reveal some cells as clues
-- ---------------------------------------------------------------------------

local function createPuzzle(solution, n, difficulty)
    -- Find all regions
    local visited   = emptyBoolGrid(n)
    local regions   = {}  -- list of {value, cells={...}}

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

    -- Decide how many cells per region to reveal
    local puzzle = emptyGrid(n)
    for _, reg in ipairs(regions) do
        local k = #reg.cells
        -- Reveal at least 1 cell per region; more for larger regions on easy
        local reveal_count
        if difficulty == "easy" then
            reveal_count = math.max(1, math.floor(k * 0.5))
        elseif difficulty == "hard" then
            reveal_count = 1
        else
            reveal_count = math.max(1, math.floor(k * 0.3))
        end
        reveal_count = math.min(reveal_count, k)
        local order = {}
        for i = 1, k do order[i] = i end
        shuffle(order)
        for i = 1, reveal_count do
            local cell = reg.cells[order[i]]
            puzzle[cell[1]][cell[2]] = reg.value
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

    -- Attempt to generate a valid solution (retry if adjacency check fails)
    local solution
    local ok = false
    for attempt = 1, 30 do
        solution = generateSolution(n)
        if checkAdjacency(solution, n) then ok = true; break end
    end
    if not ok then
        -- Fallback: one single region covering the whole grid (trivially satisfies adjacency)
        solution = emptyGrid(n)
        local total = n * n
        for r = 1, n do
            for c = 1, n do solution[r][c] = total end
        end
    end

    local puzzle = createPuzzle(solution, n, self.difficulty)

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
