-- ---------------------------------------------------------------------------
-- solver.lua -- a human-style Fillomino solver, without trial.
--
-- It never assumes a number to look for a contradiction: every step is a
-- direct deduction from the grid as it stands, the way a player reasons.
-- So a puzzle it fills completely has exactly one solution (every step was
-- forced), even when some regions have no clue at all, and it never needs a
-- guess.
--
-- Steps, by tier (a level allows its tier and below):
--   tier 1
--     border      a cell next to groups of k can't be k when joining them
--                 would make more than k cells (a finished group is closed)
--     exit        an unfinished group with a single free neighbour grows there
--     complete    an unfinished group that can reach exactly as many cells as
--                 it is missing takes them all
--     single      a cell with one possible number left gets it
--   tier 2
--     area        a cell can't be k when no group of k can reach it and no
--                 new region of k fits in the space around it
--     bottleneck  a cell every growth of a group must go through
--   tier 3
--     pocket      a small closed pocket of empty cells that can be filled only
--                 one way
--
-- Solver.solve(puzzle, n, max_tier[, stop_at]) -> solved, grid, stats
--   puzzle: n x n, 0 = empty. grid: the n x n grid as far as it got.
--   stats: { tier = hardest tier used, steps = { name = count },
--   rounds = deduction rounds }. Work is bounded: every round fills a cell
--   or removes a candidate, and the pocket search has a node cap -- the
--   solver never reads the clock.
-- ---------------------------------------------------------------------------

local Solver = {}

local MAXV = 9              -- the keypad's digits
local POCKET_MAX = 4        -- biggest pocket the "pocket" step looks at
local POCKET_NODES = 4000   -- search cap per pocket

Solver.TIERS = {
    border = 1, exit = 1, complete = 1, single = 1,
    area = 2, bottleneck = 2,
    pocket = 3,
}
Solver.STEP_NAMES = { "border", "exit", "complete", "single", "area", "bottleneck", "pocket" }

local nb_cache = {}
local function neighbours(n)
    local nb = nb_cache[n]
    if nb then return nb end
    nb = {}
    for r = 1, n do
        for c = 1, n do
            local i, t = (r - 1) * n + c, {}
            if r > 1 then t[#t + 1] = i - n end
            if r < n then t[#t + 1] = i + n end
            if c > 1 then t[#t + 1] = i - 1 end
            if c < n then t[#t + 1] = i + 1 end
            nb[i] = t
        end
    end
    nb_cache[n] = nb
    return nb
end

-- ---------------------------------------------------------------------------
-- State. cand[(i-1)*MAXV + k]: cell i may still be k. Groups (maximal
-- same-number connected sets of filled cells) are kept up to date on every
-- fill; a group swallowed by a merge is marked dead.
-- ---------------------------------------------------------------------------

local function note(S, name, count)
    S.steps[name] = S.steps[name] + (count or 1)
    local t = Solver.TIERS[name]
    if t > S.tier then S.tier = t end
end

local function removeCand(S, i, k)
    local key = (i - 1) * MAXV + k
    if not S.cand[key] then return false end
    S.cand[key] = false
    S.ncand[i] = S.ncand[i] - 1
    local ver = S.version + 1
    S.version = ver
    S.changed[i] = ver
    S.kdirty[k] = ver
    if S.ncand[i] == 0 then S.broken = true end
    return true
end

-- border, for one cell and one number: 1 + the distinct live groups of k
-- around it must not exceed k.
local function borderCheck(S, u, k)
    if not S.cand[(u - 1) * MAXV + k] then return 0 end
    local val, gid, groups, nx = S.val, S.gid, S.groups, S.nb[u]
    local sum, g1, g2, g3 = 1, 0, 0, 0
    for j = 1, #nx do
        local y = nx[j]
        if val[y] == k then
            local g = gid[y]
            if g ~= g1 and g ~= g2 and g ~= g3 then
                sum = sum + groups[g].size
                if g1 == 0 then g1 = g elseif g2 == 0 then g2 = g else g3 = g end
            end
        end
    end
    if sum > k then
        removeCand(S, u, k)
        return 1
    end
    return 0
end

-- Fill cell i with k: merge the groups it joins, then re-check the border
-- rule around the grown group. Returns true if the cell was empty.
local function assign(S, i, k)
    local val = S.val
    if val[i] ~= 0 then
        if val[i] ~= k then S.broken = true end
        return false
    end
    if not S.cand[(i - 1) * MAXV + k] then S.broken = true; return false end
    val[i] = k
    S.empty = S.empty - 1
    local ver = S.version + 1
    S.version = ver
    S.changed[i] = ver
    S.last_assign = ver
    local gid, groups, nb = S.gid, S.groups, S.nb
    local id = #groups + 1
    local G = { v = k, cells = { i }, size = 1 }
    groups[id] = G
    gid[i] = id
    local nx = nb[i]
    for j = 1, #nx do
        local y = nx[j]
        if val[y] == k and gid[y] ~= id then
            local H = groups[gid[y]]
            H.dead = true
            for _, x in ipairs(H.cells) do
                gid[x] = id
                G.cells[#G.cells + 1] = x
            end
        end
    end
    G.size = #G.cells
    if G.size > k then S.broken = true; return true end
    local count = 0
    for _, x in ipairs(G.cells) do
        local nx2 = nb[x]
        for j = 1, #nx2 do
            local u = nx2[j]
            if val[u] == 0 then count = count + borderCheck(S, u, k) end
        end
    end
    if count > 0 then note(S, "border", count) end
    return true
end

-- The state's arrays are reused from one solve to the next (the generator
-- runs the solver dozens of times per puzzle; fresh tables each time mostly
-- fed the garbage collector).
local spare = {}

local function newState(puzzle, n)
    local N = n * n
    local S = spare[n]
    if not S then
        S = {
            n = n, N = N, nb = neighbours(n),
            val = {}, cand = {}, ncand = {}, gid = {},
            mark = {}, depth = {}, parent = {}, sub = {},
            changed = {}, kdirty = {}, area_done = {},
        }
        spare[n] = S
    end
    S.groups = {}
    S.stamp, S.empty = 0, 0
    -- change stamps: a step skips what hasn't changed since it last looked
    -- (it would find nothing new there)
    S.version, S.last_assign = 0, 0
    S.steps, S.tier, S.broken = {}, 0, false
    for _, name in ipairs(Solver.STEP_NAMES) do S.steps[name] = 0 end
    for k = 1, MAXV do S.kdirty[k] = 0; S.area_done[k] = -1 end
    local top = math.min(MAXV, N)
    for i = 1, N do
        S.val[i] = 0
        S.gid[i] = 0
        S.mark[i] = 0
        S.depth[i] = 0
        S.changed[i] = 0
        local base = (i - 1) * MAXV
        for k = 1, MAXV do S.cand[base + k] = (k <= top) end
        S.ncand[i] = top
    end
    -- Givens: fill, group, then one border pass (cheaper than assign()
    -- one by one).
    local val, gid, groups, nb = S.val, S.gid, S.groups, S.nb
    local empty = 0
    for r = 1, n do
        local row = puzzle[r]
        for c = 1, n do
            local v = row[c] or 0
            if v > top then S.broken = true; v = 0 end
            val[(r - 1) * n + c] = v
            if v == 0 then empty = empty + 1 end
        end
    end
    S.empty = empty
    for i = 1, N do
        if val[i] > 0 and gid[i] == 0 then
            local id, v = #groups + 1, val[i]
            local cells, h = { i }, 1
            gid[i] = id
            while h <= #cells do
                local x = cells[h]; h = h + 1
                local nx = nb[x]
                for j = 1, #nx do
                    local y = nx[j]
                    if gid[y] == 0 and val[y] == v then
                        gid[y] = id
                        cells[#cells + 1] = y
                    end
                end
            end
            if #cells > v then S.broken = true end
            groups[id] = { v = v, cells = cells, size = #cells }
        end
    end
    for i = 1, N do
        if val[i] == 0 then
            local nx = nb[i]
            for j = 1, #nx do
                local k = val[nx[j]]
                if k > 0 then borderCheck(S, i, k) end
            end
        end
    end
    -- The givens' border eliminations are part of reading the grid, not
    -- steps of the solve.
    S.steps.border = 0
    S.tier = 0
    return S
end

local function newStamp(S)
    S.stamp = S.stamp + 1
    return S.stamp
end

-- Cells an unfinished group could still grow into: breadth-first through
-- cells that may hold its number, no farther than the cells it is missing.
-- `skip` (optional) is a cell treated as closed. Returns the list (group
-- cells excluded) and how many free cells touch the group (its exits).
local function reach(S, G, skip)
    local val, nb, mark, depth, cand = S.val, S.nb, S.mark, S.depth, S.cand
    local parent = S.parent
    local v, need = G.v, G.v - G.size
    local st = newStamp(S)
    local queue = {}
    local cells = G.cells
    for q = 1, #cells do
        local x = cells[q]
        mark[x] = st; depth[x] = 0; queue[q] = x
    end
    local out, exits, h = {}, 0, 1
    while h <= #queue do
        local x = queue[h]; h = h + 1
        local d = depth[x]
        if d < need then
            local nx = nb[x]
            for j = 1, #nx do
                local y = nx[j]
                if mark[y] ~= st and y ~= skip then
                    local vy = val[y]
                    if (vy == 0 and cand[(y - 1) * MAXV + v]) or vy == v then
                        mark[y] = st; depth[y] = d + 1; parent[y] = x
                        queue[#queue + 1] = y
                        out[#out + 1] = y
                        if d == 0 and vy == 0 then exits = exits + 1 end
                    end
                end
            end
        end
    end
    return out, exits
end

-- A group's reach only shrinks, and only when one of its cells changes:
-- `zoneSince` tells whether any cell of the stored reach changed after `ver`.
local function zoneSince(S, zone, ver)
    local changed = S.changed
    for q = 1, #zone do
        if changed[zone[q]] > ver then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Tier 1
-- ---------------------------------------------------------------------------

-- exit / complete, over every live unfinished group (groups created by the
-- fills of this pass are visited too).
local function stepGroups(S)
    local groups = S.groups
    local progress = false
    local g = 1
    while g <= #groups do
        local G = groups[g]
        if not G.dead and G.size < G.v
            and (not G.zone or zoneSince(S, G.zone, G.zone_ver)) then
            local ver = S.version
            local out, exits = reach(S, G)
            G.zone, G.zone_ver = out, ver
            if exits == 0 or G.size + #out < G.v then S.broken = true; return false end
            if exits == 1 then
                for _, y in ipairs(out) do
                    if S.depth[y] == 1 and S.val[y] == 0 then
                        assign(S, y, G.v)
                        note(S, "exit", 1)
                        progress = true
                        break
                    end
                end
            elseif G.size + #out == G.v then
                local placed = 0
                for _, y in ipairs(out) do
                    if assign(S, y, G.v) then placed = placed + 1 end
                end
                note(S, "complete", placed)
                progress = true
            end
            if S.broken then return false end
        end
        g = g + 1
    end
    return progress
end

local function stepSingle(S)
    local placed = 0
    local val, ncand, cand = S.val, S.ncand, S.cand
    for i = 1, S.N do
        if val[i] == 0 and ncand[i] == 1 then
            local base = (i - 1) * MAXV
            for k = 1, MAXV do
                if cand[base + k] then
                    if assign(S, i, k) then placed = placed + 1 end
                    break
                end
            end
            if S.broken then return false end
        end
    end
    if placed > 0 then note(S, "single", placed) end
    return placed > 0
end

-- ---------------------------------------------------------------------------
-- Tier 2
-- ---------------------------------------------------------------------------

-- area: cell i keeps k only if a group of k can still reach it, or a
-- brand-new region of k fits around it. A new region holds no filled cell,
-- so it only uses "clean" cells: empty, allowing k, touching no filled k.
-- One labelling of the clean cells per k: a clean patch smaller than k
-- can't hold a new region of k.
local function stepArea(S)
    local val, nb, N, cand, mark = S.val, S.nb, S.N, S.cand, S.mark
    local todo, reachable = {}, {}
    for k = 2, MAXV do
        local done = S.area_done[k]
        todo[k] = done < S.kdirty[k] or done < S.last_assign
        reachable[k] = {}
    end
    for _, G in ipairs(S.groups) do
        if not G.dead and G.size < G.v and todo[G.v] then
            -- stepGroups has just looked at every group: its stored reach
            -- is current (recomputed, or nothing in it changed since)
            local out = G.zone or reach(S, G)
            local t = reachable[G.v]
            for _, y in ipairs(out) do t[y] = true end
        end
    end
    local count = 0
    for k = 2, MAXV do
      if todo[k] then
        S.area_done[k] = S.version
        local reach_k = reachable[k]
        local clean = newStamp(S)
        for i = 1, N do
            if val[i] == 0 and cand[(i - 1) * MAXV + k] then
                local ok = true
                local nx = nb[i]
                for j = 1, #nx do
                    if val[nx[j]] == k then ok = false; break end
                end
                if ok then mark[i] = clean end
            end
        end
        local seen = newStamp(S)
        for i = 1, N do
            if val[i] == 0 and cand[(i - 1) * MAXV + k] and mark[i] ~= seen then
                if mark[i] == clean then
                    mark[i] = seen
                    local queue, h = { i }, 1
                    while h <= #queue do
                        local x = queue[h]; h = h + 1
                        local nx = nb[x]
                        for j = 1, #nx do
                            local y = nx[j]
                            if mark[y] == clean then
                                mark[y] = seen
                                queue[#queue + 1] = y
                            end
                        end
                    end
                    if #queue < k then
                        for q = 1, #queue do
                            local x = queue[q]
                            if not reach_k[x] and removeCand(S, x, k) then
                                count = count + 1
                            end
                        end
                    end
                elseif not reach_k[i] then
                    -- touches a filled k that can't take it in
                    if removeCand(S, i, k) then count = count + 1 end
                end
            end
        end
      end
    end
    if count > 0 then note(S, "area", count) end
    return count > 0
end

local function stepBottleneck(S)
    for _, G in ipairs(S.groups) do
        if not G.dead and G.size < G.v
            and (not G.bn_zone or zoneSince(S, G.bn_zone, G.bn_ver)) then
            local ver = S.version
            local out = reach(S, G)
            G.bn_zone, G.bn_ver = out, ver
            -- Closing x cuts off at most x's subtree in the search tree
            -- (any other cell keeps its shortest path): only cells whose
            -- subtree outweighs the group's spare room are worth a look.
            local sub, parent = S.sub, S.parent
            for q = 1, #out do sub[out[q]] = 1 end
            for q = #out, 1, -1 do
                local x = out[q]
                local p = parent[x]
                if S.depth[p] > 0 then sub[p] = sub[p] + sub[x] end
            end
            local spare = G.size + #out - G.v
            for _, x in ipairs(out) do
                if S.val[x] == 0 and sub[x] > spare then
                    local out2 = reach(S, G, x)
                    if G.size + #out2 < G.v then
                        assign(S, x, G.v)
                        note(S, "bottleneck", 1)
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Tier 3
-- ---------------------------------------------------------------------------

-- A pocket: a connected set of empty cells, small, such that every unfinished
-- group touching it has no free neighbour outside it -- filling the pocket
-- then settles every region around it, so the ways to fill it can be listed.
local function solvePocket(S, P, inP)
    local val, nb, gid, groups = S.val, S.nb, S.gid, S.groups
    local around, seen = {}, {}
    for _, x in ipairs(P) do
        for _, y in ipairs(nb[x]) do
            local g = gid[y]
            if val[y] ~= 0 and not seen[g] then
                seen[g] = true
                around[#around + 1] = groups[g]
            end
        end
    end
    for _, G in ipairs(around) do
        if G.size < G.v then
            for _, x in ipairs(G.cells) do
                for _, y in ipairs(nb[x]) do
                    if val[y] == 0 and not inP[y] then return false end
                end
            end
        end
    end

    local m = #P
    local agree, found, nodes = {}, 0, 0
    -- Every region touching the pocket must come out exactly its size.
    local function valid()
        local st = newStamp(S)
        local mark = S.mark
        local starts = {}
        for _, x in ipairs(P) do starts[#starts + 1] = x end
        for _, G in ipairs(around) do starts[#starts + 1] = G.cells[1] end
        for _, s in ipairs(starts) do
            if mark[s] ~= st then
                local v = val[s]
                mark[s] = st
                local queue, h = { s }, 1
                while h <= #queue do
                    local x = queue[h]; h = h + 1
                    for _, y in ipairs(nb[x]) do
                        if mark[y] ~= st and val[y] == v then
                            mark[y] = st
                            queue[#queue + 1] = y
                            if #queue > v then return false end
                        end
                    end
                end
                if #queue ~= v then return false end
            end
        end
        return true
    end
    local function rec(idx)
        nodes = nodes + 1
        if nodes > POCKET_NODES then found = -1; return end
        if idx > m then
            if valid() then
                found = found + 1
                for j = 1, m do
                    local v = val[P[j]]
                    if found == 1 then agree[j] = v
                    elseif agree[j] ~= v then agree[j] = 0 end
                end
            end
            return
        end
        local x = P[idx]
        local base = (x - 1) * MAXV
        for k = 1, MAXV do
            if S.cand[base + k] then
                val[x] = k
                rec(idx + 1)
                val[x] = 0
                if found < 0 then return end
            end
        end
    end
    rec(1)
    for j = 1, m do val[P[j]] = 0 end
    if found < 0 then return false end
    if found == 0 then S.broken = true; return false end
    local placed = 0
    for j = 1, m do
        if agree[j] > 0 and assign(S, P[j], agree[j]) then placed = placed + 1 end
    end
    if placed > 0 then note(S, "pocket", placed) end
    return placed > 0
end

local function stepPocket(S)
    local val, nb = S.val, S.nb
    local done = {}
    for i = 1, S.N do
        if val[i] == 0 and not done[i] then
            local P, inP, h = { i }, { [i] = true }, 1
            done[i] = true
            while h <= #P do
                local x = P[h]; h = h + 1
                for _, y in ipairs(nb[x]) do
                    if val[y] == 0 and not inP[y] then
                        inP[y] = true; done[y] = true
                        P[#P + 1] = y
                    end
                end
            end
            if #P <= POCKET_MAX and solvePocket(S, P, inP) then return true end
            if S.broken then return false end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------

-- `stop_at` (optional, {r, c}): return as soon as that cell is filled, with
-- solved = "stopped" -- the generator's quick test of a hide (see board.lua).
function Solver.solve(puzzle, n, max_tier, stop_at)
    max_tier = max_tier or 3
    local S = newState(puzzle, n)
    local rounds = 0
    local stop_i = stop_at and (stop_at[1] - 1) * n + stop_at[2]
    while not S.broken and S.empty > 0 do
        if stop_i and S.val[stop_i] ~= 0 then return "stopped" end
        rounds = rounds + 1
        local progress = stepGroups(S)
        if not progress and not S.broken then progress = stepSingle(S) end
        if not progress and not S.broken and max_tier >= 2 then
            progress = stepArea(S)
            if not progress and not S.broken then progress = stepBottleneck(S) end
        end
        if not progress and not S.broken and max_tier >= 3 then
            progress = stepPocket(S)
        end
        if not progress then break end
    end
    local solved = not S.broken and S.empty == 0
    if solved then
        for _, G in ipairs(S.groups) do
            if not G.dead and G.size ~= G.v then solved = false; break end
        end
    end
    local grid = {}
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do grid[r][c] = S.val[(r - 1) * n + c] end
    end
    return solved, grid, { tier = S.tier, steps = S.steps, rounds = rounds, broken = S.broken }
end

return Solver
