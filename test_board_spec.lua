local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("FillominoBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local function newBoard(diff)
        math.randomseed(42)
        local b = Board:new({ n = 6, difficulty = diff or "easy" })
        b:generate()
        return b
    end

    -- Flood-fill same-value connected regions in a solved grid.
    local function regionSizes(grid, n)
        local seen = {}
        for r = 1, n do seen[r] = {} end
        local sizes = {}
        for r = 1, n do
            for c = 1, n do
                if not seen[r][c] then
                    local v, stack, size = grid[r][c], { {r, c} }, 0
                    seen[r][c] = true
                    while #stack > 0 do
                        local cell = table.remove(stack)
                        size = size + 1
                        for _, d in ipairs({ {1,0},{-1,0},{0,1},{0,-1} }) do
                            local nr, nc = cell[1] + d[1], cell[2] + d[2]
                            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                                and not seen[nr][nc] and grid[nr][nc] == v then
                                seen[nr][nc] = true
                                stack[#stack + 1] = { nr, nc }
                            end
                        end
                    end
                    sizes[#sizes + 1] = { value = v, size = size }
                end
            end
        end
        return sizes
    end

    describe("generate", function()
        it("every connected region's size equals its cell value (fillomino invariant)", function()
            local b = newBoard()
            for _, reg in ipairs(regionSizes(b.solution, b.n)) do
                assert.are.equal(reg.value, reg.size,
                    ("region valued %d actually has %d cells"):format(reg.value, reg.size))
            end
        end)

        it("leaves at least one cell blank (puzzle isn't fully revealed)", function()
            local b = newBoard()
            local blanks = 0
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.puzzle[r][c] == 0 then blanks = blanks + 1 end
                end
            end
            assert.is_true(blanks > 0)
        end)

        it("given cells are pre-filled into user with the puzzle's value", function()
            local b = newBoard()
            for r = 1, b.n do
                for c = 1, b.n do
                    if b:isGiven(r, c) then
                        assert.are.equal(b.puzzle[r][c], b.user[r][c])
                    end
                end
            end
        end)
    end)

    describe("setCell / clearCell / undo", function()
        it("writes to a free cell and can be undone", function()
            local b = newBoard()
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if not b:isGiven(rr, cc) then r, c = rr, cc; break end
                end
                if r then break end
            end
            assert.is_true(b:setCell(r, c, 3))
            assert.are.equal(3, b.user[r][c])
            assert.is_true(b:canUndo())
            -- b.undo is the UndoStack instance field, which shadows the
            -- :undo() method on the metatable -- call it unbound.
            assert.is_true(Board.undo(b))
            assert.are.equal(0, b.user[r][c])
        end)

        it("refuses to write to a given cell", function()
            local b = newBoard()
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b:isGiven(rr, cc) then r, c = rr, cc; break end
                end
                if r then break end
            end
            local ok, reason = b:setCell(r, c, 1)
            assert.is_false(ok)
            assert.are.equal("given", reason)
        end)

        it("clearCell resets a cell to 0", function()
            local b = newBoard()
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if not b:isGiven(rr, cc) then r, c = rr, cc; break end
                end
                if r then break end
            end
            b:setCell(r, c, 4)
            assert.is_true(b:clearCell(r, c))
            assert.are.equal(0, b.user[r][c])
        end)
    end)

    describe("isSolved", function()
        it("is false on a fresh puzzle and true once user matches the solution", function()
            local b = newBoard()
            assert.is_false(b:isSolved())
            for r = 1, b.n do
                for c = 1, b.n do
                    b.user[r][c] = b.solution[r][c]
                end
            end
            assert.is_true(b:isSolved())
        end)
    end)

    describe("checkProgress", function()
        it("flags a region whose size doesn't match its value", function()
            local b = newBoard()
            for r = 1, b.n do
                for c = 1, b.n do
                    b.user[r][c] = b.solution[r][c]
                end
            end
            -- Break a size-1 region (a "1" cell) by writing a different digit.
            local r1, c1
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.solution[r][c] == 1 then r1, c1 = r, c; break end
                end
                if r1 then break end
            end
            if r1 then
                b.user[r1][c1] = 2
                b:checkProgress()
                assert.is_true(b.wrong_marks[r1][c1])
            end
        end)
    end)

    describe("serialize / load", function()
        it("round-trips puzzle, solution and given mask", function()
            local b = newBoard()
            local data = b:serialize()

            local b2 = Board:new({ n = 6 })
            assert.is_true(b2:load(data))
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(b.solution[r][c], b2.solution[r][c])
                    assert.are.equal(b.given[r][c], b2.given[r][c])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = newBoard()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
