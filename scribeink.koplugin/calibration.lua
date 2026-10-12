-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Three non-collinear raw taps define the tablet-to-screen affine map.
local Calibration = {}

function Calibration.solve(raw, targets)
    local p, q, r = raw[1], raw[2], raw[3]
    if not p or not q or not r then return nil, "Three pen taps are required." end
    local ux, uy, vx, vy = q.x-p.x, q.y-p.y, r.x-p.x, r.y-p.y
    local det = ux*vy-uy*vx
    local scale = math.sqrt((ux*ux+uy*uy)*(vx*vx+vy*vy))
    if scale == 0 or math.abs(det)/scale < 0.15 then
        return nil, "Calibration taps are too close together. Tap each displayed cross." 
    end
    local function coefficients(key)
        local du = targets[2][key]-targets[1][key]
        local dv = targets[3][key]-targets[1][key]
        local a, b = (du*vy-dv*uy)/det, (dv*ux-du*vx)/det
        return a, b, targets[1][key]-a*p.x-b*p.y
    end
    local a,b,c = coefficients("x")
    local d,e,f = coefficients("y")
    return {a=a,b=b,c=c,d=d,e=e,f=f}
end

function Calibration.valid(map)
    if type(map) ~= "table" then return false end
    for _, key in ipairs{"a","b","c","d","e","f"} do
        local v = map[key]
        if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then return false end
    end
    return math.abs(map.a*map.e-map.b*map.d) > 1e-12
end

function Calibration.apply(map, point)
    return {x=map.a*point.x+map.b*point.y+map.c,
            y=map.d*point.x+map.e*point.y+map.f}
end

return Calibration
