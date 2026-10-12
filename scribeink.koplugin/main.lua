-- SPDX-License-Identifier: AGPL-3.0-or-later
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Event = require("ui/event")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local time = require("ui/time")
local gettext = require("gettext")
local Screen = Device.screen
local directory = debug.getinfo(1,"S").source:sub(2):match("^(.*)[/\\]")
local Geometry = dofile(directory .. "/geometry.lua")
local Calibration = dofile(directory .. "/calibration.lua")
local Render = dofile(directory .. "/render.lua")
local Store = dofile(directory .. "/store.lua")
local PenInput = dofile(directory .. "/input.lua")
local Pdf = dofile(directory .. "/pdf.lua")
local Toolbar = dofile(directory .. "/toolbar.lua")
local CoreInput = dofile(directory .. "/coreinput.lua")

local Ink = WidgetContainer:extend{name="scribeink",is_doc_only=true,settings_key="scribeink"}
local Overlay = InputContainer:extend{covers_fullscreen=false,stop_events_propagation=true}
local PEN_WIDTHS = {0.75,1.25,2,3}

local function message(text)
    UIManager:show(InfoMessage:new{text=text})
end

function Ink:init()
    self.settings = G_reader_settings:readSetting("scribeink",{})
    self.settings.width = self.settings.width or 1.25
    if type(self.settings.width) ~= "number" or self.settings.width <= 0
        or self.settings.width > 10 or self.settings.width ~= self.settings.width then
        self.settings.width = 1.25
    end
    self.settings.calibrations = self.settings.calibrations or {}
    self.settings.persistent_toolbar=true
    -- Finger navigation and pen capture now coexist; migrate the old toggle.
    self.settings.auto_write=true
    self.selected_tool="pen"
    self.ui.menu:registerToMainMenu(self)
    if self.ui.document and self.ui.document.is_pdf then
        -- Saved ink is painted with the page, underneath the floating dock.
        self.ui.view:registerViewModule("scribeink",{
            paintTo=function(_,bb,x,y) self:paintInk(bb,x,y) end,
        })
        -- KOReader embeds its own highlights when closing the document. Keep
        -- the sidecar's source identity in sync with this known internal write.
        -- CloseDocument is emitted before that write, so this wrapper must
        -- stay on the document until the final native close completes.
        local document = self.ui.document
        local writer = document.writeDocument
        if writer then
            document.writeDocument = function(doc,...)
                local matches,reason
                if self.store then
                    self:finishStroke()
                    matches,reason = self.store:sourceMatches()
                    self:saveInk()
                end
                local result = writer(doc,...)
                if self.store and matches then
                    local adopted,err = self.store:adoptSourceWrite()
                    if adopted then self:saveInk()
                    else logger.err("Scribe Ink could not follow PDF save:",err); message(tostring(err)) end
                elseif self.store then
                    logger.err("Scribe Ink original changed before KOReader save:",reason)
                end
                return result
            end
        end
    end
end

function Ink:saveSettings()
    G_reader_settings:saveSetting("scribeink",self.settings)
end

function Ink:setPenWidth(value)
    if type(value)~="number" or value~=value or value<=0 or value>10 then return false end
    self:finishStroke()
    self.settings.width=value
    self:saveSettings()
    return true
end

function Ink:discardDialogPenInput()
    local adapter=self.adapter
    if not adapter then return end
    -- The native dialog can handle a tap before our independent raw descriptor
    -- has read it. Discard that backlog while the dialog still covers the page,
    -- then block any contact still down until it lifts.
    local okay,err=pcall(function()
        local result,poll_error=adapter:poll(function() end)
        if result==nil then error(poll_error or "Cannot drain dialog pen input.") end
        local synced,sync_error=adapter:resync()
        if not synced then error(sync_error or "Cannot synchronize dialog pen input.") end
    end)
    self.suppressed,self.toolbar_contact=false,nil
    if not okay then
        self:stopWriting()
        logger.err("Scribe Ink dialog pen input:",err)
        message(gettext("Pen input stopped: ")..tostring(err))
    end
end

function Ink:closePenWidthPicker(discard_pending)
    local dialog=self.width_dialog; self.width_dialog=nil
    if dialog and discard_pending~=false then self:discardDialogPenInput() end
    if dialog and UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
end

function Ink:showPenWidthPicker()
    self:selectTool("pen")
    if self.calibration or self.eraser_test or self.closing then return end
    if self.width_dialog and UIManager:isWidgetShown(self.width_dialog) then return end
    local dialog,buttons=nil,{}
    for _,width in ipairs(PEN_WIDTHS) do
        local value=width
        buttons[#buttons+1]={{
            text=(self.settings.width==value and "✓ " or "")..tostring(value)..gettext(" pt"),
            callback=function()
                self:setPenWidth(value)
                self:closePenWidthPicker()
            end,
        }}
    end
    buttons[#buttons+1]={{text=gettext("Close"),callback=function() self:closePenWidthPicker() end}}
    dialog=ButtonDialog:new{
        title=gettext("Pen width"),width_factor=0.5,buttons=buttons,
        tap_close_callback=function()
            if self.width_dialog==dialog then
                self.width_dialog=nil
                self:discardDialogPenInput()
            end
        end,
    }
    self.width_dialog=dialog
    UIManager:show(dialog)
end

function Ink:setInputOption(key,value)
    local restart=self.writing
    if restart then self:stopWriting() end
    self.settings.input=self.settings.input or {}
    self.settings.input[key]=value
    self:saveSettings()
    if restart then UIManager:nextTick(function() if not self.closing then self:startWriting() end end) end
end

function Ink:addToMainMenu(items)
    local widths = {}
    for _,width in ipairs(PEN_WIDTHS) do
        local value = width
        widths[#widths+1] = {
            text=tostring(value)..gettext(" pt"),
            checked_func=function() return self.settings.width == value end,
            callback=function() self:setPenWidth(value) end,
        }
    end
    items.scribeink = {
        text=gettext("Scribe Ink"),sorting_hint="more_tools",
        enabled_func=function() return self.ui.document and self.ui.document.is_pdf end,
        sub_item_table={
            {text=gettext("Show pen controls"),callback=function()
                -- Allow the invoking menu to finish closing first.
                UIManager:nextTick(function()
                    self:showToolbar()
                    if self.overlay and self.overlay.toolbar.collapsed then self.overlay:activate("collapse") end
                    self:startWriting()
                end)
            end},
            {text=gettext("Export annotated PDF copy"),callback=function() self:exportPDF() end},
            {text=gettext("Pen width"),sub_item_table=widths},
            {text=gettext("Rear eraser signal"),sub_item_table={}},
            {text=gettext("Pen input source"),sub_item_table={
                {text=gettext("Automatic (prefer raw Wacom)"),
                    checked_func=function() return not (self.settings.input and self.settings.input.prefer_scaled) end,
                    callback=function() self:setInputOption("prefer_scaled",false) end},
                {text=gettext("Prefer scaled virtual pen (fallback)"),
                    checked_func=function() return self.settings.input and self.settings.input.prefer_scaled end,
                    callback=function() self:setInputOption("prefer_scaled",true) end},
            }},
            {text=gettext("Recalibrate pen"),callback=function()
                UIManager:nextTick(function() self:startWriting(true) end)
            end},
            {text=gettext("Diagnostics"),callback=function() self:diagnostics() end},
            {text=gettext("Test rear eraser (10 seconds)"),callback=function()
                UIManager:nextTick(function() self:testEraser() end)
            end},
        },
    }
    for _,entry in ipairs(items.scribeink.sub_item_table) do
        if entry.text==gettext("Rear eraser signal") then
            for _,choice in ipairs{{"BTN_TOOL_RUBBER",gettext("Rear rubber tool (default)")},
                {"BTN_STYLUS",gettext("Stylus button 1")},{"BTN_STYLUS2",gettext("Stylus button 2")}} do
                local key=choice[1]
                entry.sub_item_table[#entry.sub_item_table+1]={text=choice[2],
                    checked_func=function() return (self.settings.input and self.settings.input.eraser_key or "BTN_TOOL_RUBBER")==key end,
                    callback=function() self:setInputOption("eraser_key",key) end}
            end
        end
    end
end

function Ink:ensureStore()
    if self.store then return true end
    local store,err = Store.open(self.ui.document.file)
    if not store then message(gettext("Scribe Ink: ")..tostring(err)); return nil end
    self.store = store
    if err then message(err) end
    return true
end

function Ink:onReaderReady()
    if not self.ui.document.is_pdf then return end
    local file = io.open(self.ui.document.file..".scribeink.json","rb")
    local backup = io.open(self.ui.document.file..".scribeink.json.bak","rb")
    local temporary = io.open(self.ui.document.file..".scribeink.json.tmp","rb")
    if file then file:close() end
    if backup then backup:close() end
    if temporary then temporary:close() end
    self.ready_task=function()
        self.ready_task=nil
        if self.closing then return end
        if self.settings.persistent_toolbar then self:showToolbar() end
        if file or backup or temporary then self:ensureStore(); UIManager:setDirty(self.ui,"partial") end
        self:startWriting(false,true)
    end
    -- ReaderReady runs before the fullscreen ReaderUI is shown.
    UIManager:nextTick(self.ready_task)
end

function Ink:showToolbar()
    if self.overlay or self.closing or not self.ui.document or not self.ui.document.is_pdf then return end
    self.overlay=Overlay:new{owner=self,dimen=Screen:getSize()}
    UIManager:show(self.overlay)
    UIManager:setDirty(self.ui,"partial")
end

function Ink:hideToolbar()
    self:closePenWidthPicker(false)
    local overlay=self.overlay; self.overlay=nil
    if overlay then UIManager:close(overlay); overlay:free() end
end

function Ink:checkView()
    local doc,view = self.ui.document,self.ui.view
    if not doc or not doc.is_pdf then return nil,gettext("Open a PDF first.") end
    if doc.configurable and doc.configurable.text_wrap == 1 then
        return nil,gettext("Turn PDF reflow off before writing.")
    end
    if view.page_scroll then return nil,gettext("Choose single-page view before writing.") end
    if not view.state or (view.state.rotation or 0) ~= 0 then
        return nil,gettext("Set PDF page rotation to 0 before writing. Screen rotation is supported after calibration.")
    end
    if not view.state.offset or not view.state.page or not view.state.zoom
        or view.state.zoom <= 0 then return nil,gettext("The PDF view is not ready yet.") end
    return true
end

function Ink:transform()
    local view = self.ui.view
    return {zoom=view.state.zoom,offset={x=view.state.offset.x,y=view.state.offset.y},
        visible={x=view.visible_area.x,y=view.visible_area.y},page=view.state.page}
end

function Ink:clip()
    local view = self.ui.view
    local left = math.max(0,view.state.offset.x)
    local top = math.max(0,view.state.offset.y)
    local right = math.min(Screen:getWidth(),view.state.offset.x+view.visible_area.w)
    local bottom = math.min(Screen:getHeight(),view.state.offset.y+view.visible_area.h)
    return {x=left,y=top,w=math.max(0,right-left),h=math.max(0,bottom-top)}
end

-- Use exactly the same physical screen radius for the outline and erasing.
function Ink:eraserRadius()
    return Screen:scaleBySize(10)+1
end
local function unionRect(a,b)
    if not a then return b end
    if not b then return a end
    local x,y=math.min(a.x,b.x),math.min(a.y,b.y)
    return {x=x,y=y,w=math.max(a.x+a.w,b.x+b.w)-x,
        h=math.max(a.y+a.h,b.y+b.h)-y}
end
function Ink:cursorRect(cursor)
    if not cursor then return nil end
    local radius=cursor.radius+4
    local x=math.max(0,math.floor(cursor.x-radius))
    local y=math.max(0,math.floor(cursor.y-radius))
    local right=math.min(Screen:getWidth(),math.ceil(cursor.x+radius+1))
    local bottom=math.min(Screen:getHeight(),math.ceil(cursor.y+radius+1))
    if right<=x or bottom<=y then return nil end
    return {x=x,y=y,w=right-x,h=bottom-y}
end
-- Draw outlines only. paintCircle is a FILLED disc in KOReader and would
-- cover underlying ink, misleading the user about what will be deleted.
local function drawCircleOutline(bb,cx,cy,r,color)
    local inner=(r-1)*(r-1)
    for dy=-r,r do
        local dx=math.floor(math.sqrt(math.max(0,r*r-dy*dy)))
        local ix=-1
        if math.abs(dy)<r then
            ix=math.floor(math.sqrt(math.max(0,inner-dy*dy)))
        end
        local width=math.max(1,dx-ix)
        bb:paintRect(cx-dx,cy+dy,width,1,color)
        bb:paintRect(cx+ix+1,cy+dy,width,1,color)
    end
end
function Ink:paintEraserCursor(bb,x,y)
    local cursor=self.eraser_cursor
    if not cursor then return end
    local cx,cy=math.floor(cursor.x+(x or 0)+0.5),math.floor(cursor.y+(y or 0)+0.5)
    -- White halo and dark ring; keep the center of the rubber transparent.
    drawCircleOutline(bb,cx,cy,cursor.radius+1,Blitbuffer.COLOR_WHITE)
    drawCircleOutline(bb,cx,cy,cursor.radius,Blitbuffer.COLOR_BLACK)
end
-- Recompose from the clean PDF snapshot, not from a screenshot containing old
-- ink. Both the cut and the cursor move are painted into Screen.bb immediately.
function Ink:updateEraserCursor(screen,changed_bounds,transform)
    local old=self.eraser_cursor
    local cursor
    if screen then
        local clip=self:clip()
        local r=self:eraserRadius()
        if Geometry.intersectsBounds({x=screen.x-r,y=screen.y-r,w=2*r,h=2*r},clip)
            and not self.overlay.toolbar:hitTest(screen.x,screen.y) then
            cursor={x=screen.x,y=screen.y,radius=r}
        end
    end
    local changed_rect
    if changed_bounds then
        transform=transform or self:transform()
        local a=Geometry.pageToScreen(changed_bounds,transform)
        local b={x=a.x+changed_bounds.w*transform.zoom,y=a.y+changed_bounds.h*transform.zoom}
        changed_rect=Render.bounds(a,b,4,self:clip())
    end
    -- No repaint for repeated contact samples at an unchanged location.
    -- In particular, hovering must never drive screen refreshes.
    local cursor_rect=unionRect(self:cursorRect(old),self:cursorRect(cursor))
    if self.stroke and self.stroke.eraser and cursor_rect then
        -- Include the whole transient outline trail in the one quiet cleanup.
        self.eraser_cleanup_rect=unionRect(self.eraser_cleanup_rect,cursor_rect)
    end
    if not changed_rect and old and cursor and old.x==cursor.x and old.y==cursor.y
        and old.radius==cursor.radius then return end
    local rect=unionRect(cursor_rect,changed_rect)
    self.eraser_cursor=cursor
    if not rect then return end
    if changed_rect then
        -- One high-quality cleanup per gesture, not one per position sample.
        self.eraser_cleanup_rect=unionRect(self.eraser_cleanup_rect,changed_rect)
    end
    transform=transform or self:transform()
    local bb=Screen.bb
    if bb and not Screen.forced_rotation and self.clean_bb
        and self.clean_key==self:renderKey(transform) and bb.blitFrom then
        bb:blitFrom(self.clean_bb,rect.x,rect.y,rect.x,rect.y,rect.w,rect.h)
        self:paintStrokes(bb,transform,rect,0,0)
        self:paintEraserCursor(bb,0,0)
        self:protectToolbar(rect)
        -- Directly updated Screen.bb: low-latency monochrome refresh.
        self:refreshRegion(rect,changed_rect~=nil)
    else
        -- No valid PDF snapshot: repaint via KOReader, but avoid the
        -- page waveform that can visibly flash on each short erase.
        UIManager:setDirty(self.ui,"ui",Geom:new(rect))
    end
end

function Ink:calibrationKey()
    local rx,ry = self.adapter.ranges.x,self.adapter.ranges.y
    return table.concat({self.adapter.info.name,self.adapter.info.path,
        rx.min,rx.max,ry.min,ry.max,Screen:getWidth(),Screen:getHeight(),Screen:getRotationMode()},":")
end

function Ink:startWriting(recalibrate,automatic)
    if self.writing and not recalibrate then return end
    if self.writing then self:stopWriting() end
    if not Device:isKindle() or not tostring(Device.model):find("Scribe") then
        message(gettext("This plugin requires a Kindle Scribe.")); return
    end
    local okay,err = self:checkView()
    if not okay then
        if not automatic then message(err) end
        self.mode_error=err
        if self.overlay then self.overlay:updateStatus() end
        return
    end
    if not self:ensureStore() then return end
    -- Check that the destination is writable before collecting any strokes.
    self.store.dirty = true
    if not self:saveInk() then return end
    local input_options={}
    for key,value in pairs(self.settings.input or {}) do input_options[key]=value end
    -- Do not repaint the screen while the eraser is merely in proximity.
    -- BTN_TOUCH or pressure contact still generates down/move immediately.
    input_options.emit_hover=false
    local adapter,input_error = PenInput.open(input_options)
    if not adapter then message(gettext("Cannot open the Scribe pen: ")..tostring(input_error)); return end
    self.adapter = adapter
    self.writing=true; self.mode_error=nil
    self.screen_key = self:calibrationKey()
    self.mapping = self.settings.calibrations[self.screen_key]
    self.suppressed = false
    self:showToolbar()
    self:installCoreInput()
    if recalibrate or not Calibration.valid(self.mapping) then self:beginCalibration() end
    self.overlay:updateStatus()
    UIManager:setDirty(self.ui,"partial")
    self.poll_task = function() self:pollPen() end
    UIManager:scheduleIn(0.01,self.poll_task)
end

function Ink:beginCalibration()
    local w,h = Screen:getWidth(),Screen:getHeight()
    self.calibration = {index=1,raw={},targets={
        {x=w*0.2,y=h*0.15},
        {x=w*0.85,y=h*0.15},
        {x=w*0.2,y=h*0.85},
    }}
    self.mapping = nil
end

function Ink:installCoreInput()
    if self.core_input then self.core_input:close() end
    self.core_input=CoreInput.install(Device.input,{
        isActive=function() return self.writing and self.overlay and UIManager:getTopmostVisibleWidget()==self.overlay end,
    })
end

function Ink:isPenNear()
    if self.stroke or self.calibration and self.calibration.contact then return true end
    if self.adapter and self.adapter.decoder and self.adapter.decoder:isToolPresent() then return true end
    if self.core_input and self.core_input:isPenNear() then return true end
    return self.pen_gate_until and time.now()<self.pen_gate_until or false
end

function Ink:saveInk()
    if self.save_task then UIManager:unschedule(self.save_task); self.save_task=nil end
    if not self.store then return true end
    local okay,err = self.store:save()
    if not okay then
        logger.err("Scribe Ink save:",err)
        message(gettext("Handwriting could not be saved. It is still in this session's memory. Fix the error and retry saving before closing this PDF or restarting KOReader.\n\n")..tostring(err))
        return nil
    end
    return true
end

function Ink:queueSave()
    if self.save_task then UIManager:unschedule(self.save_task) end
    self.save_task=function()
        self.save_task=nil
        if self.stroke then self:queueSave() else self:saveInk() end
    end
    -- Keep JSON serialization and fsync out of a run of handwriting strokes.
    UIManager:scheduleIn(0.75,self.save_task)
end

-- A quiet-time UI refresh clears fast-waveform ghosts after eraser contact.
-- The physical footprint is already shown using the fast waveform; this runs
-- once after contact settles, never during hover or active pen movement.
function Ink:scheduleEraserCleanup()
    self.eraser_cleanup_rect=unionRect(self.eraser_cleanup_rect,self:cursorRect(self.eraser_cursor))
    if not self.eraser_cleanup_rect then return end
    if self.eraser_cleanup_task then UIManager:unschedule(self.eraser_cleanup_task) end
    self.eraser_cleanup_task=function()
        self.eraser_cleanup_task=nil
        if self.stroke or not self.writing or not self.overlay then return end
        local rect=self.eraser_cleanup_rect
        self.eraser_cleanup_rect=nil
        if rect then UIManager:setDirty(nil,"ui",Geom:new(rect)) end
    end
    UIManager:scheduleIn(0.18,self.eraser_cleanup_task)
end
function Ink:finishStroke()
    local stroke = self.stroke
    if not stroke then return end
    self.stroke = nil
    if stroke.eraser then
        self.store:endUndo()
    elseif #stroke.points > 0 then
        local added,err = self.store:add(stroke.page,{width=stroke.width,points=stroke.points})
        if not added then
            self.stroke = stroke
            message(gettext("Cannot record this pen stroke: ")..tostring(err))
            return
        end
    end
    self:scheduleEraserCleanup()
    self:queueSave()
    if self.overlay then self.overlay:updateUndoState() end
end

function Ink:pollPen()
    if not self.adapter or not self.overlay or not self.writing then return end
    if self.screen_key ~= self:calibrationKey() then
        self:stopWriting()
        self:hideToolbar(); self:showToolbar()
        UIManager:nextTick(function() if not self.closing then self:startWriting(false,true) end end)
        return
    end
    local okay,err = pcall(function()
        local result,poll_error = self.adapter:poll(function(event) self:penEvent(event) end)
        if result == nil and poll_error then error(poll_error) end
    end)
    if not okay then
        self:stopWriting()
        logger.err("Scribe Ink input:",err)
        message(gettext("Pen input stopped: ")..tostring(err))
        return
    end
    self:flushInkRefresh()
    if self.adapter and self.overlay then UIManager:scheduleIn(0.01,self.poll_task) end
end

function Ink:penEvent(event)
    if self.eraser_test then return end
    -- Proximity is not contact. Never enqueue any display work on hover.
    if event.phase=="hover" then return end
    if event.phase=="leave" then
        if self.eraser_cursor then self:updateEraserCursor(nil) end
        return
    end
    if event.phase=="down" and not (event.eraser or self.selected_tool=="eraser") then
        self:updateEraserCursor(nil)
    end
    if event.eraser then
        self.eraser_stats=self.eraser_stats or {decoded=0,accepted=0,hits=0,rejected={}}
        self.eraser_stats.decoded=self.eraser_stats.decoded+1
        self.eraser_stats.last_raw={x=event.x,y=event.y}
    end
    self.pen_gate_until=time.now()+time.ms(150)
    if UIManager:getTopmostVisibleWidget() ~= self.overlay then
        self:updateEraserCursor(nil)
        self:finishStroke()
        if self.calibration then self.calibration.contact=nil end
        self.suppressed = event.phase ~= "up"
        self:recordEraserRejection(event,"dialog")
        self:logEraserContact(event)
        return
    end
    if self.calibration then
        self:updateEraserCursor(nil)
        self:recordEraserRejection(event,"calibration")
        if event.cancelled then
            self.calibration.contact=nil
        elseif event.phase == "down" and not event.eraser then
            self.calibration.contact = {x=event.x,y=event.y}
        elseif event.phase == "up" and self.calibration.contact then
            local cal = self.calibration
            cal.raw[cal.index] = cal.contact
            cal.contact = nil
            if cal.index == 3 then
                local map,err = Calibration.solve(cal.raw,cal.targets)
                if map then
                    self.mapping = map
                    self.settings.calibrations[self.screen_key] = map
                    self:saveSettings()
                    self.calibration = nil
                else
                    self:beginCalibration()
                    message(err)
                end
            else cal.index = cal.index+1 end
            self.overlay:updateStatus()
            UIManager:setDirty(self.ui,"partial")
        end
        self:logEraserContact(event)
        return
    end
    if event.phase == "up" then
        if self.toolbar_contact then
            local contact=self.toolbar_contact; self.toolbar_contact=nil
            if not event.cancelled and not event.eraser then
                local screen=Calibration.apply(self.mapping,event)
                if self.overlay.toolbar:hitTest(screen.x,screen.y)==contact then self.overlay:activate(contact) end
            end
            self.suppressed=false
            return
        end
        -- Some drivers send the final X/Y sample in the contact-release frame.
        if self.stroke and not self.suppressed and not event.cancelled then
            self:penEvent{phase="move",x=event.x,y=event.y,pressure=event.pressure,eraser=event.eraser}
        end
        self:finishStroke()
        -- The footprint is visible only during real contact; erase any cursor
        -- pixels after release, even if the tool stays in hover range.
        if self.eraser_cursor then self:updateEraserCursor(nil) end
        self.suppressed = false
        self:logEraserContact(event)
        return
    end
    -- A fresh decoder down starts a new contact, including after a finger toolbar tap.
    if event.phase == "down" then self.suppressed = false end
    if self.suppressed then self:recordEraserRejection(event,"suppressed"); return end
    if not self:checkView() then self:finishStroke(); self.suppressed=true; self:recordEraserRejection(event,"view"); return end
    local screen = Calibration.apply(self.mapping,event)
    local clip = self:clip()
    if event.eraser then self.eraser_stats.last_screen=screen end
    if self.overlay.toolbar:hitTest(screen.x,screen.y) then
        if event.phase=="down" and not event.eraser then self.toolbar_contact=self.overlay.toolbar:hitTest(screen.x,screen.y) end
        self:updateEraserCursor(nil)
        self:finishStroke(); self.suppressed=true; self:recordEraserRejection(event,"toolbar"); return
    end
    local erasing=event.eraser or self.selected_tool=="eraser"
    local r=self:eraserRadius()
    local within=Geometry.pointInRect(screen,clip)
    if erasing then
        within=Geometry.intersectsBounds({x=screen.x-r,y=screen.y-r,w=2*r,h=2*r},clip)
    end
    if clip.w <= 0 or clip.h <= 0 or not within then
        self:updateEraserCursor(nil)
        -- Moving beyond the page must not permanently suppress a continuous
        -- eraser gesture; the footprint may cross the edge and come back.
        if event.phase=="down" or not erasing then
            self:finishStroke(); self.suppressed=true
        end
        self:recordEraserRejection(event,"outside page"); return
    end
    local transform = self:transform()
    local point = Geometry.screenToPage(screen,transform)
    if event.phase == "down" then
        self:finishStroke()
        -- Never run a slow cleanup in the middle of an active eraser gesture.
        if self.eraser_cleanup_task then
            UIManager:unschedule(self.eraser_cleanup_task)
            self.eraser_cleanup_task=nil
        end
        if self.save_task then UIManager:unschedule(self.save_task); self.save_task=nil end
        self.stroke = {page=transform.page,width=self.settings.width,points={},
            eraser=event.eraser or self.selected_tool=="eraser",transform=transform}
        if self.stroke.eraser then self.store:beginUndo() end
    end
    local stroke = self.stroke
    if not stroke then return end
    local old = stroke.transform
    if transform.page ~= stroke.page or transform.zoom ~= old.zoom
        or transform.offset.x ~= old.offset.x or transform.offset.y ~= old.offset.y
        or transform.visible.x ~= old.visible.x or transform.visible.y ~= old.visible.y
        or (event.eraser or self.selected_tool=="eraser") ~= stroke.eraser then
        self:finishStroke(); self.suppressed=true; return
    end
    if stroke.eraser then
        self.eraser_stats=self.eraser_stats or {decoded=0,accepted=0,hits=0,rejected={}}
        self.eraser_stats.accepted=self.eraser_stats.accepted+1
        self.eraser_stats.last_page=point
        local changed,bounds = self.store:erase(stroke.page,stroke.last or point,point,
            self:eraserRadius()/transform.zoom)
        stroke.last = point
        if changed then self.eraser_stats.hits=self.eraser_stats.hits+changed end
        -- Update even when there was no hit: the user always sees the footprint.
        self:updateEraserCursor(screen,changed and changed>0 and bounds or nil,transform)
    else
        local last = stroke.points[#stroke.points]
        if not last or (point.x-last.x)^2+(point.y-last.y)^2 >= (0.6/transform.zoom)^2 then
            stroke.points[#stroke.points+1] = point
            self:drawNewSegment(last or point,point,stroke.width,transform)
        end
    end
end

function Ink:recordEraserRejection(event,reason)
    if event.eraser and self.eraser_stats then
        self.eraser_stats.rejected[reason]=(self.eraser_stats.rejected[reason] or 0)+1
    end
end

function Ink:logEraserContact(event)
    if event.eraser and event.phase=="up" and self.eraser_stats then
        logger.info("Scribe Ink eraser stroke:",self:eraserSummary())
    end
end

function Ink:eraserSummary()
    local stats=self.eraser_stats
    if not stats then return "No decoded eraser contacts yet." end
    local parts={"decoded="..stats.decoded,"accepted="..stats.accepted,"erased="..stats.hits}
    for reason,count in pairs(stats.rejected) do parts[#parts+1]=reason.."="..count end
    for _,name in ipairs{"last_raw","last_screen","last_page"} do
        if stats[name] then parts[#parts+1]=name.."="..string.format("%.1f,%.1f",stats[name].x,stats[name].y) end
    end
    return table.concat(parts,"; ")
end

function Ink:renderKey(transform)
    local bb=Screen.bb
    return table.concat({transform.page,transform.zoom,transform.offset.x,transform.offset.y,
        transform.visible.x,transform.visible.y,Screen:getWidth(),Screen:getHeight(),Screen:getRotationMode(),
        bb and bb.getInverse and bb:getInverse() or 0,bb and bb.getRotation and bb:getRotation() or 0},":")
end

function Ink:invalidateCache()
    if self.clean_bb then self.clean_bb:free(); self.clean_bb=nil end
    if self.eraser_cleanup_task then UIManager:unschedule(self.eraser_cleanup_task) end
    self.eraser_cleanup_task=nil; self.eraser_cleanup_rect=nil
    self.clean_key=nil; self.refresh_rect=nil; self.refresh_erase=nil
end

function Ink:refreshRegion(rect,erasing)
    if not rect then return end
    local old=self.refresh_rect
    if old then
        local left,top=math.min(old.x,rect.x),math.min(old.y,rect.y)
        self.refresh_rect={x=left,y=top,w=math.max(old.x+old.w,rect.x+rect.w)-left,
            h=math.max(old.y+old.h,rect.y+rect.h)-top}
    else self.refresh_rect=rect end
    if erasing then self.refresh_erase=true end
end

function Ink:flushInkRefresh()
    local rect=self.refresh_rect
    self.refresh_rect,self.refresh_erase=nil,nil
    if not rect or not self.overlay then return end
    -- The clean PDF + surviving ink have already been recomposed in Screen.bb.
    -- Always use the fast waveform while touching. '[partial]' can trigger
    -- slow, visible flashes and queues up when fed high-frequency pen samples.
    UIManager:setDirty(nil,"fast",Geom:new(rect))
end

function Ink:drawNewSegment(a,b,width,transform)
    if not Screen.bb or Screen.forced_rotation or self.clean_key~=self:renderKey(transform) then
        UIManager:setDirty(self.ui,"fast"); return
    end
    local sa,sb=Geometry.pageToScreen(a,transform),Geometry.pageToScreen(b,transform)
    local rect=Render.line(Screen.bb,sa,sb,width*transform.zoom,Blitbuffer.COLOR_BLACK,self:clip())
    self:refreshRegion(rect)
    self:protectToolbar(rect)
end

function Ink:protectToolbar(rect)
    if rect and self.overlay and Geometry.intersectsBounds(rect,self.overlay.toolbar:getRect()) then
        self.overlay.toolbar:paintTo(Screen.bb,0,0)
    end
end

function Ink:paintStrokes(bb,transform,clip,x,y)
    x,y=x or 0,y or 0
    local function paint(stroke)
        local bounds=Geometry.bounds(stroke)
        local origin=Geometry.pageToScreen(bounds,transform)
        local screen_bounds={x=origin.x+x-2,y=origin.y+y-2,w=bounds.w*transform.zoom+4,h=bounds.h*transform.zoom+4}
        if not Geometry.intersectsBounds(screen_bounds,clip) then return end
        local previous
        for _,point in ipairs(stroke.points) do
            local screen=Geometry.pageToScreen(point,transform)
            screen.x,screen.y=screen.x+x,screen.y+y
            Render.line(bb,previous or screen,screen,stroke.width*transform.zoom,Blitbuffer.COLOR_BLACK,clip)
            previous=screen
        end
    end
    for _,stroke in ipairs(self.store:page(transform.page)) do paint(stroke) end
    if self.stroke and not self.stroke.eraser and self.stroke.page==transform.page then paint(self.stroke) end
end

function Ink:restoreInkRegion(bounds,transform)
    -- Kept for callers using the previous API; ordinary erasing passes the
    -- cursor as well so only one recomposition is needed for a whole sample.
    self:updateEraserCursor(self.eraser_cursor,bounds,transform)
end

function Ink:paintInk(bb,x,y)
    if not self:checkView() then self:invalidateCache(); return end
    local transform,clip = self:transform(),self:clip()
    clip.x,clip.y = clip.x+x,clip.y+y
    self:invalidateCache()
    if bb==Screen.bb and x==0 and y==0 and bb.copy and self.writing then
        self.clean_bb=bb:copy(); self.clean_key=self:renderKey(transform)
    end
    if self.store then self:paintStrokes(bb,transform,clip,x,y) end
end

function Ink:stopWriting(remove_toolbar)
    if self.eraser_cursor then self:updateEraserCursor(nil) end
    self:closePenWidthPicker(false)
    if self.eraser_test_task then UIManager:unschedule(self.eraser_test_task); self.eraser_test_task=nil end
    self.eraser_test=false
    self:finishStroke()
    if self.poll_task then UIManager:unschedule(self.poll_task); self.poll_task=nil end
    if self.adapter then self.adapter:close(); self.adapter=nil end
    if self.core_input then self.core_input:close(); self.core_input=nil end
    self.writing=false
    self.calibration,self.mapping,self.toolbar_contact=nil,nil,nil
    self:invalidateCache()
    if remove_toolbar or not self.settings.persistent_toolbar then self:hideToolbar()
    elseif self.overlay then self.overlay:updateStatus() end
    self:saveInk()
    UIManager:setDirty(self.ui,"partial")
end

function Ink:exportPDF()
    self:finishStroke()
    if not self:ensureStore() or not self:saveInk() then return end
    local matches,source_error = self.store:sourceMatches()
    if not matches then message(tostring(source_error)); return end
    if self.ui.document.is_edited then
        message(gettext("Close and reopen the PDF to save KOReader's pending PDF edits before exporting.")); return
    end
    local source = self.ui.document.file
    -- Never overwrite either the source or an existing export: each export gets a free name.
    local target = source:gsub("%.[pP][dD][fF]$","").."-annotated.pdf"
    local stem,index = target:gsub("%.pdf$",""),1
    while true do
        local file = io.open(target,"rb")
        if not file then break end
        file:close(); index=index+1; target=stem.."-"..index..".pdf"
    end
    local okay,err = Pdf.export(source,target,self.store:exportPages())
    if okay then message(gettext("Annotated PDF saved:\n")..target)
    else message(gettext("PDF export failed:\n")..tostring(err)) end
end

function Ink:diagnostics()
    local adapter,err = PenInput.open(self.settings.input or {})
    if not adapter then message(tostring(err)); return end
    local info = adapter.info
    local rx,ry = adapter.ranges.x,adapter.ranges.y
    adapter:close()
    message("Scribe Ink 0.4.2\n"..tostring(Device.model).."\n"..info.path.."\n"..info.name
        .."\nX: "..rx.min..".."..rx.max.."\nY: "..ry.min..".."..ry.max
        .."\nRear eraser event supported: "..tostring(info.has_rubber)
        .."\nInput source: "..tostring(info.source_hint or "unknown")
        .."\nEraser signal: "..tostring(info.eraser_key)
        .."\n"..self:eraserSummary()
        .."\nPDF export requires the ink API in KOReader 2026.07+.\n"
        .."Calibration: three pen taps for each screen orientation.")
end

function Ink:selectTool(tool)
    self:finishStroke()
    if tool~="eraser" then self:updateEraserCursor(nil) end
    self.selected_tool=tool
    if not self.writing then self:startWriting() end
    if self.overlay then self.overlay:updateStatus() end
end

function Ink:testEraser()
    if not self.writing then self:startWriting() end
    if not self.adapter then return end
    self:finishStroke(); self:saveInk()
    self.adapter:resetDiagnostics()
    self.eraser_test=true
    self.overlay:updateStatus()
    self.eraser_test_task=function()
        self.eraser_test_task=nil
        if not self.adapter then return end
        local report=self.adapter:diagnosticText()
        self.eraser_test=false
        self.overlay:updateStatus()
        logger.info("Scribe Ink rear eraser test:\n"..report)
        message(gettext("Rear eraser test results (also saved to crash.log):\n\n")..report)
    end
    UIManager:scheduleIn(10,self.eraser_test_task)
end

function Ink:onSuspend() self:stopWriting(true) end
function Ink:onResume()
    if not self.closing and self.ui.document.is_pdf and self.settings.persistent_toolbar then
        UIManager:nextTick(function() if not self.closing then self:showToolbar(); self:startWriting(false,true) end end)
    end
end
function Ink:closeReader()
    self.closing=true
    if self.ready_task then UIManager:unschedule(self.ready_task); self.ready_task=nil end
    self:stopWriting(true)
end
function Ink:onCloseDocument() self:closeReader() end
function Ink:onClose() self:closeReader() end
function Ink:onFlushSettings() self:finishStroke(); self:saveInk(); self:saveSettings() end
function Ink:onExit() self:closeReader() end
function Ink:onPageUpdate() self:finishStroke(); self.eraser_cursor=nil; self:invalidateCache(); if self.overlay then self.overlay:updateStatus() end end
function Ink:onZoomUpdate() self:finishStroke(); self.eraser_cursor=nil; self:invalidateCache() end
function Ink:onSetDimensions()
    self:finishStroke(); self.eraser_cursor=nil; self:invalidateCache()
    if self.overlay then self.overlay.dimen=Screen:getSize(); self.overlay:updateStatus() end
end

function Ink:stopPlugin()
    self:closeReader()
    if self.ui.view and self.ui.view.view_modules then
        self.ui.view.view_modules.scribeink=nil
    end
    UIManager:setDirty(self.ui,"partial")
end

function Overlay:init()
    -- Showing a window changes these global input preferences. Keep the
    -- reader's gesture settings while the handwriting dock is on top.
    self.disable_double_tap=self.owner.ui.disable_double_tap
    self.allow_concurrent_taps=self.owner.ui.allow_concurrent_taps
    self.tap_interval_override=self.owner.ui.tap_interval_override
    self.toolbar=Toolbar.new{screen=Screen,collapsed=self.owner.settings.toolbar_collapsed}
    self:updateStatus()
end

function Overlay:updateStatus()
    local had_status=self.status~=nil
    if self.status then self.status:free() end
    local owner = self.owner
    self.status=nil
    self.toolbar:update(owner.selected_tool,{writing=owner.writing,calibration=owner.calibration,
        eraser_test=owner.eraser_test,can_undo=owner.store and owner.store.undo_stack and #owner.store.undo_stack>0 or false})
    local text
    if owner.eraser_test then text=gettext("Touch with rear eraser now (10 second test); no ink is changed.")
    elseif owner.calibration then text=gettext("Tap cross with pen tip: ")..owner.calibration.index.."/3"
    elseif owner.mode_error then text=owner.mode_error end
    if text then self.status=TextWidget:new{text=text,face=Font:getFace("smallinfofont",14),
        max_width=Screen:getWidth()*0.8} end
    if UIManager:isWidgetShown(self) then
        UIManager:setDirty(self,"ui",Geom:new(self.toolbar:getRect()))
        if text then UIManager:setDirty(self,"ui",Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:scaleBySize(40)}) end
        if had_status and not text then
            UIManager:setDirty(self.owner.ui,"ui",Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:scaleBySize(40)})
        end
    end
end

function Overlay:updateUndoState()
    local available=self.owner.store and self.owner.store.undo_stack and #self.owner.store.undo_stack>0 or false
    if available~=self.toolbar.state.can_undo then
        self.toolbar.state.can_undo=available
        local rect=self.toolbar:getButtonRect("undo")
        if rect then UIManager:setDirty(self,"ui",Geom:new(rect)) end
    end
end

function Overlay:paintTo(bb,x,y)
    self.toolbar:paintTo(bb,x,y)
    self.owner:paintEraserCursor(bb,x,y)
    if self.status then
        local size=self.status:getSize()
        bb:paintRect(x+Screen:getWidth()*0.1,y,Screen:getWidth()*0.8,size.h,Blitbuffer.COLOR_WHITE)
        self.status:paintTo(bb,x+Screen:getWidth()*0.1,y)
    end
    local cal = self.owner.calibration
    if cal then
        local p = cal.targets[cal.index]
        local radius = Screen:scaleBySize(13)
        local px,py = x+math.floor(p.x),y+math.floor(p.y)
        bb:paintRect(px-radius-5,py-radius-5,2*radius+11,2*radius+11,Blitbuffer.COLOR_WHITE)
        bb:paintCircle(px,py,radius,Blitbuffer.COLOR_BLACK,2)
        bb:paintRect(px-radius,py-1,2*radius+1,3,Blitbuffer.COLOR_BLACK)
        bb:paintRect(px-1,py-radius,3,2*radius+1,Blitbuffer.COLOR_BLACK)
    end
end

function Overlay:onGesture(event)
    local action=event.pos and self.toolbar:hitTest(event.pos.x,event.pos.y)
    if action then
        if event.ges=="tap" and not self.owner:isPenNear() then self:activate(action) end
        return true
    end
    if self.owner.calibration or self.owner.eraser_test or self.owner:isPenNear() then return true end
    -- UIManager only dispatches to its top widget and explicitly active ones;
    -- returning false here does not reach the underlying ReaderUI.
    return self:forwardReaderEvent("Gesture",event)
end

function Overlay:forwardReaderEvent(name,...)
    if UIManager:getTopmostVisibleWidget()~=self then return false end
    self.owner.ui:handleEvent(Event:new(name,...))
    return true
end

function Overlay:activate(action)
    local owner=self.owner
    if owner.eraser_test and action~="menu" and action~="collapse" then return end
    owner:finishStroke()
    if action=="collapse" then
        local old=self.toolbar:getRect()
        owner.settings.toolbar_collapsed=self.toolbar:toggleCollapsed()
        owner:saveSettings()
        local new=self.toolbar:getRect()
        local rect={x=math.min(old.x,new.x),y=math.min(old.y,new.y),
            w=math.max(old.x+old.w,new.x+new.w)-math.min(old.x,new.x),
            h=math.max(old.y+old.h,new.y+new.h)-math.min(old.y,new.y)}
        UIManager:setDirty(owner.ui,"ui",Geom:new(rect))
    elseif action=="pen" then owner:showPenWidthPicker()
    elseif action=="eraser" then owner:selectTool("eraser")
    elseif action=="undo" and not owner.calibration then
        if owner:ensureStore() then
            owner.store:undo(); owner:saveInk(); self:updateStatus(); UIManager:setDirty(owner.ui,"partial")
        end
    elseif action=="export" and not owner.calibration then owner:exportPDF()
    elseif action=="menu" then owner:saveInk(); owner.ui.menu:onShowMenu() end
end

function Overlay:onBack()
    return self:forwardReaderEvent("Back")
end
function Overlay:onKeyPress(key) return self:forwardReaderEvent("KeyPress",key) end
function Overlay:onKeyRepeat(key) return self:forwardReaderEvent("KeyRepeat",key) end
function Overlay:onKeyRelease(key) return self:forwardReaderEvent("KeyRelease",key) end
function Overlay:onSuspend() self.owner:onSuspend() end
function Overlay:free()
    if self.toolbar then self.toolbar:free() end
    if self.status then self.status:free(); self.status=nil end
end

return Ink
