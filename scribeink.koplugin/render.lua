-- SPDX-License-Identifier: AGPL-3.0-or-later
-- One native span per scanline avoids repeatedly painting overlapping disks.
local Render = {}
local ceil, floor, sqrt = math.ceil, math.floor, math.sqrt
local min, max, abs = math.min, math.max, math.abs

local function parameters(a, b, width, clip)
    -- Keep the previous renderer's pixel thickness and round cap dimensions.
    local radius = max(1, floor((width or 1) / 2 + 0.5))
    local ax, ay = floor(a.x + 0.5), floor(a.y + 0.5)
    local bx, by = floor(b.x + 0.5), floor(b.y + 0.5)
    local left, top = min(ax, bx) - radius, min(ay, by) - radius
    local right, bottom = max(ax, bx) + radius, max(ay, by) + radius
    if clip then
        -- Pixel coordinates lie inside the clip's half-open bounds.
        left, top = max(left, ceil(clip.x)), max(top, ceil(clip.y))
        right = min(right, ceil(clip.x + clip.w) - 1)
        bottom = min(bottom, ceil(clip.y + clip.h) - 1)
    end
    if left > right or top > bottom then return nil end
    return ax, ay, bx, by, radius, left, top, right, bottom
end

-- Conservative integer pixel bounds for an incremental screen refresh.
function Render.bounds(a, b, width, clip)
    local _, _, _, _, _, left, top, right, bottom = parameters(a, b, width, clip)
    if not left then return nil end
    return { x = left, y = top, w = right - left + 1, h = bottom - top + 1 }
end

-- Rasterize a constant-width capsule, returning actual painted pixel bounds.
function Render.line(bb, a, b, width, color, clip)
    local ax, ay, bx, by, radius, left, top, right, bottom = parameters(a, b, width, clip)
    if not ax then return nil end
    local columns = right - left < bottom - top
    -- 'major' is the coordinate along each span; 'minor' is its scanline.
    local ma, na, mb, nb = ax, ay, bx, by
    local major_min, major_max, scan_min, scan_max = left, right, top, bottom
    if columns then
        ma, na, mb, nb = ay, ax, by, bx
        major_min, major_max, scan_min, scan_max = top, bottom, left, right
    end
    local dm, dn = mb - ma, nb - na
    local length2, radius2 = dm * dm + dn * dn, radius * radius
    local along_slope, along_size, across_slope, across_radius
    if dm ~= 0 then
        along_slope, along_size = dn / dm, length2 / dm
        if dn ~= 0 then
            across_slope, across_radius = dm / dn, radius * sqrt(length2) / abs(dn)
        end
    end
    local painted_left, painted_top, painted_right, painted_bottom
    for scan = scan_min, scan_max do
        local low, high
        local q = scan - na
        if length2 > 0 then
            -- Intersect the infinite strip with the segment's end planes.
            if dm ~= 0 then
                local t0 = ma - q * along_slope
                local t1 = t0 + along_size
                local strip_low, strip_high = min(t0, t1), max(t0, t1)
                if dn ~= 0 then
                    local center = ma + q * across_slope
                    strip_low = max(strip_low, center - across_radius)
                    strip_high = min(strip_high, center + across_radius)
                    if strip_low <= strip_high then low, high = strip_low, strip_high end
                elseif abs(q) <= radius then
                    low, high = strip_low, strip_high
                end
            elseif q * dn >= 0 and q * dn <= length2 then
                -- Clipping can make scan selection differ from orientation.
                low, high = ma - radius, ma + radius
            end
        end
        -- The circular end caps and rectangle form one convex interval.
        if q * q <= radius2 then
            local half = sqrt(radius2 - q * q)
            low, high = min(low or ma - half, ma - half), max(high or ma + half, ma + half)
        end
        if length2 > 0 then
            local qb = scan - nb
            if qb * qb <= radius2 then
                local half = sqrt(radius2 - qb * qb)
                low, high = min(low or mb - half, mb - half), max(high or mb + half, mb + half)
            end
        end
        if low then
            -- Retain exact diagonal boundary pixels despite rounding error.
            -- LuaJIT ceil can return IEEE -0; normalize public coordinates.
            local first = max(major_min, ceil(low - 1e-9)) + 0
            local last = min(major_max, floor(high + 1e-9)) + 0
            if first <= last then
                local x, y, w, h
                if columns then x, y, w, h = scan, first, 1, last - first + 1
                else x, y, w, h = first, scan, last - first + 1, 1 end
                bb:paintRect(x, y, w, h, color)
                painted_left, painted_top = min(painted_left or x, x), min(painted_top or y, y)
                painted_right = max(painted_right or x + w - 1, x + w - 1)
                painted_bottom = max(painted_bottom or y + h - 1, y + h - 1)
            end
        end
    end
    if not painted_left then return nil end
    return { x = painted_left, y = painted_top,
        w = painted_right - painted_left + 1, h = painted_bottom - painted_top + 1 }
end

return Render
