local directory = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY = "gray" }
end
local Toolbar = dofile(directory .. "/../scribeink.koplugin/toolbar.lua")
local checks = 0
local function check(condition, message)
    checks = checks + 1; assert(condition, message)
end
local screen = { width = 600, height = 800, scale = 1,
    getWidth = function(self) return self.width end,
    getHeight = function(self) return self.height end,
    scaleBySize = function(self, size) return size * self.scale end }
local dock = Toolbar.new{screen=screen}
local rect = dock:getRect()
check(rect.x == 8 and rect.w == 42 and rect.h == 252, "compact expanded dimensions")
check(rect.y + 21 == 200, "handle centered at quarter screen")
for _, action in ipairs{"collapse","pen","eraser","undo","export","menu"} do
    local cell = dock:getButtonRect(action)
    check(dock:hitTest(cell.x + cell.w / 2, cell.y + cell.h / 2) == action, "hit " .. action)
end
check(dock:hitTest(rect.x - 1, rect.y) == nil, "outside left")
check(dock:hitTest(rect.x + rect.w, rect.y) == nil, "right edge is outside")
check(dock:hitTest(rect.x, rect.y + rect.h) == nil, "bottom edge is outside")
check(dock:hitTest(400, rect.y + 50) == nil, "page beside dock remains available")
check(dock:hitTest(rect.x + 10, rect.y + rect.h + 20) == nil, "page below dock remains available")

local function paint(toolbar, offset_x, offset_y)
    local dock_rect = toolbar:getRect()
    offset_x, offset_y = offset_x or 0, offset_y or 0
    local pixels = {}
    local bb = { paintRect = function(_, x, y, w, h, color)
        check(w > 0 and h > 0 and x == math.floor(x) and y == math.floor(y), "integer native spans")
        check(x >= dock_rect.x + offset_x and y >= dock_rect.y + offset_y
            and x + w <= dock_rect.x + dock_rect.w + offset_x
            and y + h <= dock_rect.y + dock_rect.h + offset_y, "paint stays inside dock")
        for py = y, y + h - 1 do
            pixels[py] = pixels[py] or {}
            for px = x, x + w - 1 do pixels[py][px] = color end
        end
    end }
    toolbar:paintTo(bb, offset_x, offset_y)
    return pixels
end

dock:update("pen", {writing=true})
local pixels = paint(dock)
local pen = dock:getButtonRect("pen")
check(pixels[pen.y + 3][pen.x + 3] == "black", "selected pen dark background")
local eraser = dock:getButtonRect("eraser")
check(pixels[eraser.y + 3][eraser.x + 3] == "white", "other tool white background")
dock:update("eraser", {writing=true,can_undo=false})
pixels = paint(dock, 3, 5)
check(pixels[eraser.y + 8][eraser.x + 6] == "black", "selected eraser dark background")
dock:update("pen", {writing=false})
pixels = paint(dock)
check(pixels[pen.y + 3][pen.x + 3] == "white", "reading has no active tool")

local old_top = rect.y
check(dock:toggleCollapsed(), "collapse toggle returns state")
rect = dock:getRect()
check(rect.w == 28 and rect.h == 40 and math.abs(rect.y - old_top) <= 1, "collapsed handle stays in place")
check(dock:hitTest(rect.x + 3, rect.y + 3) == "collapse", "collapsed handle expands")
check(dock:getButtonRect("pen") == nil, "collapsed tools not hittable")
check(dock:hitTest(rect.x + 3, rect.y + 50) == nil, "collapsed lower area available")
paint(dock)
dock:setCollapsed(false)
check(dock:getRect().h == 252, "expanded restore")
screen.width, screen.height, screen.scale = 1860,2480,1.875
rect = dock:getRect()
check(rect.x == 15 and rect.w == 79 and rect.h == 474, "Scribe DPI scales compact controls")
check(rect.x + rect.w < screen.width * 0.06, "dock remains narrow on Scribe")
paint(dock)
screen.width, screen.height, screen.scale = 800,600,1
rect = dock:getRect()
check(rect.y >= 0 and rect.y + rect.h <= screen.height, "landscape dock stays visible")
paint(dock)
print("Toolbar: " .. checks .. " checks passed")
return checks
