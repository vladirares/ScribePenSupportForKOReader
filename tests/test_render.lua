-- Independent pixel-distance checks for clipped capsule rendering.
local directory = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
local Render = dofile(directory .. "/../scribeink.koplugin/render.lua")

local function expectedHit(x, y, a, b, width)
    local ax, ay = math.floor(a.x + 0.5), math.floor(a.y + 0.5)
    local bx, by = math.floor(b.x + 0.5), math.floor(b.y + 0.5)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 == 0 and 0 or ((x - ax) * dx + (y - ay) * dy) / len2
    t = math.max(0, math.min(1, t))
    local px, py = x - ax - t * dx, y - ay - t * dy
    local r = math.max(1, math.floor(width / 2 + 0.5))
    return px * px + py * py <= r * r + 1e-8
end

local function buffer(clip)
    return { pixels = {}, calls = 0, paintRect = function(self, x, y, w, h)
        assert(x == math.floor(x) and y == math.floor(y) and w == math.floor(w) and h == math.floor(h))
        assert(w > 0 and h > 0)
        assert(x >= clip.x and y >= clip.y and x + w <= math.ceil(clip.x + clip.w)
            and y + h <= math.ceil(clip.y + clip.h), "native span exceeded clip")
        self.calls = self.calls + 1
        for py = y, y + h - 1 do
            self.pixels[py] = self.pixels[py] or {}
            for px = x, x + w - 1 do self.pixels[py][px] = true end
        end
    end }
end

local checked = 0
local function check(a, b, width, clip)
    local bb = buffer(clip)
    local changed = Render.line(bb, a, b, width, 0, clip)
    local bounds = Render.bounds(a, b, width, clip)
    local expected_count, actual_count = 0, 0
    for y = math.ceil(clip.y), math.ceil(clip.y + clip.h) - 1 do
        for x = math.ceil(clip.x), math.ceil(clip.x + clip.w) - 1 do
            local expected, actual = expectedHit(x, y, a, b, width), (bb.pixels[y] and bb.pixels[y][x]) == true
            assert(expected == actual, "pixel mismatch at " .. x .. "," .. y
                .. " for " .. a.x .. "," .. a.y .. " to " .. b.x .. "," .. b.y)
            if expected then expected_count = expected_count + 1 end
            if actual then
                actual_count = actual_count + 1
                assert(changed and x >= changed.x and y >= changed.y and x < changed.x + changed.w
                    and y < changed.y + changed.h, "dirty bounds omitted painted pixel")
            end
        end
    end
    assert(expected_count == actual_count)
    if actual_count == 0 then assert(changed == nil) end
    if bounds then assert(bb.calls <= math.min(bounds.w, bounds.h), "more than one native span per scanline") end
    checked = checked + 1
end

local clip = {x=0,y=0,w=90,h=90}
local cases = {
    {{x=10,y=10},{x=70,y=10},1},
    {{x=70,y=10},{x=10,y=10},4},
    {{x=10,y=10},{x=10,y=70},3},
    {{x=10,y=70},{x=10,y=10},7},
    {{x=10,y=10},{x=70,y=70},5},
    {{x=70,y=10},{x=10,y=70},5},
    {{x=10,y=70},{x=70,y=10},5},
    {{x=10,y=10},{x=70,y=13},6},
    {{x=20,y=5},{x=22,y=80},4},
    {{x=20.2,y=25.7},{x=20.3,y=25.6},3},
    {{x=-25,y=3},{x=130,y=88},6},
    {{x=-20,y=-20},{x=-10,y=-10},2},
}
for _, case in ipairs(cases) do check(case[1],case[2],case[3],clip) end
-- Crops can force a different scan orientation, including a vertical line.
check({x=30,y=-100},{x=30,y=200},8,{x=0,y=15,w=80,h=3})
check({x=-100,y=30},{x=200,y=30},8,{x=15,y=0,w=3,h=80})
check({x=10,y=10},{x=65,y=55},4,{x=15.3,y=12.5,w=40.2,h=34.4})

math.randomseed(73152)
for _ = 1, 120 do
    check({x=math.random(-20,110),y=math.random(-20,110)},
        {x=math.random(-20,110),y=math.random(-20,110)},math.random(1,14),clip)
end

local long_clip = {x=0,y=0,w=1100,h=60}
local bb = buffer(long_clip)
Render.line(bb,{x=10,y=30},{x=1010,y=30},4,0,long_clip)
local radius, length = 2, 1000
local old_calls = (math.ceil(length / math.max(1,radius*0.65)) + 1) * (radius*2 + 1)
assert(bb.calls == 5 and old_calls / bb.calls > 700, "long-line native call reduction regressed")
print("Render: " .. checked .. " pixel coverage cases passed; long horizontal native calls "
    .. old_calls .. " -> " .. bb.calls)
