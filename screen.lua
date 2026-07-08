local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase          = require("screen_base")
local MenuHelper          = require("menu_helper")
local FillominoBoard      = lrequire("board")
local FillominoBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

local GRID_SIZES   = { 6, 7, 8 }
local MAX_DIGIT    = 9

-- ---------------------------------------------------------------------------
-- FillominoScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Fillomino — Rules

Fill every cell of the grid with a number so that each group of orthogonally connected cells sharing the same number contains exactly that many cells.

Rules:
• Given clue numbers are fixed and cannot be changed.
• Any two groups of the same number must not touch each other orthogonally (they may touch diagonally).
• There is no limit on how many groups of any given number can exist.

Example: a group of cells all containing 3 must consist of exactly 3 orthogonally connected cells.
]])

local GAME_RULES_FR = [[
Fillomino — Règles

Remplissez chaque case de la grille avec un chiffre de sorte que chaque groupe de cases orthogonalement connectées partageant le même chiffre contienne exactement ce nombre de cases.

Règles :
• Les chiffres indices sont fixes et ne peuvent pas être modifiés.
• Deux groupes portant le même chiffre ne doivent pas se toucher orthogonalement (le contact en diagonale est autorisé).
• Il n'y a pas de limite au nombre de groupes d'un même chiffre.

Exemple : un groupe de cases contenant toutes le chiffre 3 doit être composé d'exactement 3 cases orthogonalement connectées.
]]

local FillominoScreen = ScreenBase:extend{}

function FillominoScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 6)
    self.board  = FillominoBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "medium"))
    end
    self.selected = self.board.selected
    ScreenBase.init(self)
end

function FillominoScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function FillominoScreen:buildLayout()
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = FillominoBoardWidget:new{
        board          = self.board,
        onCellSelected = function(r, c) self:onCellSelected(r, c) end,
    }
    if self.selected then
        self.board_widget:setSelected(self.selected.r, self.selected.c)
    end

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    -- Top bar
    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("New game"), callback = function() self:onNewGame() end },
            { id = "grid_button",   text = self:getGridButtonText(),
              callback = function() self:openGridMenu() end },
            { id = "diff_button",   text = self:getDiffButtonText(),
              callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
            self:makeCloseButtonConfig(),
        }},
    }
    self.grid_button = top_buttons:getButtonById("grid_button")
    self.diff_button = top_buttons:getButtonById("diff_button")

    -- Digit buttons 1..9
    local digit_row = {}
    for d = 1, MAX_DIGIT do
        local dv = d
        digit_row[#digit_row + 1] = {
            id       = "digit_" .. dv,
            text     = tostring(dv),
            callback = function() self:onDigit(dv) end,
        }
    end
    local digit_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = { digit_row },
    }

    -- Bottom bar
    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("Check"), callback = function() self:onCheck() end },
            { text = _("Erase"), callback = function() self:onErase() end },
            { id = "undo_button", text = _("Undo"),
              callback = function() self:onUndo() end },
            { text = _("Rules"),  callback = function() self:showRulesHint() end },
        }},
    }
    self.undo_button = bottom_buttons:getButtonById("undo_button")
    self:_updateUndoButton()

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function FillominoScreen:onCellSelected(r, c)
    self.selected = { r = r, c = c }
    self.board:selectCell(r, c)
    self.board_widget:setSelected(r, c)
    self.board_widget:refresh()
    self:updateStatus()
end

function FillominoScreen:onDigit(d)
    if not self.selected then return end
    local r, c = self.selected.r, self.selected.c
    -- Toggle: if same value already set, erase it
    local cur = self.board.user[r][c]
    local new_val = (cur == d) and 0 or d
    local ok, err = self.board:setCell(r, c, new_val)
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus(self.board:isSolved() and _("Congratulations! Puzzle solved!") or nil)
    else
        if err == "given" then
            self:updateStatus(_("Cannot edit a given cell."))
        end
    end
end

function FillominoScreen:onErase()
    if not self.selected then return end
    local r, c = self.selected.r, self.selected.c
    local ok, err = self.board:clearCell(r, c)
    if err == "given" then
        self:updateStatus(_("Cannot edit a given cell."))
        return
    end
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
    end
    self.board_widget:refresh()
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function FillominoScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "medium")
    local n    = self.plugin:getSetting("grid_n", 6)
    self.board = FillominoBoard:new{ n = n }
    self.board:generate(diff)
    self.selected = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function FillominoScreen:onUndo()
    local ok, msg = self.board:undo()
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
end

function FillominoScreen:onCheck()
    self.board:checkProgress()
    self.board_widget:refresh()
    if self.board:isSolved() then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    else
        local remaining = self.board:getRemainingCells()
        self:updateStatus(T(_("Check done. Empty cells: %1"), remaining))
    end
end

function FillominoScreen:showRulesHint()
    if _.lang() == "fr" then
        self:showMessage(
            "Remplissez chaque case avec un chiffre de 1 à 9.\n" ..
            "Les cases portant le même chiffre forment des groupes connectés\n" ..
            "d'exactement ce nombre de cases.\n" ..
            "Deux groupes de même taille ne peuvent pas être adjacents.\n\n" ..
            "Appuyez sur une case pour la sélectionner, puis sur un chiffre.\n" ..
            "Appuyez sur le même chiffre pour effacer."
        , 8)
    else
        self:showMessage(_(
            "Fill every cell with a number 1-9.\n" ..
            "Cells with the same number form connected groups\n" ..
            "of exactly that many cells.\n" ..
            "No two groups of the same size may be adjacent.\n\n" ..
            "Tap a cell to select, then tap a digit button.\n" ..
            "Tap the same digit to erase."
        ), 8)
    end
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function FillominoScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 6),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function FillominoScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function FillominoScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isSolved() then
        status = _("Congratulations! Puzzle solved!")
    else
        local remaining = self.board:getRemainingCells()
        local diff      = self.plugin:getSetting("difficulty", "medium")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Empty: %4"),
            self.board.n, self.board.n, label, remaining)
    end
    ScreenBase.updateStatus(self, status)
end

function FillominoScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function FillominoScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "medium")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function FillominoScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return FillominoScreen
