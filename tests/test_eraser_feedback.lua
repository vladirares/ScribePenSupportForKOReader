-- Hover feedback and rear-key glitches; no Kindle/evdev hardware needed.
local Input = dofile("scribeink.koplugin/input.lua")
local C = Input.codes
local decoder = Input.newDecoder({ emit_hover = true })
local events = {}
local function cb(event) events[#events + 1] = event end
local function feed(kind,code,value)
    decoder:feed(kind,code,value,#events+0.1,cb)
end
local function report() feed(C.EV_SYN,C.SYN_REPORT,0) end
feed(C.EV_KEY,C.BTN_TOOL_RUBBER,1)
feed(C.EV_ABS,C.ABS_X,100)
feed(C.EV_ABS,C.ABS_Y,200)
report()
assert(#events == 1 and events[1].phase == "hover" and events[1].eraser)
feed(C.EV_ABS,C.ABS_PRESSURE,20)
report()
assert(#events == 2 and events[2].phase == "down" and events[2].eraser)
-- A one-frame BTN_TOOL_RUBBER drop must not interrupt a pressured contact.
feed(C.EV_KEY,C.BTN_TOOL_RUBBER,0)
feed(C.EV_ABS,C.ABS_X,110)
report()
assert(#events == 3 and events[3].phase == "move" and events[3].eraser)
feed(C.EV_KEY,C.BTN_TOOL_RUBBER,1)
feed(C.EV_ABS,C.ABS_PRESSURE,0)
report()
assert(#events == 5 and events[4].phase == "up" and events[5].phase == "hover")
feed(C.EV_KEY,C.BTN_TOOL_RUBBER,0)
report()
assert(events[#events].phase == "leave")
return #events
