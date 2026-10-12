local CoreInput = dofile("scribeink.koplugin/coreinput.lua")
local checks = 0
local function equal(actual, expected, label)
    checks = checks + 1
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local active, old_calls, dropped, registrations, unregistrations = true, 0, {}, 0, 0
local previous = function(_, slot) old_calls = old_calls + 1; return slot.slot == 7 end
local detector = { active_contacts = {} }
function detector:getContact(slot) return self.active_contacts[slot] end
function detector:dropContact(contact)
    dropped[#dropped + 1] = contact.slot
    contact.pending_hold_timer, contact.pending_double_tap_timer = nil, nil
    self.active_contacts[contact.slot] = nil
end
local input = { pen_slot = 4, stylus_callback = previous, gesture_detector = detector }
function input:registerStylusCallback(callback)
    registrations = registrations + 1
    self.stylus_callback = callback
end
function input:unregisterStylusCallback()
    unregistrations = unregistrations + 1
    self.stylus_callback = nil
end
local function contact(slot)
    local c = { slot = slot, pending_hold_timer = true, pending_double_tap_timer = true }
    detector.active_contacts[slot] = c
    return c
end
local stale_pen = contact(4)
local changes = {}
local handle = assert(CoreInput.install(input, {
    isActive = function() return active end,
    onPenProximity = function(near) changes[#changes + 1] = near end,
}))
equal(registrations, 1)
equal(detector:getContact(4), nil, "install cancels a stale native pen contact")
equal(stale_pen.pending_hold_timer, nil)
equal(handle:isPenNear(), false)
equal(input.stylus_callback(input, { slot = 0, tool = 0 }), false, "ordinary finger delegates")
equal(old_calls, 1)
equal(input.stylus_callback(input, { slot = 0, tool = 2 }), false, "palm tool code is not a pen slot")
equal(handle:isPenNear(), false)
equal(input.stylus_callback(input, { slot = 7, tool = 2 }), true, "previous plugin retains its other-slot behavior")

local palm0, palm1 = contact(0), contact(1)
equal(input.stylus_callback(input, { slot = 4, tool = 1, id = 4 }), true, "capture swallows native tip gesture")
equal(handle:isPenNear(), true)
equal(#changes, 1)
equal(changes[1], true)
equal(detector:getContact(0), nil)
equal(detector:getContact(1), nil)
equal(palm0.pending_hold_timer, nil, "proximity entry cancels palm hold")
equal(palm1.pending_double_tap_timer, nil, "proximity entry cancels delayed palm tap")
equal(input.stylus_callback(input, { slot = 4, tool = 2, id = 4 }), true, "capture swallows native rubber gesture")
equal(#changes, 1, "tip-to-rubber does not fabricate proximity exit")

local palm_after_entry = contact(2)
equal(input.stylus_callback(input, { slot = 4, tool = 0, id = -1 }), true)
equal(handle:isPenNear(), false)
equal(changes[2], false)
equal(detector:getContact(2), nil, "proximity exit cancels remaining palm timer")
equal(palm_after_entry.pending_hold_timer, nil)

active = false
local dialog_finger = contact(0)
equal(input.stylus_callback(input, { slot = 4, tool = 1, id = 4 }), false,
    "modal/inactive capture delegates pen input to previous callback")
equal(handle:isPenNear(), true, "modal pen proximity is still tracked")
equal(detector:getContact(0), dialog_finger, "modal fingers retain native timers")
local modal_pen = contact(4)
active = true
equal(input.stylus_callback(input, { slot = 4, tool = 1, id = 4 }), true)
equal(detector:getContact(4), nil, "returning to capture cancels native modal pen contact")
equal(modal_pen.pending_hold_timer, nil)

local keep_pen = contact(4)
contact(0); contact(1)
handle:dropFingerContacts()
equal(detector:getContact(0), nil)
equal(detector:getContact(1), nil)
equal(detector:getContact(4), keep_pen, "explicit palm clearing preserves designated pen contact")
handle:close()
equal(input.stylus_callback, previous, "close restores previous callback")
equal(handle:isPenNear(), false)
local before = registrations
handle:close()
equal(registrations, before, "close is idempotent")

input.stylus_callback = nil
handle = assert(CoreInput.install(input))
local other = function() return true end
input:registerStylusCallback(other)
handle:close()
equal(input.stylus_callback, other, "close cannot overwrite a later callback owner")
input.stylus_callback = nil
handle = assert(CoreInput.install(input))
handle:close()
equal(unregistrations, 1, "close unregisters when no earlier callback existed")

input.ev_slots = { [4] = { slot = 4, tool = 2 } }
local already_down_palm = contact(0)
handle = assert(CoreInput.install(input))
equal(handle:isPenNear(), true, "install recognizes a tool already hovering before capture")
equal(detector:getContact(0), nil)
equal(already_down_palm.pending_hold_timer, nil)
handle:close()

local unsupported, error_message = CoreInput.install({ pen_slot = 4 })
equal(unsupported, nil)
equal(type(error_message), "string", "unsupported APIs fail explicitly")
return checks
