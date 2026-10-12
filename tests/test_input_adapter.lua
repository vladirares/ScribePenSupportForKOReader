-- Exercise evdev ABI requests and descriptor lifecycle with a deterministic
-- FFI-backed fake device. Linux device/ioctl behavior still needs hardware QA.
local realffi = require("ffi")
if not pcall(realffi.typeof, "struct input_event") then
    realffi.cdef[[
        struct input_event {
            struct { long tv_sec; long tv_usec; } time;
            unsigned short type, code;
            int value;
        };
    ]]
end

local savedffi = package.loaded.ffi
local savedposix = package.loaded["ffi/posix_h"]
local savedinput = package.loaded["ffi/linux_input_h"]
local savedopen = io.open
local savedlfs = package.loaded.lfs
local assertions = 0
local opened, closed, reads = 0, 0, 0
local frames = {}
local bad_coordinates = false
local malformed = false
local fail_read = false
local snapshot_touch = false
local discovering = false
local device_names = {}
local names_by_path = {
    ["/dev/input/fake-pen"] = "WacomDigitizer",
    ["/dev/input/event0"] = "Touch panel",
    ["/dev/input/event1"] = "stylus-custom",
    ["/dev/input/event2"] = "WacomDigitizer",
}

local function equal(actual, expected, label)
    assertions = assertions + 1
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function setbit(buffer, number)
    local index = math.floor(number / 8)
    buffer[index] = tonumber(buffer[index]) + 2 ^ (number % 8)
end

local fakeC = { O_RDONLY = 0, O_NONBLOCK = 2048, O_CLOEXEC = 524288 }
function fakeC.open(path, flags)
    if not discovering then equal(path, "/dev/input/fake-pen") end
    assert(names_by_path[path], "Unexpected device path: " .. tostring(path))
    equal(flags, 2048 + 524288, "nonblocking own descriptor")
    opened = opened + 1
    local fd = 40 + opened
    device_names[fd] = names_by_path[path]
    return fd
end
function fakeC.close(fd)
    assert(fd >= 41)
    closed = closed + 1
    return 0
end
function fakeC.ioctl(fd, request, buffer)
    assert(fd >= 41)
    local nr = request % 256
    local size = math.floor(request / 65536) % 16384
    equal(math.floor(request / 16777216) % 256, 128, "ioctl read direction")
    equal(math.floor(request / 256) % 256, 69, "ioctl type E")
    if nr == 0x21 then -- EVIOCGBIT(EV_KEY)
        equal(size, 96)
        if device_names[fd] ~= "Touch panel" then
            setbit(buffer, 320)
            setbit(buffer, 321)
            setbit(buffer, 331)
            setbit(buffer, 332)
        end
        setbit(buffer, 330)
    elseif nr == 0x23 then -- EVIOCGBIT(EV_ABS)
        equal(size, 8)
        setbit(buffer, 0)
        setbit(buffer, 1)
        setbit(buffer, 24)
    elseif nr == 0x18 then -- EVIOCGKEY
        equal(size, 96)
        if snapshot_touch then setbit(buffer, 320); setbit(buffer, 330) end
    elseif nr == 0x06 then -- EVIOCGNAME
        equal(size, 128)
        realffi.copy(buffer, device_names[fd] .. "\0")
    elseif nr == 0x40 or nr == 0x41 or nr == 0x58 then -- EVIOCGABS
        equal(size, 24, "kernel input_absinfo layout")
        buffer[0].value = 0
        buffer[0].minimum = 0
        buffer[0].maximum = bad_coordinates and nr == 0x41 and 0 or 20000
        buffer[0].resolution = 100
    else
        error("Unexpected ioctl request " .. nr)
    end
    return 0
end
function fakeC.read(fd, buffer, size)
    assert(fd >= 41)
    equal(size, realffi.sizeof("struct input_event") * 64)
    reads = reads + 1
    if malformed then return 1 end
    if fail_read then realffi.errno(19); return -1 end
    local frame = table.remove(frames, 1)
    if not frame then realffi.errno(11); return -1 end
    for index, value in ipairs(frame) do
        buffer[index - 1].type = value[1]
        buffer[index - 1].code = value[2]
        buffer[index - 1].value = value[3]
        buffer[index - 1].time.tv_sec = 10
        buffer[index - 1].time.tv_usec = 2000
    end
    return #frame * realffi.sizeof("struct input_event")
end

local fakeffi = setmetatable({ os = "Linux", C = fakeC }, { __index = realffi })
package.loaded.ffi = fakeffi
package.loaded["ffi/posix_h"] = true
package.loaded["ffi/linux_input_h"] = true
package.loaded.lfs = { dir = function() return function() return nil end end }
io.open = function(path, mode)
    if discovering and path == "/proc/bus/input/devices" then
        return {
            lines = function()
                local index = -1
                return function()
                    index = index + 1
                    if index <= 2 then return "H: Handlers=mouse0 event" .. index end
                end
            end,
            close = function() end,
        }
    end
    return savedopen(path, mode)
end

local ok, test_error = pcall(function()
    local Input = dofile("scribeink.koplugin/input.lua")
    local function open()
        local adapter, error_message = Input.open({ path = "/dev/input/fake-pen" })
        assert(adapter, error_message)
        return adapter
    end
    local function contact()
        return {{1,320,1}, {3,0,100}, {3,1,200}, {1,330,1}, {0,0,0}}
    end

    local adapter = open()
    equal(adapter.info.name, "WacomDigitizer")
    equal(adapter.info.has_rubber, true)
    equal(adapter.ranges.x.max, 20000)
    frames = { contact(), {{3,0,110}, {0,0,0}}, {{1,330,0}, {0,0,0}} }
    local output = {}
    equal(adapter:poll(function(event) output[#output + 1] = event end), 3)
    equal(output[1].phase, "down")
    equal(output[1].time, 10.002)
    equal(output[2].x, 110)
    equal(output[3].phase, "up")
    adapter:close()
    adapter:close()
    equal(closed, 1, "explicit close exactly once")

    -- Reopening also tests the private FFI struct declaration can be reused.
    adapter = open()
    frames = { contact(), {{3,0,999}, {0,0,0}} }
    output = {}
    equal(adapter:poll(function(event)
        output[#output + 1] = event
        adapter:close()
    end), 1, "callback can close capture")
    equal(#output, 1)
    equal(closed, 2)

    adapter = open()
    frames = { contact() }
    local callback_ok = pcall(function()
        adapter:poll(function() error("intentional callback failure") end)
    end)
    equal(callback_ok, false)
    equal(closed, 3, "callback failure closes descriptor")

    adapter = open()
    frames = { contact() }
    adapter:poll()
    fail_read = true
    output = {}
    local count, error_message = adapter:poll(function(event) output[#output + 1] = event end)
    equal(count, nil)
    assert(error_message:find("errno 19", 1, true))
    equal(output[1].cancelled, true)
    equal(closed, 4, "disconnect closes descriptor")
    fail_read = false

    adapter = open()
    malformed = true
    count = adapter:poll()
    equal(count, nil)
    equal(closed, 5, "malformed read closes descriptor")
    malformed = false

    bad_coordinates = true
    count = Input.open({ path = "/dev/input/fake-pen" })
    equal(count, nil)
    equal(closed, 6, "rejected device closes descriptor")
    bad_coordinates = false

    snapshot_touch = true
    adapter = open()
    frames = { {{3,0,20}, {3,1,30}, {0,0,0}}, {{1,330,0}, {0,0,0}}, contact() }
    output = {}
    equal(adapter:poll(function(event) output[#output + 1] = event end), 1)
    equal(output[1].phase, "down", "initial ongoing contact ignored")
    adapter:close()
    equal(closed, opened, "all descriptors closed")

    snapshot_touch = false
    discovering = true
    adapter = assert(Input.open())
    equal(adapter.info.path, "/dev/input/event2", "automatic mode prefers physical Wacom")
    equal(adapter.info.source_hint, "raw")
    equal(adapter.info.prefer_scaled, false)
    adapter:close()
    equal(closed, opened, "discovery closes rejected and lower priority devices")

    adapter = assert(Input.open({ prefer_scaled = true }))
    equal(adapter.info.path, "/dev/input/event1", "fallback mode prefers virtual stylus")
    equal(adapter.info.source_hint, "scaled")
    equal(adapter.info.prefer_scaled, true)
    adapter:close()
    equal(closed, opened, "fallback discovery closes all descriptors")

    discovering = false
    adapter = open()
    equal(adapter.info.has_stylus, true)
    equal(adapter.info.has_stylus2, true)
    equal(adapter.info.eraser_key, "BTN_TOOL_RUBBER")
    adapter:resetDiagnostics()
    frames = {
        {{1,321,1}, {3,24,15}, {3,0,300}, {3,1,400}, {0,0,0}},
        {{3,0,310}, {3,25,0}, {0,0,0}},
        {{3,24,0}, {1,321,0}, {0,0,0}},
    }
    output = {}
    equal(adapter:poll(function(event) output[#output + 1] = event end), 3,
        "real adapter rear pressure fallback")
    equal(output[1].eraser, true)
    equal(output[3].phase, "up")
    local text = adapter:diagnosticText()
    assert(text:find("BTN_TOOL_RUBBER: presses=1, releases=1, last=0", 1, true))
    assert(text:find("BTN_STYLUS2: presses=0, releases=0, last=unseen", 1, true))
    assert(text:find("ABS_PRESSURE: count=2, min=0, max=15, last=0", 1, true))
    assert(text:find("ABS_DISTANCE: count=1, min=0, max=0, last=0", 1, true))
    equal(adapter.diagnostics.frames, 3)
    equal(adapter.diagnostics.records, 11)
    adapter:resetDiagnostics()
    equal(adapter.diagnostics.records, 0, "diagnostic reset while capturing")
    equal(adapter.diagnostics.frames, 0)
    equal(#adapter.diagnostics.recent, 0)
    equal(adapter.diagnostics.initial.rubber, false)

    local observed = {}
    adapter:setRawObserver(function(event) observed[#observed + 1] = event end)
    frames = { {{1,332,1}, {3,24,20}, {0,0,0}} }
    equal(adapter:poll(), 0, "unconfigured STYLUS2 never changes default tool")
    equal(observed[1].name, "BTN_STYLUS2")
    equal(observed[1].value, 1)
    equal(#observed, 3, "observer sees raw events even with no decoded contact")
    adapter:resetDiagnostics()
    equal(adapter.diagnostics.initial.stylus2, true, "test start records a key already held")
    assert(adapter:diagnosticText():find("stylus2=true", 1, true))
    adapter:setRawObserver(nil)
    adapter:close()

    adapter = assert(Input.open({ path = "/dev/input/fake-pen", eraser_key = "BTN_STYLUS2" }))
    equal(adapter.info.eraser_key, "BTN_STYLUS2")
    frames = {
        {{1,332,1}, {3,0,100}, {3,1,200}, {3,24,20}, {0,0,0}},
        {{3,24,0}, {1,332,0}, {0,0,0}},
    }
    output = {}
    equal(adapter:poll(function(event) output[#output + 1] = event end), 2)
    equal(output[1].eraser, true)
    equal(output[2].phase, "up")
    -- Diagnostic storage is bounded even for unexpected driver codes.
    for index = 1, 1000 do adapter:recordRaw(1, index, index % 2, 1) end
    equal(adapter.diagnostics.kinds, 64)
    equal(#adapter.diagnostics.recent, 24)
    adapter:close()
    equal(closed, opened, "diagnostic adapters close every descriptor")
end)

package.loaded.ffi = savedffi
package.loaded["ffi/posix_h"] = savedposix
package.loaded["ffi/linux_input_h"] = savedinput
package.loaded.lfs = savedlfs
io.open = savedopen
assert(ok, test_error)
return assertions
