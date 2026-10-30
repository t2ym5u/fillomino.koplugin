local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

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

Tap a cell to select it, then tap a digit button to fill it in. Tap the same digit again to erase.
]])

local GAME_RULES_FR = [[
Fillomino — Règles

Remplissez chaque case de la grille avec un chiffre de sorte que chaque groupe de cases orthogonalement connectées partageant le même chiffre contienne exactement ce nombre de cases.

Règles :
• Les chiffres indices sont fixes et ne peuvent pas être modifiés.
• Deux groupes portant le même chiffre ne doivent pas se toucher orthogonalement (le contact en diagonale est autorisé).
• Il n'y a pas de limite au nombre de groupes d'un même chiffre.

Exemple : un groupe de cases contenant toutes le chiffre 3 doit être composé d'exactement 3 cases orthogonalement connectées.

Appuyez sur une case pour la sélectionner, puis sur un chiffre pour la remplir. Appuyez à nouveau sur le même chiffre pour effacer.
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
    local is_landscape = self:isLandscape()

    -- Title bar with Options menu
    local title_bar = self:buildTitleBar(_("Fillomino"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Digit pad 1..9
    local keys = {}
    for d = 1, MAX_DIGIT do
        local dv = d
        keys[#keys + 1] = { id = "digit_" .. d, text = tostring(d),
                            callback = function() self:onDigit(dv) end }
    end
    local number_pad = self:buildNumberPad(keys)
    self.digit_button_refs = {}
    for d = 1, MAX_DIGIT do
        self.digit_button_refs[d] = number_pad:getButtonById("digit_" .. d)
    end

    -- Bottom bar
    local action_bar = self:buildActionBar({
        { text = _("Check"), callback = function() self:onCheck() end },
        { text = _("Hint"),  callback = function() self:onHint() end },
        { text = _("Erase"), callback = function() self:onErase() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    self:_updateUndoButton()

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        number_pad,
        VerticalSpan:new{ width = Size.span.vertical_default },
        action_bar,
    }

    -- The widget draws its own outer border, so the frame only pads.
    local frame_pad = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = FillominoBoardWidget:new{
        max_size       = math.min(budget_w, budget_h) - 2 * frame_pad,
        board          = self.board,
        onCellSelected = function(r, c) self:onCellSelected(r, c) end,
    }
    if self.selected then
        self.board_widget:setSelected(self.selected.r, self.selected.c)
    end
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
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
    -- board.undo is the UndoStack field, which shadows the :undo() method.
    local ok, msg = FillominoBoard.undo(self.board)
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

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function FillominoScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
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
        status = self:joinStatus(T("%1×%2", self.board.n, self.board.n), label, T(_("Empty: %1"), remaining))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends with a status update, so this
    -- is where the bar learns that the round ended (or was undone).
    self:refreshActionBar()
end

function FillominoScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function FillominoScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "medium")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

function FillominoScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

function FillominoScreen:isRoundOver()
    return self.board:isSolved()
end

return FillominoScreen
