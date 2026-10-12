-- SPDX-License-Identifier: AGPL-3.0-or-later
-- KOReader v2026.07.1 exposes a callback before its gesture detector.
-- Use the dedicated pen slot, since tool=2 in a finger slot may be palm rejection.
local CoreInput = {}
local Handle = {}
Handle.__index = Handle

local function dropContact(input, slot)
    local detector = input.gesture_detector
    if not detector or type(detector.getContact) ~= "function"
        or type(detector.dropContact) ~= "function" then return end
    local contact = detector:getContact(slot)
    if contact then detector:dropContact(contact) end
end

function Handle:dropFingerContacts()
    local detector = self.input.gesture_detector
    if not detector or type(detector.active_contacts) ~= "table"
        or type(detector.dropContact) ~= "function" then return end
    local contacts = {}
    for slot, contact in pairs(detector.active_contacts) do
        if slot ~= self.input.pen_slot then contacts[#contacts + 1] = contact end
    end
    -- dropContact cancels the contact's hold/double-tap timers in KOReader.
    for _, contact in ipairs(contacts) do detector:dropContact(contact) end
end

function Handle:isPenNear()
    return not self.closed and self.near or false
end

function CoreInput.install(input, config)
    config = config or {}
    if not input or type(input.registerStylusCallback) ~= "function"
        or type(input.unregisterStylusCallback) ~= "function"
        or type(input.pen_slot) ~= "number" then
        return nil, "KOReader's dedicated stylus callback API is unavailable."
    end
    local self = setmetatable({ input = input, previous = input.stylus_callback,
        is_active = config.isActive or function() return true end,
        on_proximity = config.onPenProximity, near = false }, Handle)
    local existing = input.ev_slots and input.ev_slots[input.pen_slot]
    if existing then self.near = existing.tool == 1 or existing.tool == 2 or existing.tool == 3 end
    self.callback = function(this, slot)
        if not self.closed and slot.slot == this.pen_slot then
            local active = self.is_active()
            local near = slot.tool == 1 or slot.tool == 2 or slot.tool == 3
            if near ~= self.near then
                self.near = near
                -- Cancel palms already down and their timers on both edges.
                -- Modal/inactive input retains KOReader's normal behavior.
                if active then self:dropFingerContacts() end
                if self.on_proximity then self.on_proximity(near) end
            end
            if active then
                -- Clear a pen contact created before capture or in a dialog,
                -- including its timers, before suppressing this input frame.
                dropContact(this, this.pen_slot)
                return true
            end
        end
        if self.previous then return self.previous(this, slot) end
    end
    input:registerStylusCallback(self.callback)
    if self.is_active() then
        dropContact(input, input.pen_slot)
        if self.near then self:dropFingerContacts() end
    end
    return self
end

function Handle:close()
    if self.closed then return end
    self.closed = true
    self.near = false
    -- Another plugin may have registered a callback since ours. Only restore
    -- the callback if the currently installed one is still owned by this handle.
    if self.input.stylus_callback == self.callback then
        if self.previous then self.input:registerStylusCallback(self.previous)
        else self.input:unregisterStylusCallback() end
    end
end

return CoreInput
