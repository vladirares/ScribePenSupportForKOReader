-- Recorded-protocol tests; no claim of physical Kindle validation.
local Input = dofile("scribeink.koplugin/input.lua")
local C = Input.codes
local checks = 0

local function equal(actual, expected, label)
    checks = checks + 1
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function harness(config)
    local decoder, output = Input.newDecoder(config), {}
    local function callback(event) output[#output + 1] = event end
    local function feed(kind, code, value)
        return decoder:feed(kind, code, value, #output + 0.125, callback)
    end
    local function report() return feed(C.EV_SYN, C.SYN_REPORT, 0) end
    return decoder, output, feed, report, callback
end

-- Hover, contact, coordinate-only updates, pressure-only updates, lift and hover.
do
    local _, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_ABS, C.ABS_X, 450)
    feed(C.EV_ABS, C.ABS_Y, 700)
    report()
    equal(#out, 0, "hover emits no ink")
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    feed(C.EV_ABS, C.ABS_PRESSURE, 230)
    report()
    equal(#out, 1, "contact starts one stroke")
    equal(out[1].phase, "down")
    equal(out[1].x, 450)
    equal(out[1].eraser, false)
    feed(C.EV_ABS, C.ABS_X, 460)
    report()
    equal(out[2].phase, "move")
    equal(out[2].y, 700, "unchanged Y is preserved")
    feed(C.EV_ABS, C.ABS_PRESSURE, 400)
    report()
    equal(out[3].pressure, 400)
    report()
    equal(#out, 3, "empty frames do not duplicate samples")
    feed(C.EV_KEY, C.BTN_TOUCH, 0)
    feed(C.EV_ABS, C.ABS_PRESSURE, 0)
    report()
    equal(out[4].phase, "up")
    feed(C.EV_ABS, C.ABS_X, 480)
    report()
    equal(#out, 4, "hover after lift emits no ink")
end

-- BTN_TOUCH can precede coordinates in the same frame. Never emit partial data.
do
    local _, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    equal(#out, 0, "contact without coordinates")
    feed(C.EV_ABS, C.ABS_X, 100)
    report()
    equal(#out, 0, "contact without Y")
    feed(C.EV_ABS, C.ABS_Y, 200)
    report()
    equal(out[1].phase, "down")
    equal(out[1].x, 100)
    equal(out[1].y, 200)
end

-- The physical rubber tool works independently of the pen's barrel button.
do
    local _, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_RUBBER, 1)
    feed(C.EV_ABS, C.ABS_X, 1000)
    feed(C.EV_ABS, C.ABS_Y, 2000)
    report()
    equal(#out, 0, "rubber hover")
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    equal(out[1].eraser, true, "rubber down")
    feed(C.EV_ABS, C.ABS_X, 1020)
    report()
    equal(out[2].eraser, true, "rubber motion")
    feed(C.EV_KEY, C.BTN_TOUCH, 0)
    feed(C.EV_KEY, C.BTN_TOOL_RUBBER, 0)
    report()
    equal(out[3].phase, "up")
    equal(out[3].eraser, true, "up retains previous tool")
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_KEY, C.BTN_STYLUS, 1)
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    equal(out[4].eraser, false, "barrel button does not replace rubber by default")
end

-- Tool changes terminate one stroke before beginning another.
do
    local _, out, feed, report = harness({ barrel_eraser = true })
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_ABS, C.ABS_X, 10)
    feed(C.EV_ABS, C.ABS_Y, 20)
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    feed(C.EV_KEY, C.BTN_STYLUS, 1)
    report()
    equal(#out, 3)
    equal(out[2].phase, "up")
    equal(out[2].eraser, false)
    equal(out[3].phase, "down")
    equal(out[3].eraser, true)
end

-- Devices lacking BTN_TOUCH use pressure, but pressure from an unrelated source
-- does not start a stroke without pen proximity.
do
    local _, out, feed, report = harness({ has_touch = false })
    feed(C.EV_ABS, C.ABS_X, 1)
    feed(C.EV_ABS, C.ABS_Y, 2)
    feed(C.EV_ABS, C.ABS_PRESSURE, 5)
    report()
    equal(#out, 0)
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_ABS, C.ABS_PRESSURE, 5)
    report()
    equal(out[1].phase, "down")
    feed(C.EV_ABS, C.ABS_PRESSURE, 0)
    report()
    equal(out[2].phase, "up")
end

-- Loss of proximity ends contact even if a buggy stream omits BTN_TOUCH release.
do
    local _, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    feed(C.EV_ABS, C.ABS_X, 1)
    feed(C.EV_ABS, C.ABS_Y, 2)
    report()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 0)
    report()
    equal(out[2].phase, "up")
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    report()
    equal(#out, 2, "stale contact does not turn the next hover into ink")
end

-- evdev overrun cancels the stroke and ignores data through the next SYN_REPORT.
-- Query snapshots block a contact that was already down until it releases.
do
    local decoder, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    feed(C.EV_ABS, C.ABS_X, 1)
    feed(C.EV_ABS, C.ABS_Y, 2)
    report()
    feed(C.EV_SYN, C.SYN_DROPPED, 0)
    equal(out[2].phase, "up")
    equal(out[2].cancelled, true)
    equal(out[2].reason, "input_overrun")
    feed(C.EV_ABS, C.ABS_X, 99)
    equal(report(), "resync")
    equal(#out, 2, "lost frame ignored")
    decoder:sync({ x = 50, y = 60, pen = true, touch = true, pressure = 3 })
    feed(C.EV_ABS, C.ABS_X, 51)
    report()
    equal(#out, 2, "incomplete contact not resumed")
    feed(C.EV_KEY, C.BTN_TOUCH, 0)
    report()
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    equal(out[3].phase, "down")
    equal(out[3].x, 51)
end

-- Opening while a pen is down never paints an accidental partial stroke.
do
    local decoder, out, feed, report, callback = harness()
    decoder:sync({ x = 50, y = 60, rubber = true, touch = true })
    report()
    equal(#out, 0)
    feed(C.EV_KEY, C.BTN_TOUCH, 0)
    report()
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    equal(out[1].eraser, true)
    decoder:cancel(callback, "test")
    decoder:cancel(callback, "test")
    equal(#out, 2, "cancel is idempotent")
end

-- Rear-tool pressure can establish contact even on streams which advertise
-- BTN_TOUCH but do not set it for the rubber. Hover pressure zero cannot erase.
do
    local _, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_RUBBER, 1)
    feed(C.EV_ABS, C.ABS_X, 100)
    feed(C.EV_ABS, C.ABS_Y, 200)
    feed(C.EV_ABS, C.ABS_PRESSURE, 0)
    report()
    equal(#out, 0, "rear hover is not contact")
    feed(C.EV_ABS, C.ABS_PRESSURE, 45)
    report()
    equal(out[1].phase, "down", "rubber pressure without BTN_TOUCH")
    equal(out[1].eraser, true)
    feed(C.EV_ABS, C.ABS_X, 110)
    report()
    equal(out[2].phase, "move")
    feed(C.EV_ABS, C.ABS_PRESSURE, 0)
    report()
    equal(out[3].phase, "up")
    feed(C.EV_ABS, C.ABS_X, 999)
    report()
    equal(#out, 3, "rear hover after lift cannot erase")
end

-- The pressure fallback must not change ordinary pen-contact interpretation.
do
    local _, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_ABS, C.ABS_X, 100)
    feed(C.EV_ABS, C.ABS_Y, 200)
    feed(C.EV_ABS, C.ABS_PRESSURE, 45)
    report()
    equal(#out, 0, "ordinary pen still requires advertised BTN_TOUCH")
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    equal(out[1].eraser, false)
end

-- Alternative hardware signals are opt-in. Either configured stylus key can
-- identify an eraser even if the rear stream omits both native tool keys.
for _, signal in ipairs{ "BTN_STYLUS", "BTN_STYLUS2" } do
    local _, out, feed, report = harness({ eraser_key = signal })
    feed(C.EV_KEY, C[signal], 1)
    feed(C.EV_ABS, C.ABS_X, 100)
    feed(C.EV_ABS, C.ABS_Y, 200)
    report()
    equal(#out, 0, signal .. " alone does not establish contact")
    feed(C.EV_ABS, C.ABS_PRESSURE, 10)
    report()
    equal(out[1].phase, "down")
    equal(out[1].eraser, true)
    feed(C.EV_KEY, C[signal], 0)
    report()
    equal(out[2].phase, "up")
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    report()
    equal(out[3].eraser, false, "ordinary tip still writes after selected signal release")
end

do
    local _, out, feed, report = harness()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1)
    feed(C.EV_KEY, C.BTN_STYLUS2, 1)
    feed(C.EV_KEY, C.BTN_TOUCH, 1)
    feed(C.EV_ABS, C.ABS_X, 100)
    feed(C.EV_ABS, C.ABS_Y, 200)
    report()
    equal(out[1].eraser, false, "STYLUS2 is not guessed as rubber by default")
end

do
    local decoder, out, feed, report = harness({ eraser_key = "BTN_STYLUS2", pressure_threshold = 5 })
    decoder:sync({ x = 100, y = 200, barrel2 = true, pressure = 10 })
    report()
    equal(#out, 0, "sync blocks already active configured rear contact")
    feed(C.EV_ABS, C.ABS_PRESSURE, 5)
    report()
    equal(#out, 0, "minimum pressure is not contact")
    feed(C.EV_ABS, C.ABS_PRESSURE, 6)
    report()
    equal(out[1].eraser, true)
end

-- Replay the ordered key transitions in the user's FW 5.19.6 diagnostic:
-- two rubber contacts, one tip contact, six more rubber contacts, then hover.
-- The diagnostic contains summaries rather than complete frames; pressure/X/Y
-- samples below are representative values within its observed ranges.
do
    local decoder, out, feed, report = harness()
    feed(C.EV_ABS, C.ABS_X, 7053)
    feed(C.EV_ABS, C.ABS_Y, 10530)
    local function contacts(count)
        for _ = 1, count do
            feed(C.EV_KEY, C.BTN_TOUCH, 1)
            feed(C.EV_ABS, C.ABS_PRESSURE, 3472)
            report()
            feed(C.EV_KEY, C.BTN_TOUCH, 0)
            feed(C.EV_ABS, C.ABS_PRESSURE, 0)
            report()
        end
    end
    feed(C.EV_KEY, C.BTN_TOOL_RUBBER, 1); report()
    contacts(2)
    feed(C.EV_KEY, C.BTN_TOOL_RUBBER, 0); report()
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 1); report()
    contacts(1)
    feed(C.EV_KEY, C.BTN_TOOL_PEN, 0); report()
    feed(C.EV_KEY, C.BTN_TOOL_RUBBER, 1); report()
    contacts(6)
    local rubber_down, pen_down, up = 0, 0, 0
    for _, event in ipairs(out) do
        if event.phase == "down" then
            if event.eraser then rubber_down = rubber_down + 1 else pen_down = pen_down + 1 end
        elseif event.phase == "up" then up = up + 1 end
    end
    equal(rubber_down, 8, "all observed rear contacts decode as eraser")
    equal(pen_down, 1, "observed tip contact decodes as pen")
    equal(up, 9, "all contacts release")
    equal(decoder:isToolPresent(), true, "last logged rear hover remains in proximity")
    equal(decoder:isContact(), false, "last logged rear hover is lifted")
end

-- Tool-key chatter must not turn a held physical rear eraser into a pen.
-- Releasing a contact emits UP once, then a later hover, never both at once.
do
    local _, out, feed, report = harness({ emit_hover=true })
    feed(C.EV_KEY,C.BTN_TOOL_RUBBER,1)
    feed(C.EV_ABS,C.ABS_X,100)
    feed(C.EV_ABS,C.ABS_Y,200)
    report()
    equal(#out,1,"proximity produces exactly one noncontact preview")
    equal(out[1].phase,"hover")
    equal(out[1].eraser,true)
    feed(C.EV_KEY,C.BTN_TOUCH,1)
    report()
    equal(out[2].phase,"down")
    equal(out[2].eraser,true)
    feed(C.EV_KEY,C.BTN_TOOL_RUBBER,0)
    feed(C.EV_KEY,C.BTN_TOOL_PEN,1)
    report()
    equal(out[3].phase,"move","temporary tool-key switch does not split contact")
    equal(out[3].eraser,true,"temporary pen key does not turn rubber into ink")
    feed(C.EV_ABS,C.ABS_X,115)
    report()
    equal(out[4].phase,"move")
    equal(out[4].eraser,true)
    feed(C.EV_KEY,C.BTN_TOUCH,0)
    report()
    equal(#out,5,"release does not also emit hover")
    equal(out[5].phase,"up")
    equal(out[5].eraser,true)
    feed(C.EV_ABS,C.ABS_X,120)
    report()
    equal(out[6].phase,"hover","moving in air after release previews the new tool")
    equal(out[6].eraser,false)
end
return checks
