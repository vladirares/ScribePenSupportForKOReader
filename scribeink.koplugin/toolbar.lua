-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Compact floating dock. Icons use native rectangle spans, with no fonts or SVG caches.
local Blitbuffer = require("ffi/blitbuffer")
local directory = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
local Render = dofile(directory .. "/render.lua")
local Toolbar = {}
Toolbar.__index = Toolbar
local actions = { "collapse", "pen", "eraser", "undo", "export", "menu" }
local floor, min, max = math.floor, math.min, math.max

function Toolbar.new(options)
    options = options or {}
    assert(options.screen, "Toolbar.new requires screen")
    return setmetatable({ screen = options.screen, collapsed = options.collapsed == true,
        selected_tool = "pen", state = {} }, Toolbar)
end

local function scaled(self, pixels)
    return max(1, floor(self.screen:scaleBySize(pixels) + 0.5))
end

function Toolbar:layout()
    local width, height = self.screen:getWidth(), self.screen:getHeight()
    local margin = min(scaled(self, 8), floor(min(width, height) / 4))
    local cell = max(1, min(scaled(self, 42), floor((height - margin * 2) / #actions)))
    local expanded_width = max(1, min(scaled(self, 42), width - margin * 2))
    local expanded_height = cell * #actions
    local top = max(margin, min(floor(height * 0.25 - cell / 2 + 0.5), height - margin - expanded_height))
    if self.collapsed then
        local handle_width = max(1, min(scaled(self, 28), width - margin * 2))
        local handle_height = max(1, min(scaled(self, 40), height - margin * 2))
        top = max(margin, min(floor(top + (cell - handle_height) / 2), height - margin - handle_height))
        return { x = margin, y = top, w = handle_width, h = handle_height }, handle_height
    end
    return { x = margin, y = top, w = expanded_width, h = expanded_height }, cell
end

function Toolbar:getRect()
    local rect = self:layout()
    return rect
end

function Toolbar:getButtonRect(action)
    local rect, cell = self:layout()
    if self.collapsed then return action == "collapse" and rect or nil end
    for index, name in ipairs(actions) do
        if name == action then return { x = rect.x, y = rect.y + (index - 1) * cell, w = rect.w, h = cell } end
    end
end

function Toolbar:hitTest(x, y)
    local rect, cell = self:layout()
    if x < rect.x or x >= rect.x + rect.w or y < rect.y or y >= rect.y + rect.h then return nil end
    if self.collapsed then return "collapse" end
    return actions[floor((y - rect.y) / cell) + 1]
end

function Toolbar:setCollapsed(collapsed)
    self.collapsed = collapsed == true
end

function Toolbar:toggleCollapsed()
    self.collapsed = not self.collapsed
    return self.collapsed
end

-- state: writing, calibration (optional table with index), eraser_test, can_undo.
function Toolbar:update(selected_tool, state)
    self.selected_tool = selected_tool == "eraser" and "eraser" or "pen"
    self.state = state or {}
end

local function icon(self, bb, action, rect, color)
    local size = max(4, min(scaled(self, 24), rect.w - scaled(self, 10), rect.h - scaled(self, 10)))
    local ox, oy = rect.x + floor((rect.w - size) / 2), rect.y + floor((rect.h - size) / 2)
    local factor = size / 24
    local thickness = max(1, size / 14)
    local function point(x, y) return { x = ox + x * factor, y = oy + y * factor } end
    local function line(x1, y1, x2, y2)
        Render.line(bb, point(x1, y1), point(x2, y2), thickness, color, rect)
    end
    local function path(vertices)
        for index = 2, #vertices do
            line(vertices[index - 1][1], vertices[index - 1][2], vertices[index][1], vertices[index][2])
        end
    end
    if action == "collapse" then
        if self.collapsed then path{{9,5},{16,12},{9,19}}
        else path{{15,5},{8,12},{15,19}} end
    elseif action == "pen" then
        path{{5,20},{8,12},{18,2},{22,6},{12,16},{5,20}}
        line(8,12,12,16)
        line(16,4,20,8)
    elseif action == "eraser" then
        path{{4,16},{11,5},{21,11},{14,22},{10,22},{4,16}}
        line(8,10,18,16)
        line(4,22,21,22)
    elseif action == "undo" then
        path{{4,11},{10,8},{16,9},{20,13},{20,18},{17,21},{12,22}}
        path{{8,5},{3,11},{10,12}}
    elseif action == "export" then
        line(12,3,12,16)
        path{{7,8},{12,3},{17,8}}
        path{{5,14},{5,21},{19,21},{19,14}}
    elseif action == "menu" then
        line(4,6,20,6); line(4,12,20,12); line(4,18,20,18)
    end
end

function Toolbar:paintTo(bb, x, y)
    x, y = x or 0, y or 0
    local rect, cell = self:layout()
    rect.x, rect.y = rect.x + x, rect.y + y
    local black, white = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local gray = Blitbuffer.COLOR_GRAY or black
    local border = scaled(self, 1)
    bb:paintRect(rect.x, rect.y, rect.w, rect.h, white)
    bb:paintRect(rect.x, rect.y, rect.w, border, black)
    bb:paintRect(rect.x, rect.y + rect.h - border, rect.w, border, black)
    bb:paintRect(rect.x, rect.y, border, rect.h, black)
    bb:paintRect(rect.x + rect.w - border, rect.y, border, rect.h, black)
    local count = self.collapsed and 1 or #actions
    for index = 1, count do
        local action = actions[index]
        local button = { x = rect.x + border, y = rect.y + (index - 1) * cell + border,
            w = rect.w - border * 2, h = cell - border * 2 }
        local active = self.state.writing and action == self.selected_tool
        local color = black
        if active then
            bb:paintRect(button.x, button.y, button.w, button.h, black)
            color = white
        elseif (action == "undo" and self.state.can_undo == false)
            or ((action == "undo" or action == "export") and (self.state.calibration or self.state.eraser_test)) then
            color = gray
        end
        icon(self, bb, action, button, color)
        if not self.collapsed and (index == 1 or index == 3 or index == 5) then
            bb:paintRect(rect.x + border, rect.y + index * cell - border,
                rect.w - border * 2, border, gray)
        end
    end
end

function Toolbar:free() end

return Toolbar
