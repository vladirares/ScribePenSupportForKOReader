-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Read a separate evdev descriptor: never consume KOReader's descriptor, grab
-- a device, or change its kernel settings. Coordinates are left in device units.
local Input = {}

local CODE = {
    EV_SYN = 0, EV_KEY = 1, EV_ABS = 3,
    SYN_REPORT = 0, SYN_DROPPED = 3,
    ABS_X = 0, ABS_Y = 1, ABS_PRESSURE = 24, ABS_DISTANCE = 25,
    ABS_TILT_X = 26, ABS_TILT_Y = 27, ABS_MISC = 40,
    BTN_TOOL_PEN = 320, BTN_TOOL_RUBBER = 321,
    BTN_TOUCH = 330, BTN_STYLUS = 331, BTN_STYLUS2 = 332,
}
Input.codes = CODE

local function eraserKey(config)
    if config.eraser_key == "BTN_STYLUS" or config.eraser_key == CODE.BTN_STYLUS then
        return CODE.BTN_STYLUS
    elseif config.eraser_key == "BTN_STYLUS2" or config.eraser_key == CODE.BTN_STYLUS2 then
        return CODE.BTN_STYLUS2
    elseif config.eraser_key == nil and config.barrel_eraser == true then
        return CODE.BTN_STYLUS
    end
    return CODE.BTN_TOOL_RUBBER
end

local KEY_NAMES = {
    [CODE.BTN_TOOL_PEN] = "BTN_TOOL_PEN", [CODE.BTN_TOOL_RUBBER] = "BTN_TOOL_RUBBER",
    [CODE.BTN_TOUCH] = "BTN_TOUCH", [CODE.BTN_STYLUS] = "BTN_STYLUS",
    [CODE.BTN_STYLUS2] = "BTN_STYLUS2",
}
local AXIS_NAMES = {
    [CODE.ABS_X] = "ABS_X", [CODE.ABS_Y] = "ABS_Y", [CODE.ABS_PRESSURE] = "ABS_PRESSURE",
    [CODE.ABS_DISTANCE] = "ABS_DISTANCE", [CODE.ABS_TILT_X] = "ABS_TILT_X",
    [CODE.ABS_TILT_Y] = "ABS_TILT_Y", [CODE.ABS_MISC] = "ABS_MISC",
}

function Input.codeName(event_type, code)
    if event_type == CODE.EV_KEY then return KEY_NAMES[code] or "KEY_" .. code end
    if event_type == CODE.EV_ABS then return AXIS_NAMES[code] or "ABS_" .. code end
    if event_type == CODE.EV_SYN and code == CODE.SYN_REPORT then return "SYN_REPORT" end
    if event_type == CODE.EV_SYN and code == CODE.SYN_DROPPED then return "SYN_DROPPED" end
    return "TYPE_" .. event_type .. "_CODE_" .. code
end

local Decoder = {}
Decoder.__index = Decoder

-- Public so recorded Linux input frames can be tested without a Kindle or FFI.
function Input.newDecoder(config)
    config = config or {}
    return setmetatable({
        has_touch = config.has_touch ~= false,
        emit_hover = config.emit_hover == true,
        eraser_key = eraserKey(config),
        pressure_threshold = config.pressure_threshold or 0,
        -- Hardware adapters enable a short release grace; pure decoder tests
        -- default to no delay for backward-compatible protocol fixtures.
        eraser_release_grace = config.eraser_release_grace or 0,
        pressure = 0,
        pen = false, rubber = false, touch = false, barrel = false, barrel2 = false,
        active = false, dirty = false, blocked = false,
    }, Decoder)
end

function Decoder:isEraser()
    return self.rubber or (self.eraser_key == CODE.BTN_STYLUS and self.barrel)
        or (self.eraser_key == CODE.BTN_STYLUS2 and self.barrel2)
        -- A rear contact stays a rear contact through brief pressure/tool-key
        -- dropouts. Contact releases are debounced in report(), not here.
        or (self.active and self.active_eraser)
end

function Decoder:isToolPresent()
    return self.pen or self:isEraser()
end

function Decoder:isContact()
    local pressure_contact = self.pressure > self.pressure_threshold
    -- A firmware stream may advertise BTN_TOUCH but omit it for the rear tool.
    -- Pressure can then establish eraser contact; ordinary pen hover still obeys
    -- BTN_TOUCH when that key is available. Side buttons require explicit setup.
    return self:isToolPresent() and (self.touch
        or (not self.has_touch or self:isEraser()) and pressure_contact)
end

function Decoder:emit(phase, callback, timestamp, cancelled, reason)
    local event = {
        phase = phase,
        -- Do not extend a completed erase to a later in-air hover coordinate.
        x = phase == "up" and self.pending_eraser_up and self.last_contact_x or self.x,
        y = phase == "up" and self.pending_eraser_up and self.last_contact_y or self.y,
        pressure = self.pressure,
        eraser = (self.active and self.active_eraser) or (not self.active and self:isEraser()) or false,
        time = timestamp, cancelled = cancelled or nil, reason = reason,
    }
    if phase == "down" or phase == "move" then
        self.last_contact_x, self.last_contact_y = self.x, self.y
    end
    if callback then callback(event) end
end

function Decoder:cancel(callback, reason)
    -- An overrun can lose coordinates. Split the geometry, but remember an
    -- active eraser so it can restart at the resynchronized position.
    self.resume_eraser_on_sync = reason == "input_overrun" and self.active and self.active_eraser or nil
    if self.active then
        self:emit("up", callback, self.time, true, reason or "cancelled")
    end
    self.active = false
    self.active_eraser = nil
    self.pending_eraser_up = nil
    self.dirty = false
end

-- Called after EVIOCGKEY/EVIOCGABS snapshots. A contact already in progress is
-- ignored until it lifts; this also prevents joining strokes across dropped data.
function Decoder:sync(snapshot)
    local resume = self.resume_eraser_on_sync
    self.resume_eraser_on_sync = nil
    self.active = false
    self.active_eraser = nil
    self.pending_eraser_up = nil
    self.x, self.y = snapshot.x, snapshot.y
    self.pressure = snapshot.pressure or 0
    self.pen, self.rubber = snapshot.pen or false, snapshot.rubber or false
    self.touch, self.barrel = snapshot.touch or false, snapshot.barrel or false
    self.barrel2 = snapshot.barrel2 or false
    -- Only a rear eraser already active before SYN_DROPPED may resume.
    -- Newly opened devices still block any preexisting held contact.
    local touching = self.touch or self.pressure > self.pressure_threshold
    if resume and touching and self.x ~= nil and self.y ~= nil then
        self.active, self.active_eraser = true, true
        self.resume_eraser_after_sync = true
    else
        self.resume_eraser_after_sync = false
    end
    self.blocked = self:isContact() and not self.active
    self.hover_present = self:isToolPresent()
    self.dirty = false
end

function Decoder:resume(callback, timestamp)
    if self.resume_eraser_after_sync and self.active then
        self.resume_eraser_after_sync = false
        self:emit("down", callback, timestamp)
    end
end

-- The physical eraser remains logically down through short contact-key gaps.
-- Poll() finalizes the release even when the hardware sends no more reports.
function Decoder:flushPending(callback, timestamp)
    if not (self.pending_eraser_up and self.active and self.active_eraser) then return false end
    if timestamp - self.pending_eraser_up < self.eraser_release_grace then return false end
    self:emit("up", callback, timestamp)
    self.active = false
    self.active_eraser = nil
    self.pending_eraser_up = nil
    return true
end

function Decoder:report(callback, timestamp)
    self.time = timestamp
    local contact = self:isContact()
    if not self:isToolPresent() then
        -- A tool leaving proximity also invalidates stale contact/pressure state.
        self.touch = false
        self.pressure = 0
    end
    if self.blocked then
        if not contact then self.blocked = false end
        self.dirty = false
        return
    end
    local eraser = self:isEraser()
    local was_active = self.active
    if self.active and self.active_eraser and self.eraser_release_grace > 0 then
        if contact then
            self.pending_eraser_up = nil
        else
            self.pending_eraser_up = self.pending_eraser_up or timestamp
            if not self:flushPending(callback, timestamp) then
                self.hover_present = self:isToolPresent()
                self.dirty = false
                return
            end
        end
    end
    if self.active and (not contact or eraser ~= self.active_eraser) then
        self:emit("up", callback, timestamp)
        self.active = false
        self.active_eraser = nil
    end
    if contact and self.x ~= nil and self.y ~= nil then
        if not self.active then
            self.active = true
            self.active_eraser = eraser
            self:emit("down", callback, timestamp)
        elseif self.dirty then
            self:emit("move", callback, timestamp)
        end
    elseif self.emit_hover and not was_active then
        -- Do not emit hover in the same report as UP: release must restore the
        -- page and schedule its one cleanup refresh before preview can return.
        if self:isToolPresent() and self.x ~= nil and self.y ~= nil and self.dirty then
            self:emit("hover", callback, timestamp)
        elseif self.hover_present and not self:isToolPresent() then
            self:emit("leave", callback, timestamp)
        end
    end
    self.hover_present = self:isToolPresent()
    self.dirty = false
end

-- SYN_REPORT commits a coherent sample even when BTN_TOUCH arrives before X/Y.
-- Returns "resync" only after the post-SYN_DROPPED SYN_REPORT, per evdev rules.
function Decoder:feed(event_type, code, value, timestamp, callback)
    if self.dropped then
        if event_type == CODE.EV_SYN and code == CODE.SYN_REPORT then
            self.dropped = false
            return "resync"
        end
        return
    end
    if event_type == CODE.EV_SYN then
        if code == CODE.SYN_REPORT then
            self:report(callback, timestamp)
        elseif code == CODE.SYN_DROPPED then
            self:cancel(callback, "input_overrun")
            self.dropped = true
        end
    elseif event_type == CODE.EV_ABS then
        if code == CODE.ABS_X then self.x = value
        elseif code == CODE.ABS_Y then self.y = value
        elseif code == CODE.ABS_PRESSURE then self.pressure = math.max(0, value)
        else return end
        self.dirty = true
    elseif event_type == CODE.EV_KEY then
        local pressed = value ~= 0
        if code == CODE.BTN_TOOL_PEN then self.pen = pressed
        elseif code == CODE.BTN_TOOL_RUBBER then self.rubber = pressed
        elseif code == CODE.BTN_TOUCH then self.touch = pressed
        elseif code == CODE.BTN_STYLUS then self.barrel = pressed
        elseif code == CODE.BTN_STYLUS2 then self.barrel2 = pressed
        else return end
        self.dirty = true
    end
end

local Adapter = {}
Adapter.__index = Adapter

function Adapter:resetDiagnostics()
    local state = self.decoder
    self.diagnostics = { records = 0, frames = 0, keys = {}, axes = {}, kinds = 0, recent = {},
        initial = { pen = state.pen, rubber = state.rubber, touch = state.touch,
            stylus = state.barrel, stylus2 = state.barrel2, pressure = state.pressure } }
end

function Adapter:setRawObserver(callback)
    self.raw_observer = callback
end

function Adapter:recordRaw(event_type, code, value, timestamp)
    local diagnostics = self.diagnostics
    diagnostics.records = diagnostics.records + 1
    if event_type == CODE.EV_SYN and code == CODE.SYN_REPORT then
        diagnostics.frames = diagnostics.frames + 1
    elseif event_type == CODE.EV_KEY or event_type == CODE.EV_ABS then
        local bucket = event_type == CODE.EV_KEY and diagnostics.keys or diagnostics.axes
        local item = bucket[code]
        if not item and diagnostics.kinds < 64 then
            item = { count = 0, min = value, max = value, last = value, presses = 0, releases = 0 }
            bucket[code] = item
            diagnostics.kinds = diagnostics.kinds + 1
        end
        if item then
            item.count = item.count + 1
            item.min, item.max, item.last = math.min(item.min, value), math.max(item.max, value), value
            if event_type == CODE.EV_KEY then
                if value == 1 then item.presses = item.presses + 1 end
                if value == 0 then item.releases = item.releases + 1 end
                local recent = diagnostics.recent
                if #recent >= 24 then table.remove(recent, 1) end
                recent[#recent + 1] = Input.codeName(event_type, code) .. "=" .. value
            end
        end
    end
    if self.raw_observer then
        local ok, observer_error = pcall(self.raw_observer, {
            type = event_type, code = code, value = value, time = timestamp,
            name = Input.codeName(event_type, code),
        })
        if not ok then self:close(); error(observer_error, 0) end
    end
end

function Adapter:diagnosticText()
    local d, info = self.diagnostics, self.info
    local initial = d.initial
    local lines = {
        "Pen input: " .. info.name .. " @ " .. info.path,
        "Source hint: " .. info.source_hint .. "; eraser key: " .. info.eraser_key,
        "Capabilities: rubber=" .. tostring(info.has_rubber) .. ", touch=" .. tostring(info.has_touch)
            .. ", pressure=" .. tostring(info.has_pressure) .. ", stylus=" .. tostring(info.has_stylus)
            .. ", stylus2=" .. tostring(info.has_stylus2),
        "Observed " .. d.records .. " raw events in " .. d.frames .. " frames.",
        "At test start: pen=" .. tostring(initial.pen) .. ", rubber=" .. tostring(initial.rubber)
            .. ", touch=" .. tostring(initial.touch) .. ", stylus=" .. tostring(initial.stylus)
            .. ", stylus2=" .. tostring(initial.stylus2) .. ", pressure=" .. initial.pressure,
    }
    for _, code in ipairs{ CODE.BTN_TOOL_PEN, CODE.BTN_TOOL_RUBBER, CODE.BTN_TOUCH,
        CODE.BTN_STYLUS, CODE.BTN_STYLUS2 } do
        local item = d.keys[code]
        lines[#lines + 1] = KEY_NAMES[code] .. ": presses=" .. (item and item.presses or 0)
            .. ", releases=" .. (item and item.releases or 0) .. ", last=" .. (item and item.last or "unseen")
    end
    local axes = {}
    for code in pairs(d.axes) do axes[#axes + 1] = code end
    table.sort(axes)
    for _, code in ipairs(axes) do
        local item = d.axes[code]
        lines[#lines + 1] = Input.codeName(CODE.EV_ABS, code) .. ": count=" .. item.count
            .. ", min=" .. item.min .. ", max=" .. item.max .. ", last=" .. item.last
    end
    if #d.recent > 0 then lines[#lines + 1] = "Recent keys: " .. table.concat(d.recent, "; ") end
    return table.concat(lines, "\n")
end

local function linuxAPI()
    local ok, ffi = pcall(require, "ffi")
    if not ok or ffi.os ~= "Linux" then
        return nil, "Raw pen input requires KOReader's Linux/LuaJIT runtime."
    end
    local headers_ok, headers_error = pcall(function()
        require("ffi/posix_h")
        require("ffi/linux_input_h")
        -- Private name avoids conflicting with headers from other plugins.
        if not pcall(ffi.typeof, "struct scribeink_absinfo") then
            ffi.cdef[[
                struct scribeink_absinfo {
                    int value, minimum, maximum, fuzz, flat, resolution;
                };
            ]]
        end
    end)
    if not headers_ok then return nil, "Unable to load evdev headers: " .. tostring(headers_error) end
    return { ffi = ffi, C = ffi.C }
end

-- Linux asm-generic _IOR('E', nr, size); valid for Kindle's ARM evdev ABI.
local function readIOCTL(nr, size)
    return 2147483648 + size * 65536 + 69 * 256 + nr
end

local function hasBit(buffer, number)
    local byte = tonumber(buffer[math.floor(number / 8)])
    return math.floor(byte / 2 ^ (number % 8)) % 2 == 1
end

local function axisInfo(api, fd, axis)
    local info = api.ffi.new("struct scribeink_absinfo[1]")
    if api.C.ioctl(fd, readIOCTL(0x40 + axis, api.ffi.sizeof(info[0])), info) < 0 then return end
    return {
        min = tonumber(info[0].minimum), max = tonumber(info[0].maximum),
        value = tonumber(info[0].value), resolution = tonumber(info[0].resolution),
    }
end

local function devicePaths(config)
    if config.path and config.path ~= "" then return { config.path } end
    local result, seen = {}, {}
    local function add(path)
        if not seen[path] then seen[path] = true; result[#result + 1] = path end
    end
    -- The proc inventory is also available on old Kindle firmwares.
    local proc = io.open("/proc/bus/input/devices", "r")
    if proc then
        for line in proc:lines() do
            if line:match("^H: Handlers=") then
                for event in line:gmatch("event%d+") do add("/dev/input/" .. event) end
            end
        end
        proc:close()
    end
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok then
        pcall(function()
            for name in lfs.dir("/dev/input") do
                if name:match("^event%d+$") then add("/dev/input/" .. name) end
            end
        end)
    end
    table.sort(result)
    return result
end

local function inspectDevice(api, path, config)
    local fd = api.C.open(path, api.C.O_RDONLY + api.C.O_NONBLOCK + api.C.O_CLOEXEC)
    if fd < 0 then return nil, "Cannot open " .. path .. " (errno " .. api.ffi.errno() .. ")." end
    fd = tonumber(fd)
    local function reject(reason)
        api.C.close(fd)
        return nil, reason
    end
    local keys = api.ffi.new("unsigned char[96]")
    local axes = api.ffi.new("unsigned char[8]")
    if api.C.ioctl(fd, readIOCTL(0x20 + CODE.EV_KEY, 96), keys) < 0
        or api.C.ioctl(fd, readIOCTL(0x20 + CODE.EV_ABS, 8), axes) < 0 then
        return reject(path .. " is not a readable evdev pen device.")
    end
    if not hasBit(keys, CODE.BTN_TOOL_PEN) and not hasBit(keys, CODE.BTN_TOOL_RUBBER) then
        return reject(path .. " has no pen-tool capability.")
    end
    if not hasBit(axes, CODE.ABS_X) or not hasBit(axes, CODE.ABS_Y) then
        return reject(path .. " has no absolute pen coordinates.")
    end
    local x, y = axisInfo(api, fd, CODE.ABS_X), axisInfo(api, fd, CODE.ABS_Y)
    if not x or not y or x.max <= x.min or y.max <= y.min then
        return reject(path .. " has invalid coordinate ranges.")
    end
    local has_touch = hasBit(keys, CODE.BTN_TOUCH)
    local pressure = hasBit(axes, CODE.ABS_PRESSURE) and axisInfo(api, fd, CODE.ABS_PRESSURE) or nil
    if not has_touch and not pressure then
        return reject(path .. " cannot distinguish pen contact from hover.")
    end
    local name_buffer = api.ffi.new("char[128]")
    local name = path
    if api.C.ioctl(fd, readIOCTL(0x06, 128), name_buffer) >= 0 then
        name = api.ffi.string(name_buffer)
    end
    local lower = name:lower()
    local score = 0
    local wacom = lower:find("wacom", 1, true)
    local digitizer = lower:find("digitizer", 1, true)
    local scaled = lower:find("custom", 1, true) or lower:find("virtual", 1, true)
        or lower:find("scaled", 1, true)
    if wacom then score = score + 100 end
    if digitizer then score = score + 80 end
    if lower:find("stylus", 1, true) then score = score + 20 end
    -- Some firmware services may exclusively consume the physical digitizer.
    -- The virtual stream remains a fallback without changing any kernel grab.
    if scaled then score = score + (config.prefer_scaled and 400 or -300) end
    if pressure then score = score + 20 end
    local has_rubber = hasBit(keys, CODE.BTN_TOOL_RUBBER)
    if has_rubber then score = score + 10 end
    return {
        fd = fd, score = score, ranges = { x = x, y = y, pressure = pressure },
        info = { path = path, name = name, has_touch = has_touch, has_rubber = has_rubber,
            has_pressure = pressure ~= nil,
            has_stylus = hasBit(keys, CODE.BTN_STYLUS), has_stylus2 = hasBit(keys, CODE.BTN_STYLUS2),
            eraser_key = KEY_NAMES[eraserKey(config)],
            source_hint = scaled and "scaled" or ((wacom or digitizer) and "raw" or "unknown"),
            prefer_scaled = config.prefer_scaled == true },
    }
end

function Adapter:resync()
    local keys = self.api.ffi.new("unsigned char[96]")
    if self.api.C.ioctl(self.fd, readIOCTL(0x18, 96), keys) < 0 then
        return nil, "Could not query the pen state (errno " .. self.api.ffi.errno() .. ")."
    end
    local x = axisInfo(self.api, self.fd, CODE.ABS_X)
    local y = axisInfo(self.api, self.fd, CODE.ABS_Y)
    local pressure = self.info.has_pressure and axisInfo(self.api, self.fd, CODE.ABS_PRESSURE)
    if not x or not y or (self.info.has_pressure and not pressure) then
        return nil, "Could not query the pen coordinates."
    end
    self.decoder:sync({
        x = x.value, y = y.value, pressure = pressure and pressure.value or 0,
        pen = hasBit(keys, CODE.BTN_TOOL_PEN), rubber = hasBit(keys, CODE.BTN_TOOL_RUBBER),
        touch = hasBit(keys, CODE.BTN_TOUCH), barrel = hasBit(keys, CODE.BTN_STYLUS),
        barrel2 = hasBit(keys, CODE.BTN_STYLUS2),
    })
    return true
end

function Input.open(config)
    config = config or {}
    local api, api_error = linuxAPI()
    if not api then return nil, api_error end
    local chosen, last_error
    for _, path in ipairs(devicePaths(config)) do
        local candidate, error_message = inspectDevice(api, path, config)
        if candidate then
            if not chosen or candidate.score > chosen.score then
                if chosen then api.C.close(chosen.fd) end
                chosen = candidate
            else
                api.C.close(candidate.fd)
            end
        else
            last_error = error_message
        end
    end
    if not chosen then
        if config.path and config.path ~= "" then return nil, last_error end
        return nil, "No evdev pen device with valid X/Y and contact detection was found."
    end
    local self = setmetatable({
        api = api, fd = chosen.fd, ranges = chosen.ranges, info = chosen.info,
        decoder = Input.newDecoder({ has_touch = chosen.info.has_touch, barrel_eraser = config.barrel_eraser,
            emit_hover = config.emit_hover == true,
            eraser_release_grace = config.eraser_release_grace == nil and 0.10
                or config.eraser_release_grace,
            eraser_key = config.eraser_key, pressure_threshold = chosen.ranges.pressure
                and math.max(0, chosen.ranges.pressure.min) or 0 }),
        buffer = api.ffi.new("struct input_event[64]"),
        event_size = api.ffi.sizeof("struct input_event"),
        max_batches = config.max_batches or 16,
    }, Adapter)
    -- Safety net if a plugin error abandons the adapter without calling close.
    self.guard = api.ffi.gc(api.ffi.new("int[1]", self.fd), function(guard)
        if guard[0] >= 0 then api.C.close(guard[0]) end
    end)
    local synced, sync_error = self:resync()
    if not synced then self:close(); return nil, sync_error end
    self:resetDiagnostics()
    return self
end

-- Nonblocking, bounded work. Returns emitted sample count, or nil/error and
-- closes only our descriptor on disconnect/read failure.
-- Use the clock corresponding to evdev's timestamps. Depending on kernel
-- configuration, input_event uses either monotonic or realtime timestamps.
local function inputClockNow(api, anchor)
    local ok, value = pcall(function()
        local ts = api.ffi.new("struct timespec[1]")
        local nearest, distance
        for _, clock_id in ipairs{1, 0} do -- CLOCK_MONOTONIC, CLOCK_REALTIME
            if api.C.clock_gettime(clock_id, ts) == 0 then
                local t = tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) / 1000000000
                local d = math.abs(t - anchor)
                if not distance or d < distance then nearest, distance = t, d end
            end
        end
        if distance and distance < 86400 then return nearest end
    end)
    return ok and value or nil
end

function Adapter:poll(callback)
    if self.fd == nil then return nil, "Pen input is closed." end
    local emitted, interrupted = 0, 0
    local function deliver(event)
        emitted = emitted + 1
        if callback then
            local ok, callback_error = pcall(callback, event)
            if not ok then
                self:close()
                error(callback_error, 0)
            end
        end
    end
    local function flushPendingRelease()
        local decoder = self.decoder
        if not decoder.pending_eraser_up then return end
        local now = inputClockNow(self.api, decoder.pending_eraser_up)
        -- If this KOReader FFI build cannot read the clock, do not leave the
        -- eraser stuck down. Only the debounce (not erasing) degrades.
        if not now then now = decoder.pending_eraser_up + decoder.eraser_release_grace end
        decoder:flushPending(deliver, now)
    end
    for _ = 1, self.max_batches do
        local count = tonumber(self.api.C.read(self.fd, self.buffer, self.api.ffi.sizeof(self.buffer)))
        if count < 0 then
            local errno = self.api.ffi.errno()
            if errno == 11 then
                flushPendingRelease()
                return emitted
            end -- EAGAIN / EWOULDBLOCK
            if errno == 4 then -- EINTR; bounded by max_batches
                interrupted = interrupted + 1
                if interrupted >= 4 then
                    flushPendingRelease()
                    return emitted
                end
            else
                self.decoder:cancel(deliver, "input_disconnected")
                self:close()
                return nil, "Pen read failed (errno " .. errno .. ")."
            end
        elseif count == 0 or count % self.event_size ~= 0 then
            self.decoder:cancel(deliver, "input_disconnected")
            self:close()
            return nil, "Pen input disconnected or returned an incomplete evdev record."
        else
            for index = 0, count / self.event_size - 1 do
                local event = self.buffer[index]
                local timestamp = tonumber(event.time.tv_sec) + tonumber(event.time.tv_usec) / 1000000
                local event_type, code, value = tonumber(event.type), tonumber(event.code), tonumber(event.value)
                self:recordRaw(event_type, code, value, timestamp)
                if self.fd == nil then return emitted end
                local result = self.decoder:feed(event_type, code, value, timestamp, deliver)
                -- A toolbar action in the callback can stop capture immediately.
                if self.fd == nil then return emitted end
                if result == "resync" then
                    local synced, error_message = self:resync()
                    if not synced then self:close(); return nil, error_message end
                    -- Restart at the current snapshot coordinate; do not erase
                    -- across the unknown portion lost to SYN_DROPPED.
                    self.decoder:resume(deliver, timestamp)
                end
            end
        end
    end
    flushPendingRelease()
    return emitted
end

function Adapter:close()
    if self.fd ~= nil then
        self.api.C.close(self.fd)
        self.fd = nil
        if self.guard then
            self.guard[0] = -1
            self.api.ffi.gc(self.guard, nil)
            self.guard = nil
        end
        self.decoder:cancel()
    end
end

return Input
