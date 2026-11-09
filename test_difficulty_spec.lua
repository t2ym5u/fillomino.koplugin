-- Difficulty guarantees for Fillomino (see docs/dev/TESTING.md, "Difficulty
-- specs"). Puzzles are graded by the logic solver's tiers (solver.lua):
-- tier 1 = border/exit/complete/single, tier 2 = + area/bottleneck, tier 3 =
-- + small closed pockets, never trial. Easy = tier 1 with a clue in every
-- region, Medium = tier 2, Hard = tier 3, fewer clues as the level rises.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Fillomino difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    describe("levels (logic solver gate)", function()
        local Solver
        local SEEDS = 10
        local TIER = { easy = 1, medium = 2, hard = 3 }
        local made = {}   -- made[n][seed][level] = { puzzle, solution, givens, ms }

        setup(function()
            Solver = dofile(DIR .. "solver.lua")
            for _, n in ipairs({ 6, 7, 8 }) do
                made[n] = {}
                for seed = 1, SEEDS do
                    made[n][seed] = {}
                    for _, level in ipairs({ "easy", "medium", "hard" }) do
                        math.randomseed(seed * 7919 + n)
                        local b = Board:new({ n = n })
                        local t0 = os.clock()
                        b:generate(level)
                        local ms = (os.clock() - t0) * 1000
                        local givens = 0
                        for r = 1, n do
                            for c = 1, n do
                                if b.puzzle[r][c] > 0 then givens = givens + 1 end
                            end
                        end
                        made[n][seed][level] = { b = b, givens = givens, ms = ms }
                    end
                end
            end
        end)

        local function key(p, n)
            local t = {}
            for r = 1, n do for c = 1, n do t[#t + 1] = p[r][c] end end
            return table.concat(t, ",")
        end

        it("every puzzle is solved by logic alone, within its level, to the solution", function()
            for n, seeds in pairs(made) do
                for seed, levels in pairs(seeds) do
                    for level, m in pairs(levels) do
                        local ok, g = Solver.solve(m.b.puzzle, n, TIER[level])
                        assert.is_true(ok, ("%dx%d %s seed %d not solved"):format(n, n, level, seed))
                        for r = 1, n do
                            for c = 1, n do
                                assert.are.equal(m.b.solution[r][c], g[r][c])
                            end
                        end
                    end
                end
            end
        end)

        it("Easy keeps a clue in every region", function()
            for n, seeds in pairs(made) do
                for _, levels in pairs(seeds) do
                    local b = levels.easy.b
                    local seen = {}
                    for r = 1, n do seen[r] = {} end
                    for r = 1, n do
                        for c = 1, n do
                            if not seen[r][c] then
                                local v, stack, clue = b.solution[r][c], { {r, c} }, false
                                seen[r][c] = true
                                while #stack > 0 do
                                    local cell = table.remove(stack)
                                    if b.puzzle[cell[1]][cell[2]] > 0 then clue = true end
                                    for _, d in ipairs({ {1,0},{-1,0},{0,1},{0,-1} }) do
                                        local nr, nc = cell[1] + d[1], cell[2] + d[2]
                                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                                            and not seen[nr][nc] and b.solution[nr][nc] == v then
                                            seen[nr][nc] = true
                                            stack[#stack + 1] = { nr, nc }
                                        end
                                    end
                                end
                                assert.is_true(clue)
                            end
                        end
                    end
                end
            end
        end)

        it("the same seed gives three different puzzles, fewer clues as the level rises", function()
            for n, seeds in pairs(made) do
                for _, L in pairs(seeds) do
                    assert.is_true(L.easy.givens > L.medium.givens)
                    assert.is_true(L.medium.givens > L.hard.givens)
                    local e, m, h = key(L.easy.b.puzzle, n), key(L.medium.b.puzzle, n), key(L.hard.b.puzzle, n)
                    assert.are_not.equal(e, m)
                    assert.are_not.equal(m, h)
                    assert.are_not.equal(e, h)
                end
            end
        end)

        it("harder levels need harder steps", function()
            for n, seeds in pairs(made) do
                local work = { easy = 0, medium = 0, hard = 0 }
                for _, L in pairs(seeds) do
                    for level, m in pairs(L) do
                        local _, _, stats = Solver.solve(m.b.puzzle, n, 3)
                        work[level] = work[level] + stats.steps.area + stats.steps.bottleneck
                            + stats.steps.pocket
                        if level == "easy" then assert.are.equal(1, stats.tier) end
                    end
                end
                assert.are.equal(0, work.easy)
                assert.is_true(work.medium > 0)
                assert.is_true(work.hard >= work.medium)
            end
        end)

        it("is deterministic: the same seed gives the same puzzle (Daily Challenge)", function()
            for _, n in ipairs({ 6, 8 }) do
                for _, level in ipairs({ "easy", "hard" }) do
                    math.randomseed(3 * 7919 + n)
                    local b = Board:new({ n = n })
                    b:generate(level)
                    assert.are.equal(key(made[n][3][level].b.puzzle, n), key(b.puzzle, n))
                end
            end
        end)

        it("generates in reasonable time (generous bound, Mac)", function()
            for _, seeds in pairs(made) do
                for _, L in pairs(seeds) do
                    for _, m in pairs(L) do assert.is_true(m.ms < 500, m.ms .. " ms") end
                end
            end
        end)

        -- With a clock that jumps 1000 s at every read, a seed still gives
        -- the same puzzle (work is bounded by solver runs only).
        it("generation does not depend on the clock", function()
            local oc, ot = os.clock, os.time
            for _, level in ipairs({ "easy", "medium", "hard" }) do
                math.randomseed(2 * 7919 + 6)
                local b = Board:new({ n = 6 })
                local t = 0
                os.clock = function() t = t + 1000; return t end
                os.time = function(x) if x then return ot(x) end; t = t + 1000; return t end
                local ok, err = pcall(function() b:generate(level) end)
                os.clock, os.time = oc, ot
                assert.is_true(ok, tostring(err))
                assert.are.equal(key(made[6][2][level].b.puzzle, 6), key(b.puzzle, 6))
            end
        end)
    end)

    it("never reads the clock", function()
        local src = assert(io.open(DIR .. "solver.lua")):read("*a")
        assert.is_nil(src:find("os%.clock"))
        assert.is_nil(src:find("os%.time"))
        local bsrc = assert(io.open(DIR .. "board.lua")):read("*a")
        assert.is_nil(bsrc:find("os%.clock"))
        assert.is_nil(bsrc:find("os%.time"))
    end)
end)
