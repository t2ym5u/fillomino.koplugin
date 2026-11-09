local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Fillomino logic solver", function()
    local Solver, Board

    setup(function()
        Solver = dofile(DIR .. "solver.lua")
        Board  = require("board")
    end)

    local function grid(rows)
        local g = {}
        for r, row in ipairs(rows) do
            g[r] = {}
            for c = 1, #row do g[r][c] = tonumber(row:sub(c, c)) end
        end
        return g
    end

    local function same(a, b, n)
        for r = 1, n do
            for c = 1, n do
                if a[r][c] ~= b[r][c] then return false end
            end
        end
        return true
    end

    -- 2 2 1
    -- 3 1 2
    -- 3 3 2
    local SOL = { "221", "312", "332" }

    it("tier 1: single exits grow groups to the end", function()
        local ok, g, stats = Solver.solve(grid{ "201", "310", "002" }, 3, 1)
        assert.is_true(ok)
        assert.is_true(same(g, grid(SOL), 3))
        assert.are.equal(1, stats.tier)
        assert.is_true(stats.steps.exit > 0)
    end)

    it("tier 2: a region with no clue at all, walled in, can only be a 1", function()
        local p = grid{ "221", "302", "332" }
        assert.is_false((Solver.solve(p, 3, 1)))
        local ok, g, stats = Solver.solve(p, 3, 2)
        assert.is_true(ok)
        assert.is_true(same(g, grid(SOL), 3))
        assert.are.equal(2, stats.tier)
        assert.is_true(stats.steps.area > 0)
    end)

    it("tier 3: a closed two-cell pocket can only be one 2-region", function()
        -- 3 3 3
        -- 4 . .   two 1s would touch, a lone cell must be a 1: so 2 2
        -- 4 4 4
        local p = grid{ "333", "400", "444" }
        assert.is_false((Solver.solve(p, 3, 2)))
        local ok, g, stats = Solver.solve(p, 3, 3)
        assert.is_true(ok)
        assert.is_true(same(g, grid{ "333", "422", "444" }, 3))
        assert.are.equal(3, stats.tier)
        assert.is_true(stats.steps.pocket > 0)
    end)

    it("stops early on the watched cell (the generator's quick test)", function()
        local ok = Solver.solve(grid{ "201", "310", "002" }, 3, 1, { 1, 2 })
        assert.are.equal("stopped", ok)
    end)

    it("does not claim to solve an ambiguous grid", function()
        local p = grid{ "0000", "0000", "0000", "0000" }
        local ok, _, stats = Solver.solve(p, 4, 3)
        assert.is_false(ok)
        assert.is_false(stats.broken)
    end)

    it("is sound: on random partial grids every deduction matches the solution", function()
        local solved, wrong, broken = 0, 0, 0
        for it = 1, 150 do
            math.randomseed(it * 31 + 5)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            local sol = b.solution
            local p = {}
            for r = 1, 5 do
                p[r] = {}
                for c = 1, 5 do
                    p[r][c] = (math.random() < 0.35) and 0 or sol[r][c]
                end
            end
            local ok, g, stats = Solver.solve(p, 5, 3)
            if stats.broken then broken = broken + 1 end
            for r = 1, 5 do
                for c = 1, 5 do
                    if g[r][c] ~= 0 and g[r][c] ~= sol[r][c] then wrong = wrong + 1 end
                end
            end
            if ok then solved = solved + 1 end
        end
        assert.are.equal(0, wrong)
        assert.are.equal(0, broken)
        assert.is_true(solved > 20, "solved only " .. solved)
    end)
end)
