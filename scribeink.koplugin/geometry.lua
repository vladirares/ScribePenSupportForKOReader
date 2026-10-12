-- Persistent geometry uses native MuPDF page coordinates, including any
-- intrinsic PDF rotation; KOReader's additional reader rotation must be zero.
local Geometry = {}

local function pointDistance2(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 == 0 and 0 or ((px - ax) * dx + (py - ay) * dy) / len2
    t = math.max(0, math.min(1, t))
    dx, dy = px - (ax + t * dx), py - (ay + t * dy)
    return dx * dx + dy * dy
end

function Geometry.segmentDistance2(ax, ay, bx, by, cx, cy, dx, dy)
    local abx, aby, cdx, cdy = bx - ax, by - ay, dx - cx, dy - cy
    local cross = abx * cdy - aby * cdx
    if math.abs(cross) > 1e-12 then
        local acx, acy = cx - ax, cy - ay
        local t = (acx * cdy - acy * cdx) / cross
        local u = (acx * aby - acy * abx) / cross
        if t >= 0 and t <= 1 and u >= 0 and u <= 1 then return 0 end
    end
    return math.min(
        pointDistance2(ax, ay, cx, cy, dx, dy),
        pointDistance2(bx, by, cx, cy, dx, dy),
        pointDistance2(cx, cy, ax, ay, bx, by),
        pointDistance2(dx, dy, ax, ay, bx, by))
end

function Geometry.pointInRect(point, rect)
    return point.x >= rect.x and point.x <= rect.x + rect.w
        and point.y >= rect.y and point.y <= rect.y + rect.h
end

function Geometry.intersectsBounds(a, b)
    return a.x <= b.x + b.w and a.x + a.w >= b.x
        and a.y <= b.y + b.h and a.y + a.h >= b.y
end

function Geometry.bounds(stroke)
    if not stroke.points or #stroke.points == 0 then return nil end
    local first = stroke.points[1]
    local minx, miny, maxx, maxy = first.x, first.y, first.x, first.y
    for i = 2, #stroke.points do
        local p = stroke.points[i]
        minx, miny = math.min(minx, p.x), math.min(miny, p.y)
        maxx, maxy = math.max(maxx, p.x), math.max(maxy, p.y)
    end
    local padding = (stroke.width or 0) / 2
    return { x = minx - padding, y = miny - padding,
        w = maxx - minx + padding * 2, h = maxy - miny + padding * 2 }
end

-- The eraser sweeps a capsule between two samples, so fast motion cannot
-- skip thin strokes. Stroke thickness is included when checking contact.
function Geometry.strokeHit(stroke, a, b, radius)
    if not stroke.points or #stroke.points == 0 then return false end
    local reach = math.max(0, radius) + (stroke.width or 0) / 2
    local sweep_bounds = { x = math.min(a.x, b.x) - reach,
        y = math.min(a.y, b.y) - reach,
        w = math.abs(a.x - b.x) + reach * 2,
        h = math.abs(a.y - b.y) + reach * 2 }
    if not Geometry.intersectsBounds(Geometry.bounds(stroke), sweep_bounds) then return false end
    local previous = stroke.points[1]
    if #stroke.points == 1 then
        return pointDistance2(previous.x, previous.y, a.x, a.y, b.x, b.y) <= reach * reach
    end
    for i = 2, #stroke.points do
        local p = stroke.points[i]
        if Geometry.segmentDistance2(a.x, a.y, b.x, b.y,
                previous.x, previous.y, p.x, p.y) <= reach * reach then return true end
        previous = p
    end
    return false
end

-- Intersect a line segment with a circle, returning its parameter interval.
-- The cross product avoids subtracting two large, nearly equal distances.
local function circleInterval(p, q, center, radius)
    local dx, dy = q.x - p.x, q.y - p.y
    local length2 = dx * dx + dy * dy
    local ox, oy = p.x - center.x, p.y - center.y
    if length2 == 0 then
        if ox * ox + oy * oy <= radius * radius then return 0, 1 end
        return nil
    end
    local cross = ox * dy - oy * dx
    local perpendicular2 = cross * cross / length2
    local remaining = radius * radius - perpendicular2
    if remaining < 0 then return nil end
    local center_t = -(ox * dx + oy * dy) / length2
    local half = math.sqrt(remaining / length2)
    local first, last = math.max(0, center_t - half), math.min(1, center_t + half)
    if first <= last then return first, last end
end

-- A capsule is its two end circles plus the rectangle between them. Because
-- it is convex, the union intersects any line in at most one interval.
local function capsuleInterval(p, q, a, b, radius)
    local first, last
    local function include(lo, hi)
        if lo then
            first, last = math.min(first or lo, lo), math.max(last or hi, hi)
        end
    end
    include(circleInterval(p, q, a, radius))
    local ux, uy = b.x - a.x, b.y - a.y
    local length = math.sqrt(ux * ux + uy * uy)
    if length == 0 then return first, last end
    include(circleInterval(p, q, b, radius))
    ux, uy = ux / length, uy / length
    local ox, oy, dx, dy = p.x - a.x, p.y - a.y, q.x - p.x, q.y - p.y
    local lo, hi = 0, 1
    local function slab(origin, delta, low, high)
        if delta == 0 then return origin >= low and origin <= high end
        local t0, t1 = (low - origin) / delta, (high - origin) / delta
        if t0 > t1 then t0, t1 = t1, t0 end
        lo, hi = math.max(lo, t0), math.min(hi, t1)
        return lo <= hi
    end
    if slab(ox * ux + oy * uy, dx * ux + dy * uy, 0, length)
        and slab(ox * uy - oy * ux, dx * uy - dy * ux, -radius, radius) then
        include(lo, hi)
    end
    return first, last
end

local function interpolate(a, b, t)
    -- Exact original endpoints retain their coordinates through repeated cuts.
    if t == 0 then return { x = a.x, y = a.y } end
    if t == 1 then return { x = b.x, y = b.y } end
    return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }
end

-- Cut only the centerline covered by an eraser sweep, returning ordinary
-- strokes so the existing sidecar and PDF exporters need no mask format.
-- Expand by half the ink width: new round caps then remain outside the rubber
-- footprint. The caller adds screen-to-page raster clearance to radius.
-- nil means unchanged; an empty fragment array means complete removal.
function Geometry.eraseStroke(stroke, a, b, radius)
    local points, width = stroke.points, stroke.width or 0
    if not points or #points == 0 then return nil end
    local sweep = { x = math.min(a.x, b.x) - radius,
        y = math.min(a.y, b.y) - radius,
        w = math.abs(a.x - b.x) + radius * 2,
        h = math.abs(a.y - b.y) + radius * 2 }
    if not Geometry.intersectsBounds(Geometry.bounds(stroke), sweep) then return nil end
    local reach = radius + width / 2
    if #points == 1 then
        local p = points[1]
        if pointDistance2(p.x, p.y, a.x, a.y, b.x, b.y) <= reach * reach then
            return {}, Geometry.bounds(stroke)
        end
        return nil
    end
    local fragments, current, changed = {}, nil, false
    local minx, miny, maxx, maxy
    local function affected(p)
        minx, miny = math.min(minx or p.x, p.x), math.min(miny or p.y, p.y)
        maxx, maxy = math.max(maxx or p.x, p.x), math.max(maxy or p.y, p.y)
    end
    local function append(p)
        if not current then current = { width = width, points = {} } end
        local previous = current.points[#current.points]
        if not previous or previous.x ~= p.x or previous.y ~= p.y then
            current.points[#current.points + 1] = { x = p.x, y = p.y }
        end
    end
    local function finish()
        if current then fragments[#fragments + 1] = current; current = nil end
    end
    for i = 2, #points do
        local p, q = points[i - 1], points[i]
        local first, last = capsuleInterval(p, q, a, b, reach)
        -- A tangency has no centerline length to cut. Ignore numerical dust at
        -- existing cut endpoints, avoiding endless re-splitting on still taps.
        local dx, dy = q.x - p.x, q.y - p.y
        local length = math.sqrt(dx * dx + dy * dy)
        if first and ((first == 0 and last == 1) or (last - first) * length > 1e-9) then
            changed = true
            local entry, exit = interpolate(p, q, first), interpolate(p, q, last)
            affected(entry); affected(exit)
            if first > 0 then append(p); append(entry) end
            finish()
            if last < 1 then append(exit); append(q) end
        else
            append(p); append(q)
        end
    end
    if not changed then return nil end
    finish()
    local padding = width / 2
    return fragments, { x = minx - padding, y = miny - padding,
        w = maxx - minx + 2 * padding, h = maxy - miny + 2 * padding }
end

-- Apply an entire eraser gesture to an ORIGINAL stroke in one pass. Repeated
-- Store:erase calls fragment strokes after every sample and make the next
-- sample increasingly expensive; this makes one fragment set per source path.
function Geometry.eraseStrokePath(stroke,path,radius)
    local points,width=stroke.points,stroke.width or 0
    if not points or #points==0 or not path or #path==0 then return nil end
    local minx,miny,maxx,maxy=path[1].x,path[1].y,path[1].x,path[1].y
    for i=2,#path do
        local p=path[i]
        minx,miny=math.min(minx,p.x),math.min(miny,p.y)
        maxx,maxy=math.max(maxx,p.x),math.max(maxy,p.y)
    end
    local reach=radius+width/2
    if not Geometry.intersectsBounds(Geometry.bounds(stroke),
        {x=minx-reach,y=miny-reach,w=maxx-minx+2*reach,h=maxy-miny+2*reach}) then return nil end
    local function contact(p,q,a,b)
        -- Cheap broad-phase before the much more expensive capsule math.
        if math.max(p.x,q.x)+reach < math.min(a.x,b.x)
            or math.min(p.x,q.x)-reach > math.max(a.x,b.x)
            or math.max(p.y,q.y)+reach < math.min(a.y,b.y)
            or math.min(p.y,q.y)-reach > math.max(a.y,b.y) then return nil end
        return capsuleInterval(p,q,a,b,reach)
    end
    if #points==1 then
        for j=1,#path do
            local a,b=path[j-1] or path[j],path[j]
            if Geometry.segmentDistance2(points[1].x,points[1].y,points[1].x,points[1].y,
                a.x,a.y,b.x,b.y)<=reach*reach then
                return {},Geometry.bounds(stroke)
            end
        end
        return nil
    end
    local fragments,current,changed={},nil,false
    local ax,ay,bx,by
    local function affected(p)
        ax,ay=math.min(ax or p.x,p.x),math.min(ay or p.y,p.y)
        bx,by=math.max(bx or p.x,p.x),math.max(by or p.y,p.y)
    end
    local function append(p)
        if not current then current={width=width,points={}} end
        local last=current.points[#current.points]
        if not last or last.x~=p.x or last.y~=p.y then
            current.points[#current.points+1]={x=p.x,y=p.y}
        end
    end
    local function finish()
        if current then fragments[#fragments+1]=current;current=nil end
    end
    for i=2,#points do
        local p,q=points[i-1],points[i]
        local cuts={}
        local dx,dy=q.x-p.x,q.y-p.y
        local length=math.sqrt(dx*dx+dy*dy)
        for j=1,#path do
            local a,b=path[j-1] or path[j],path[j]
            local lo,hi=contact(p,q,a,b)
            if lo and ((lo==0 and hi==1) or (hi-lo)*length>1e-9) then
                cuts[#cuts+1]={lo,hi}
            end
        end
        if #cuts==0 then
            append(p);append(q)
        else
            table.sort(cuts,function(a,b) return a[1]<b[1] end)
            local cutoff=0
            for _,cut in ipairs(cuts) do
                local lo,hi=math.max(cutoff,cut[1]),cut[2]
                if hi>cutoff then
                    if lo>cutoff then
                        append(interpolate(p,q,cutoff))
                        append(interpolate(p,q,lo))
                    end
                    finish()
                    affected(interpolate(p,q,lo));affected(interpolate(p,q,hi))
                    changed=true
                    cutoff=hi
                end
            end
            if cutoff<1 then append(interpolate(p,q,cutoff));append(q) end
        end
    end
    if not changed then return nil end
    finish()
    local pad=width/2
    return fragments,{x=ax-pad,y=ay-pad,w=bx-ax+2*pad,h=by-ay+2*pad}
end

-- Liang-Barsky clipping. Returned endpoints retain the segment's direction.
function Geometry.clipSegment(a, b, rect)
    local dx, dy, t0, t1 = b.x - a.x, b.y - a.y, 0, 1
    local function edge(p, q)
        if p == 0 then return q >= 0 end
        local r = q / p
        if p < 0 then
            if r > t1 then return false end
            if r > t0 then t0 = r end
        else
            if r < t0 then return false end
            if r < t1 then t1 = r end
        end
        return true
    end
    if not edge(-dx, a.x - rect.x)
        or not edge(dx, rect.x + rect.w - a.x)
        or not edge(-dy, a.y - rect.y)
        or not edge(dy, rect.y + rect.h - a.y) then return nil end
    return { x = a.x + t0 * dx, y = a.y + t0 * dy },
        { x = a.x + t1 * dx, y = a.y + t1 * dy }
end

-- KOReader state.offset is the page's screen origin; visible_area is the
-- crop/pan origin in zoomed pixels. Reader page rotation must be zero.
function Geometry.pageToScreen(point, transform)
    return { x = point.x * transform.zoom - transform.visible.x + transform.offset.x,
        y = point.y * transform.zoom - transform.visible.y + transform.offset.y }
end

function Geometry.screenToPage(point, transform)
    return { x = (point.x + transform.visible.x - transform.offset.x) / transform.zoom,
        y = (point.y + transform.visible.y - transform.offset.y) / transform.zoom }
end

return Geometry
