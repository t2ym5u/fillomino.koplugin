local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

local C_BG          = Blitbuffer.COLOR_WHITE
local C_SEL         = Blitbuffer.COLOR_GRAY_C
local C_GIVEN_BG    = Blitbuffer.COLOR_GRAY_D
local C_WRONG_BG    = Blitbuffer.COLOR_GRAY_A
local C_LINE_THIN   = Blitbuffer.COLOR_GRAY_9
local C_LINE        = Blitbuffer.COLOR_BLACK
local C_GIVEN_FG    = Blitbuffer.COLOR_BLACK
local C_USER_FG     = Blitbuffer.COLOR_GRAY_2
local C_THICK_EDGE  = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- FillominoBoardWidget
-- ---------------------------------------------------------------------------

local FillominoBoardWidget = GridWidgetBase:extend{ board = nil }

function FillominoBoardWidget:init()
    local n   = self.board and self.board.n or 6
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
end

function FillominoBoardWidget:onCellTap(row, col)
    if self.onCellSelected then self.onCellSelected(row, col) end
end

function FillominoBoardWidget:setSelected(r, c)
    self.selected = r and c and { r = r, c = c } or nil
end

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function FillominoBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local board  = self.board
    local n      = board.n
    local cell   = self.dimen.w / n
    local thin   = Size.line.thin or 1
    local thick  = math.max(2, math.floor(cell * 0.08))

    -- White background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- -----------------------------------------------------------------------
    -- Cell backgrounds
    -- -----------------------------------------------------------------------
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)

            if board.wrong_marks[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_WRONG_BG)
            elseif board:isGiven(r, c) then
                bb:paintRect(cx, cy, cw, ch, C_GIVEN_BG)
            end

            if self.selected and self.selected.r == r and self.selected.c == c then
                bb:paintRect(cx, cy, cw, ch, C_SEL)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Grid lines: thin interior, thick outer
    -- -----------------------------------------------------------------------
    for i = 1, n - 1 do
        drawLine(bb, x + math.floor(i * cell), y, thin, self.dimen.h, C_LINE_THIN)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, thin, C_LINE_THIN)
    end
    -- Outer border
    drawLine(bb, x,                        y,                        self.dimen.w, thick, C_LINE)
    drawLine(bb, x,                        y + self.dimen.h - thick, self.dimen.w, thick, C_LINE)
    drawLine(bb, x,                        y,                        thick, self.dimen.h, C_LINE)
    drawLine(bb, x + self.dimen.w - thick, y,                        thick, self.dimen.h, C_LINE)

    -- -----------------------------------------------------------------------
    -- Thick borders between cells of different user groups
    -- -----------------------------------------------------------------------
    local half = math.floor(thick / 2)

    -- Vertical internal edges
    for r = 1, n do
        for c = 1, n - 1 do
            local v1 = board.user[r][c]
            local v2 = board.user[r][c + 1]
            -- Draw thick line if they differ or one is 0
            if v1 ~= v2 or v1 == 0 or v2 == 0 then
                local lx = x + math.floor(c * cell) - half
                local ly = y + math.floor((r - 1) * cell)
                drawLine(bb, lx, ly, thick, math.ceil(cell), C_THICK_EDGE)
            end
        end
    end
    -- Horizontal internal edges
    for r = 1, n - 1 do
        for c = 1, n do
            local v1 = board.user[r][c]
            local v2 = board.user[r + 1][c]
            if v1 ~= v2 or v1 == 0 or v2 == 0 then
                local lx = x + math.floor((c - 1) * cell)
                local ly = y + math.floor(r * cell) - half
                drawLine(bb, lx, ly, math.ceil(cell), thick, C_THICK_EDGE)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Numbers
    -- -----------------------------------------------------------------------
    local pad  = self.number_padding or 2
    local cinn = math.max(1, math.floor(cell - 2 * pad))

    for r = 1, n do
        for c = 1, n do
            local v = board.user[r][c]
            if v > 0 then
                local cx    = x + math.floor((c - 1) * cell)
                local cy    = y + math.floor((r - 1) * cell)
                local text  = tostring(v)
                local color = board:isGiven(r, c) and C_GIVEN_FG or C_USER_FG
                local m     = RenderText:sizeUtf8Text(0, cinn, self.number_face, text, true, false)
                local base  = cy + pad + math.floor((cinn + m.y_top - m.y_bottom) / 2)
                local tx    = cx + pad + math.floor((cinn - m.x) / 2)
                RenderText:renderUtf8Text(bb, tx, base, self.number_face, text, true, false, color)
            end
        end
    end
end

return FillominoBoardWidget
