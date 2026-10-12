-- Integration checks exercise production main.lua with KOReader UI boundaries mocked.
local base = debug.getinfo(1,"S").source:sub(2):match("^(.*[/\\])").."../scribeink.koplugin/"
local checks = 0
local test_now=0
local function check(value,label) checks=checks+1; assert(value,label) end
local function near(a,b) return math.abs(a-b)<1e-7 end
local Class = {}
function Class:extend(o) o=o or {}; self.__index=self; return setmetatable(o,self) end
function Class:new(o) o=self:extend(o); if o.init then o:init() end; return o end
function Class:handleEvent(e) if self[e.handler] then return self[e.handler](self,unpack(e.args)) end end
local width,height,rotation = 600,800,0
-- A sparse framebuffer keeps real raster output observable without emulating
-- native memory. Copies own their pixel map; blits restore only the requested
-- region, allowing tests to catch dirty snapshots and full-page redraws.
local framebuffer_copies,framebuffer_frees,native_paints,native_blits,native_circles=0,0,{},{},{}
local Buffer={}
Buffer.__index=Buffer
function Buffer.new() return setmetatable({pixels={},inverse=0,rotation=0},Buffer) end
function Buffer:getWidth() return width end
function Buffer:getHeight() return height end
function Buffer:getInverse() return self.inverse end
function Buffer:getRotation() return self.rotation end
function Buffer:pixel(x,y) return self.pixels[y*width+x] or 255 end
function Buffer:paintRect(x,y,w,h,color)
    native_paints[#native_paints+1]={x=x,y=y,w=w,h=h}
    if x==0 and y==0 and w==width and h==height and color==255 then self.pixels={}; return end
    for py=y,y+h-1 do for px=x,x+w-1 do
        if px>=0 and px<width and py>=0 and py<height then
            self.pixels[py*width+px]=color~=255 and color or nil
        end
    end end
end
function Buffer:copy()
    framebuffer_copies=framebuffer_copies+1
    local copy=Buffer.new(); copy.inverse,copy.rotation=self.inverse,self.rotation
    for k,v in pairs(self.pixels) do copy.pixels[k]=v end
    return copy
end
function Buffer:blitFrom(source,x,y,sx,sy,w,h)
    native_blits[#native_blits+1]={x=x,y=y,w=w,h=h}
    for dy=0,h-1 do for dx=0,w-1 do
        local value=source:pixel(sx+dx,sy+dy)
        self.pixels[(y+dy)*width+x+dx]=value~=255 and value or nil
    end end
end
function Buffer:free() self.freed=true; framebuffer_frees=framebuffer_frees+1 end
function Buffer:paintCircle(cx,cy,radius,color,thickness)
    native_circles[#native_circles+1]={x=cx,y=cy,radius=radius}
    local inner=thickness and math.max(0,radius-thickness) or 0
    for y=math.floor(cy-radius),math.ceil(cy+radius) do
        for x=math.floor(cx-radius),math.ceil(cx+radius) do
            local d2=(x-cx)^2+(y-cy)^2
            if d2<=radius^2 and d2>=inner^2 and x>=0 and x<width and y>=0 and y<height then
                self.pixels[y*width+x]=color~=255 and color or nil
            end
        end
    end
end
local Screen = {getWidth=function() return width end,getHeight=function() return height end,
    getRotationMode=function() return rotation end,scaleBySize=function(_,n) return n end,
    getSize=function() return {x=0,y=0,w=width,h=height} end}
Screen.bb=Buffer.new()
local core_previous_calls=0
local core_input={pen_slot=4,ev_slots={[4]={slot=4,tool=0,id=-1}},gesture_detector={active_contacts={}}}
function core_input:registerStylusCallback(callback) self.stylus_callback=callback end
function core_input:unregisterStylusCallback() self.stylus_callback=nil end
function core_input.gesture_detector:getContact(slot) return self.active_contacts[slot] end
function core_input.gesture_detector:dropContact(contact) self.active_contacts[contact.slot]=nil end
local previous_core_callback=function() core_previous_calls=core_previous_calls+1; return false end
core_input.stylus_callback=previous_core_callback
local Device = {screen=Screen,input=core_input,model="KindleScribe",isKindle=function() return true end}
local windows,tasks,notices,refreshes = {},{}, {},{}
local ui,repaintPage
local pending_refreshes,display_pixels,display_updates={},{},{}
local avoid_flash_requests=0
local Manager = {}
local function updateInputPreferences(widget)
    core_input.disable_double_tap=not widget or widget.disable_double_tap~=false
    core_input.allow_concurrent_taps=widget and widget.allow_concurrent_taps==true or false
    core_input.tap_interval_override=widget and widget.tap_interval_override or nil
end
function Manager:show(widget)
    windows[#windows+1]=widget
    if widget.text then notices[#notices+1]=widget.text end
    updateInputPreferences(widget)
end
function Manager:close(widget)
    for i=#windows,1,-1 do if windows[i]==widget then table.remove(windows,i) end end
    updateInputPreferences(windows[#windows])
end
function Manager:getTopmostVisibleWidget() return windows[#windows] end
function Manager:isWidgetShown(widget) for _,w in ipairs(windows) do if widget==w then return true end end return false end
function Manager:setDirty(w,mode,rect)
    local request={w=w,mode=mode,rect=rect,avoid_flash=self.avoid_flash==true}
    refreshes[#refreshes+1]=request
    pending_refreshes[#pending_refreshes+1]=request
end
-- Logical framebuffer changes alone do not update the physical display.
-- Process queued widget painting and refreshes as a subsequent UI tick does.
function Manager:present(rect)
    rect=rect or {x=0,y=0,w=width,h=height}
    for py=math.max(0,math.floor(rect.y)),math.min(height-1,math.ceil(rect.y+rect.h)-1) do
        for px=math.max(0,math.floor(rect.x)),math.min(width-1,math.ceil(rect.x+rect.w)-1) do
            local value=Screen.bb:pixel(px,py)
            display_pixels[py*width+px]=value~=255 and value or nil
        end
    end
end
function Manager:displayPixel(x,y) return display_pixels[y*width+x] or 255 end
function Manager:avoidFlashOnNextRepaint()
    avoid_flash_requests=avoid_flash_requests+1; self.avoid_flash=true
end
function Manager:processRepaints()
    local requests=pending_refreshes; pending_refreshes={}
    for _,request in ipairs(requests) do
        if request.w==ui then repaintPage(false)
        elseif request.w and request.w.paintTo then request.w:paintTo(Screen.bb,0,0) end
        self:present(request.rect)
        display_updates[#display_updates+1]=request
    end
    self.avoid_flash=false
end
function Manager:scheduleIn(delay,task) tasks[task]=delay end
function Manager:unschedule(task) tasks[task]=nil end
function Manager:nextTick(task) task() end
-- The real KOReader UIManager:sendEvent does not fall through to every lower
-- window. Reproduce its dispatch contract: top non-toast, its active_widgets,
-- then only lower active_widgets/is_always_active listeners. This catches a
-- dock which merely returns false or exposes the whole reader behind dialogs.
function Manager:sendEvent(event)
    local top_widget,checked=nil,{}
    for i=#windows,1,-1 do
        local widget=windows[i]
        checked[widget]=true
        if widget.toast then widget:handleEvent(event) else top_widget=widget; break end
    end
    if not top_widget then return end
    if top_widget:handleEvent(event) then return end
    if top_widget.active_widgets then
        for _,widget in ipairs(top_widget.active_widgets) do if widget:handleEvent(event) then return end end
    end
    local index=#windows
    while index>0 do
        local widget=windows[index]
        if not checked[widget] then
            checked[widget]=true
            if widget.active_widgets then
                for _,active in ipairs(widget.active_widgets) do if active:handleEvent(event) then return end end
            end
            if widget.is_always_active and widget:handleEvent(event) then return end
            index=#windows
        else index=index-1 end
    end
end
local Text = Class:extend{}
function Text:getSize() return {w=#self.text*5,h=18} end
function Text:paintTo() end
function Text:free() end
local Geom = Class:extend{}
local modules = {
    ["device"]=Device,["ui/uimanager"]=Manager,
    ["ui/widget/container/widgetcontainer"]=Class,
    ["ui/widget/container/inputcontainer"]=Class,
    ["ui/widget/infomessage"]=Class,["ui/widget/textwidget"]=Text,
    ["ui/widget/buttondialog"]=Class,
    ["ui/font"]={getFace=function() return {} end},["ui/geometry"]=Geom,
    ["ui/event"]={new=function(_,name,...) return {handler="on"..name,args={...}} end},
    ["ui/time"]={now=function() return test_now end,ms=function(value) return value/1000 end},
    ["ffi/blitbuffer"]={COLOR_BLACK=0,COLOR_WHITE=255},
    ["logger"]={err=function() end,info=function() end},["gettext"]=function(text) return text end,
    ["rapidjson"]={},["libs/libkoreader-lfs"]={},["ffi/util"]={},["ffi/sha2"]={},
}
for name,module in pairs(modules) do package.loaded[name]=module end
local settings = {width=1.25,calibrations={},auto_write=false,persistent_toolbar=false}
local settings_writes=0
G_reader_settings = {readSetting=function() return settings end,saveSetting=function(_,_,s)
    settings=s; settings_writes=settings_writes+1
end}
local saved,fail_save,export_count,closed,adopted = 0,false,0,0,0
local Geometry = dofile(base.."geometry.lua")
-- Production Store/Geometry own stroke mutation, clipping and grouped undo.
-- Only filesystem persistence and source identity are mocked below.
local ActualStore=dofile(base.."store.lua")
local store=setmetatable({pages={},undo_stack={},dirty=false,path="original.pdf.scribeink.json"},ActualStore)
function store:save()
    if fail_save then return nil,"disk full" end
    if self.dirty then self.dirty=false; saved=saved+1 end
    return true
end
function store:sourceMatches() return true end
function store:adoptSourceWrite() adopted=adopted+1; self.dirty=true; return true end
local input = {codes={}}
local input_opens=0
function input.open()
    input_opens=input_opens+1
    return {info={name="WacomDigitizer",path="/dev/input/event2",has_rubber=true},
        ranges={x={min=0,max=10000},y={min=0,max=10000}},
        pending={},resyncs=0,
        poll=function(self,callback)
            local pending=self.pending; self.pending={}
            for _,event in ipairs(pending) do
                self.contact_active=event.phase~="up"
                if self.blocked_contact then
                    if event.phase=="up" then self.blocked_contact=false end
                elseif callback then callback(event) end
            end
            return #pending
        end,
        resync=function(self)
            self.resyncs=self.resyncs+1
            self.blocked_contact=self.contact_active==true
            return true
        end,
        close=function() closed=closed+1 end,
        resetDiagnostics=function() end,diagnosticText=function() return "rear eraser samples" end,
        decoder={present=false,isToolPresent=function(self) return self.present end}}
end
local pdf = {export=function() export_count=export_count+1; return true end}
local real_dofile = dofile
dofile = function(path)
    if path:match("[/\\]store%.lua$") then return {open=function() return store end} end
    if path:match("[/\\]input%.lua$") then return input end
    if path:match("[/\\]pdf%.lua$") then return pdf end
    return real_dofile(path)
end
local Plugin = dofile(base.."main.lua")
dofile = real_dofile
local view = {state={page=1,zoom=2,rotation=0,offset={x=30,y=40}},
    visible_area={x=20,y=10,w=540,h=700},registerViewModule=function(self,_,m) self.ink=m end}
local core_writes=0
local doc = {file="__scribeink_ui_test_nonexistent__.pdf",is_pdf=true,configurable={text_wrap=0},
    getPageCount=function() return 5 end,writeDocument=function() core_writes=core_writes+1 end}
local registered_menu_widgets={}
local menu_shows=0
ui = {document=doc,view=view,disable_double_tap=false,allow_concurrent_taps=true,tap_interval_override=17,
    menu={registerToMainMenu=function(_,widget)
    registered_menu_widgets[#registered_menu_widgets+1]=widget
end,onShowMenu=function() menu_shows=menu_shows+1 end}}
local reader_events={Gesture=0,Back=0,KeyPress=0,KeyRepeat=0,KeyRelease=0}
local reader_last={}
function ui:handleEvent(e)
    if e.handler=="onGotoPage" then self.view.state.page=e.args[1]
    else
        local name=e.handler:sub(3)
        if reader_events[name] then
            reader_events[name]=reader_events[name]+1; reader_last[name]=e.args[1]; return true
        end
    end
end
local plugin = Plugin:new{ui=ui}
check(plugin.settings.auto_write and plugin.settings.persistent_toolbar,
    "legacy mode preferences migrate to automatic integrated pen controls")
local function flushSave()
    local task=plugin.save_task
    if task then tasks[task]=nil; task() end
end
repaintPage=function(present)
    Screen.bb:paintRect(0,0,width,height,255)
    Screen.bb:paintRect(110,210,1,1,77) -- a document pixel crossed by handwriting
    Screen.bb:paintRect(500,500,1,1,99) -- unrelated content outside an erase rectangle
    view.ink:paintTo(Screen.bb,0,0)
    if plugin.overlay then plugin.overlay:paintTo(Screen.bb,0,0) end
    if present~=false then
        Manager:present()
        pending_refreshes={}
    end
end
local function dismissWidthPicker()
    if plugin.width_dialog then
        local dialog=plugin.width_dialog
        local row=dialog.buttons[#dialog.buttons]
        row[1].callback()
    end
end
local function tapButton(overlay,label)
    test_now=test_now+0.2 -- a deliberate finger tap after the pen lifts
    local action=({Pen="pen",Erase="eraser",Undo="undo",Export="export",Menu="menu",Collapse="collapse"})[label] or label
    local rect=overlay.toolbar and overlay.toolbar:getButtonRect(action)
    if rect then
        local consumed=overlay:onGesture{ges="tap",pos={x=rect.x+rect.w/2,y=rect.y+rect.h/2}}
        -- Most scenarios use Pen simply to restore drawing. Dedicated cases
        -- below exercise the real picker and choosing a different width.
        if action=="pen" then dismissWidthPicker() end
        return consumed
    end
    error("Missing toolbar button: "..label)
end
-- Exercise the menu builder itself: production KOReader invokes this after
-- init when opening Tools. Enabling/loading the plugin alone misses failures
-- in deferred menu construction, including gettext shadowed by loop indices.
local menu = {}
plugin:addToMainMenu(menu)
check(menu.scribeink and menu.scribeink.text == "Scribe Ink", "plugin builds its user-visible menu")
check(#registered_menu_widgets==1 and registered_menu_widgets[1]==plugin,
    "reader registers the plugin once as a menu contributor")
check(menu.scribeink.sorting_hint=="more_tools", "writing tools appear in More tools")
check(menu.scribeink.enabled_func(), "PDF reader enables writing tools")
doc.is_pdf=false
check(not menu.scribeink.enabled_func(), "other document formats disable PDF writing tools")
doc.is_pdf=true
ui.document=nil
check(not menu.scribeink.enabled_func(), "missing document cannot enable writing tools")
ui.document=doc
check(input_opens==0 and not plugin.store and not plugin.overlay and not next(tasks),
    "constructing the Tools menu does not acquire the pen or start a writing session")

local function findItem(items,label)
    for _,item in ipairs(items) do if item.text==label then return item end end
    error("Missing menu item: "..label)
end
local actions=menu.scribeink.sub_item_table
local width_items=findItem(actions,"Pen width").sub_item_table
check(#width_items==4, "menu offers four useful writing widths")
local expected_widths={0.75,1.25,2,3}
for index,value in ipairs(expected_widths) do
    local option=findItem(width_items,tostring(value).." pt")
    local writes_before=settings_writes
    option.callback()
    check(near(plugin.settings.width,value) and settings==plugin.settings
        and settings_writes==writes_before+1, "pen width selection updates and persists its actual value")
    for _,other in ipairs(width_items) do
        check(other.checked_func()==(other==option), "width check marks follow the selected setting")
    end
end
findItem(width_items,"1.25 pt").callback() -- restore the integration scenario's width
local source_items=findItem(actions,"Pen input source").sub_item_table
local automatic=findItem(source_items,"Automatic (prefer raw Wacom)")
local fallback=findItem(source_items,"Prefer scaled virtual pen (fallback)")
check(automatic.checked_func() and not fallback.checked_func(), "automatic pen source is the default")
local writes_before=settings_writes
fallback.callback()
check(plugin.settings.input.prefer_scaled and fallback.checked_func() and not automatic.checked_func()
    and settings_writes==writes_before+1, "fallback pen source choice persists and updates check marks")
automatic.callback()
check(not plugin.settings.input.prefer_scaled and automatic.checked_func() and not fallback.checked_func()
    and settings_writes==writes_before+2, "automatic source can be restored from the menu")

-- Invoke the actual menu callbacks while replacing only the costly operation
-- endpoints. This verifies routing/deferred startup without opening extra pen
-- adapters or perturbing stroke, export and close counts in the scenarios below.
local startWriting,exportPDF,diagnostics=plugin.startWriting,plugin.exportPDF,plugin.diagnostics
local testEraser,stopWriting,showToolbar,hideToolbar=plugin.testEraser,plugin.stopWriting,plugin.showToolbar,plugin.hideToolbar
local requested,deferred={},{}
local nextTick=Manager.nextTick
Manager.nextTick=function(_,task) deferred[#deferred+1]=task end
plugin.startWriting=function(instance,recalibrate)
    check(instance==plugin, "writing menu callback targets the current reader instance")
    requested[#requested+1]=recalibrate and "recalibrate" or "start"
end
plugin.exportPDF=function(instance)
    check(instance==plugin, "export menu callback targets the current reader instance")
    requested[#requested+1]="export"
end
plugin.diagnostics=function(instance)
    check(instance==plugin, "diagnostics callback targets the current reader instance")
    requested[#requested+1]="diagnostics"
end
plugin.testEraser=function(instance)
    check(instance==plugin, "eraser test menu callback targets the current reader instance")
    requested[#requested+1]="eraser-test"
end
plugin.stopWriting=function(instance) check(instance==plugin, "eraser signal changes stop the current writer") end
plugin.showToolbar=function() end
plugin.hideToolbar=function() end
findItem(actions,"Show pen controls").callback()
check(#requested==0 and #deferred==1, "Start writing waits for the invoking Tools menu to close")
table.remove(deferred,1)()
findItem(actions,"Export annotated PDF copy").callback()
findItem(actions,"Recalibrate pen").callback()
check(table.concat(requested,",")=="start,export" and #deferred==1,
    "Recalibrate also waits until the invoking menu closes")
table.remove(deferred,1)()
findItem(actions,"Diagnostics").callback()
findItem(actions,"Test rear eraser (10 seconds)").callback()
check(#deferred==1, "rear eraser capture waits for its invoking menu to close")
table.remove(deferred,1)()
check(table.concat(requested,",")=="start,export,recalibrate,diagnostics,eraser-test",
    "all operational menu actions dispatch to the expected operation")
local has_mode_toggle=false
for _,item in ipairs(actions) do
    if item.text=="Start writing automatically on PDFs" or item.text=="Always show writing toolbar" then
        has_mode_toggle=true
    end
end
check(not has_mode_toggle, "menus do not offer a separate reading or writing mode toggle")
local eraser_choices=findItem(actions,"Rear eraser signal").sub_item_table
for _,choice in ipairs(eraser_choices) do
    choice.callback()
    for _,other in ipairs(eraser_choices) do
        check(other.checked_func()==(choice==other), "rear eraser signal selection persists and updates check marks")
    end
end
findItem(eraser_choices,"Rear rubber tool (default)").callback()
plugin.startWriting,plugin.exportPDF,plugin.diagnostics=startWriting,exportPDF,diagnostics
plugin.testEraser,plugin.stopWriting,plugin.showToolbar,plugin.hideToolbar=testEraser,stopWriting,showToolbar,hideToolbar
Manager.nextTick=nextTick
check(input_opens==0 and saved==0 and export_count==0 and not next(tasks),
    "menu callback regression checks leave hardware and document scenarios untouched")

local rebuilt={}
plugin:addToMainMenu(rebuilt)
check(rebuilt.scribeink~=menu.scribeink and rebuilt.scribeink.sub_item_table~=actions,
    "reopening Tools builds independent menu tables")
local rebuilt_widths=findItem(rebuilt.scribeink.sub_item_table,"Pen width").sub_item_table
check(findItem(rebuilt_widths,"1.25 pt").checked_func(), "rebuilt menu displays the saved selected width")
findItem(rebuilt_widths,"2 pt").callback()
check(findItem(width_items,"2 pt").checked_func(), "existing and rebuilt menus reflect the current setting")
findItem(rebuilt_widths,"1.25 pt").callback()
local Calibration = dofile(base.."calibration.lua")
local targets={{x=90,y=175},{x=510,y=175},{x=90,y=675}}
local raw={{x=8250,y=1500},{x=8250,y=8500},{x=3250,y=1500}}
local map=Calibration.solve(raw,targets)
check(map and Calibration.valid(map),"calibration handles swapped and reversed axes")
local transformed=Calibration.apply(map,{x=5750,y=5000})
check(near(transformed.x,300) and near(transformed.y,425),"calibration maps independent interior point")
check(not Calibration.solve({{x=1,y=1},{x=2,y=2},{x=3,y=3}},targets),"collinear calibration rejected")

-- ReaderReady runs before KOReader shows its reader window. Auto activation
-- must wait until that window exists, then keep the toolbar above it.
local ready_callbacks={}
local immediate_tick=Manager.nextTick
Manager.nextTick=function(_,task) ready_callbacks[#ready_callbacks+1]=task end
plugin:onReaderReady()
check(not plugin.overlay and input_opens==0 and #ready_callbacks==1,
    "ReaderReady defers toolbar and pen startup until the reader is shown")
Manager:show(ui)
table.remove(ready_callbacks,1)()
Manager.nextTick=immediate_tick
check(plugin.overlay and plugin.writing and windows[#windows]==plugin.overlay,
    "PDF opens with persistent toolbar and automatic writing above the reader")
check(plugin.overlay.disable_double_tap==false and plugin.overlay.allow_concurrent_taps==true
    and plugin.overlay.tap_interval_override==17 and core_input.disable_double_tap==false
    and core_input.allow_concurrent_taps==true and core_input.tap_interval_override==17,
    "showing the dock preserves the reader's double-tap, concurrent-touch and tap-interval preferences")

-- Calibrate by production event handling, then write in a cropped/zoomed page.
plugin:startWriting() -- already active; must not open another pen adapter
check(input_opens==1, "starting an already active writer does not reopen its input")
check(plugin.overlay and plugin.calibration.index==1,"first start calibrates")
local overlay=plugin.overlay
check(overlay.toolbar.state.calibration and overlay.toolbar.state.calibration.index==1,"first calibration instruction displayed")
plugin:showPenWidthPicker()
check(not plugin.width_dialog and windows[#windows]==overlay,
    "pen width popup does not cover the active calibration crosses")
plugin:penEvent{phase="down",x=2,y=3,eraser=false}
plugin:penEvent{phase="up",x=2,y=3,cancelled=true}
check(plugin.calibration.index==1,"cancelled input cannot calibrate")
for i,target in ipairs(plugin.calibration.targets) do
    -- Identity raw axes simplify subsequent handwriting events.
    plugin:penEvent{phase="down",x=target.x,y=target.y,eraser=false}
    plugin:penEvent{phase="up",x=target.x,y=target.y,eraser=false}
end
check(not plugin.calibration and plugin.mapping and next(settings.calibrations),"calibration persists after three taps")
repaintPage()
local saved_before_first=saved
plugin:penEvent{phase="down",x=100,y=200,eraser=false}
plugin:penEvent{phase="move",x=140,y=230,eraser=false}
plugin:penEvent{phase="up",x=140,y=230,eraser=false}
check(#store:page(1)==1 and #store:page(1)[1].points==2,"pen stroke committed")
check(near(store:page(1)[1].points[1].x,45) and near(store:page(1)[1].points[1].y,85),"ink stored in page coordinates")
check(saved==saved_before_first and plugin.save_task and tasks[plugin.save_task]==0.75,
    "pen lift queues an idle save without blocking on disk IO")
flushSave()
check(saved==saved_before_first+1 and not plugin.save_task, "idle save persists the completed stroke")
plugin:penEvent{phase="down",x=350,y=200,eraser=false}
plugin:penEvent{phase="up",x=360,y=210,eraser=false}
check(#store:page(1)[2].points==2,"final release coordinate extends ink")
local previous_idle_save=plugin.save_task
store.pages[1][2]=nil
overlay:onGesture{ges="swipe",pos={x=100,y=300}}
check(view.state.page==1,"palm gestures cannot change page")
plugin:penEvent{phase="down",x=120,y=200,eraser=true}
check(not plugin.save_task and not tasks[previous_idle_save], "next contact cancels the pending idle disk write")
plugin:penEvent{phase="move",x=120,y=240,eraser=true}
plugin:penEvent{phase="up",x=120,y=240,eraser=true}
check(#store:page(1)==2 and not store.undo_group,
    "rear eraser cuts the contacted part into two surviving fragments and ends undo group")
check(near(store:page(1)[1].points[1].x,45)
    and near(store:page(1)[2].points[#store:page(1)[2].points].x,65),
    "a small rear eraser preserves the original stroke's distant endpoints")
tapButton(overlay,"Undo")
check(#store:page(1)==1,"toolbar undo restores erased ink")
repaintPage()
plugin:penEvent{phase="down",x=180,y=300,eraser=false}
plugin:penEvent{phase="up",x=180,y=300,eraser=false}
check(#store:page(1)==2,"finger toolbar action does not suppress next pen stroke")

-- Clip a stroke when it leaves the page; do not connect it after re-entry.
plugin:penEvent{phase="down",x=200,y=350,eraser=false}
plugin:penEvent{phase="move",x=10,y=350,eraser=false}
plugin:penEvent{phase="move",x=300,y=350,eraser=false}
plugin:penEvent{phase="up",x=300,y=350,eraser=false}
check(#store:page(1)==3 and #store:page(1)[3].points==1,"page boundary never creates bridging ink")
plugin:penEvent{phase="down",x=200,y=400,eraser=false}
Manager:show{ text="dialog" }
plugin:penEvent{phase="move",x=230,y=400,eraser=false}
check(#store:page(1)==4,"opening dialog finishes current stroke")
Manager:close(windows[#windows])
plugin:penEvent{phase="up",x=230,y=400,eraser=false}
test_now=test_now+0.2
local before_page_navigation=reader_events.Gesture
check(overlay:onGesture{ges="swipe",pos={x=550,y=400}}==true and reader_events.Gesture==before_page_navigation+1,
    "finger page navigation remains available while pen capture stays active")
ui:handleEvent{handler="onGotoPage",args={2}}
plugin:onPageUpdate()
check(view.state.page==2,"normal reader navigation changes page")
plugin:penEvent{phase="down",x=200,y=300,eraser=false}
plugin:penEvent{phase="up",x=200,y=300,eraser=false}
check(#store:page(2)==1,"new page receives pen ink")
doc:writeDocument()
check(core_writes==1 and adopted==1,"trusted core PDF write rebinds source identity")
plugin:exportPDF()
check(export_count==1,"native PDF copy export invoked")
Manager:close(windows[#windows])
plugin:penEvent{phase="down",x=200,y=500,eraser=false}
plugin:onSuspend()
check(not plugin.adapter and not plugin.overlay and closed==1,"suspend closes adapter and overlay")
check(#store:page(2)==2,"suspend saves unfinished stroke")
check(not next(tasks),"suspend removes poll timer")
plugin:startWriting()
check(not plugin.calibration,"saved calibration reused")
rotation=2
plugin:pollPen()
check(plugin.writing and plugin.overlay and plugin.calibration and closed==2,
    "orientation changes reopen capture and request calibration for the new orientation")
rotation=0
plugin:pollPen()
check(plugin.writing and not plugin.calibration and closed==3,
    "returning to a calibrated orientation resumes capture automatically")
plugin:stopWriting()
view.page_scroll=true
plugin:startWriting()
check(not plugin.writing and plugin.overlay,"continuous view rejects writing while retaining the toolbar")
view.page_scroll=false
Manager:close(windows[#windows])
doc.configurable.text_wrap=1
plugin:startWriting()
check(not plugin.writing and plugin.overlay,"reflow rejects writing while retaining the toolbar")
doc.configurable.text_wrap=0
Manager:close(windows[#windows])
fail_save=true
plugin:startWriting()
check(not plugin.writing and plugin.overlay,"write failure prevents capture while retaining controls")
check(notices[#notices]:find("disk full",1,true),"save failure displayed")

-- Persistent controls support ordinary reading gestures and a reliable manual
-- eraser even on a driver which does not identify the rear rubber itself.
fail_save=false
Manager:close(windows[#windows])
plugin:startWriting()
local persistent_overlay=plugin.overlay
test_now=test_now+0.2
check(plugin.writing and plugin.overlay==persistent_overlay and windows[#windows]==persistent_overlay,
    "compact pen controls remain visible while reading and pen capture coexist")
local gestures_before_integrated,back_before_integrated=reader_events.Gesture,reader_events.Back
check(persistent_overlay:onGesture{ges="swipe",pos={x=250,y=300}}==true
    and persistent_overlay:onBack()==true and reader_events.Gesture==gestures_before_integrated+1
    and reader_events.Back==back_before_integrated+1, "ordinary finger gestures and Back reach the reader without changing modes")
check(not persistent_overlay.toolbar:getButtonRect("read") and not persistent_overlay.toolbar:getButtonRect("write"),
    "compact dock has no separate Read or Write buttons")

-- Drive the actual window-dispatch boundary, not only Overlay:onGesture's
-- return value. ReaderUI is an ordinary lower window and does not receive
-- events unless the dock explicitly delegates them.
local event_module=modules["ui/event"]
local navigation={ges="double_tap",pos={x=250,y=300}}
local gestures_before_dispatch=reader_events.Gesture
local nonforwarding_window=Class:new{onGesture=function() return false end}
Manager:show(nonforwarding_window)
Manager:sendEvent(event_module:new("Gesture",navigation))
check(reader_events.Gesture==gestures_before_dispatch,
    "UIManager returning false from an overlay does not implicitly reach the reader")
Manager:close(nonforwarding_window)
Manager:sendEvent(event_module:new("Gesture",navigation))
check(reader_events.Gesture==gestures_before_dispatch+1 and reader_last.Gesture==navigation,
    "UIManager dispatch delivers a normal finger gesture to ReaderUI exactly once")
local back_before_dispatch=reader_events.Back
Manager:sendEvent(event_module:new("Back"))
check(reader_events.Back==back_before_dispatch+1,
    "UIManager dispatch delivers Back to ReaderUI exactly once")
local page_key={key="PageDown"}
for _,name in ipairs{"KeyPress","KeyRepeat","KeyRelease"} do
    local before=reader_events[name]
    Manager:sendEvent(event_module:new(name,page_key))
    check(reader_events[name]==before+1 and reader_last[name]==page_key,
        "dock forwards reader keyboard events once with the original key object")
end

local erased_button=persistent_overlay.toolbar:getButtonRect("eraser")
local gestures_before_dock=reader_events.Gesture
Manager:sendEvent(event_module:new("Gesture",{ges="tap",
    pos={x=erased_button.x+erased_button.w/2,y=erased_button.y+erased_button.h/2}}))
check(plugin.selected_tool=="eraser" and reader_events.Gesture==gestures_before_dock,
    "dock actions are consumed and never forwarded as reader page gestures")
local pen_button=persistent_overlay.toolbar:getButtonRect("pen")
Manager:sendEvent(event_module:new("Gesture",{ges="tap",
    pos={x=pen_button.x+pen_button.w/2,y=pen_button.y+pen_button.h/2}}))
dismissWidthPicker()
plugin.adapter.decoder.present=true
Manager:sendEvent(event_module:new("Gesture",{ges="swipe",pos={x=250,y=300}}))
check(reader_events.Gesture==gestures_before_dock,
    "UIManager dispatch cannot send a palm gesture to the reader while the pen is near")
plugin.adapter.decoder.present=false
test_now=test_now+0.2

local modal_gestures,modal_backs=0,0
local modal=Class:new{modal=true,
    onGesture=function() modal_gestures=modal_gestures+1; return true end,
    onBack=function() modal_backs=modal_backs+1; return true end,
    onKeyPress=function() return false end}
local reader_gestures_before_modal=reader_events.Gesture
local reader_backs_before_modal=reader_events.Back
local reader_keys_before_modal=reader_events.KeyPress
Manager:show(modal)
Manager:sendEvent(event_module:new("Gesture",{ges="tap",
    pos={x=erased_button.x+erased_button.w/2,y=erased_button.y+erased_button.h/2}}))
Manager:sendEvent(event_module:new("Back"))
Manager:sendEvent(event_module:new("KeyPress",page_key))
check(modal_gestures==1 and modal_backs==1 and plugin.selected_tool=="pen"
    and reader_events.Gesture==reader_gestures_before_modal and reader_events.Back==reader_backs_before_modal,
    "a top modal retains its gesture and Back handling without triggering the dock or reader")
check(reader_events.KeyPress==reader_keys_before_modal,
    "an unhandled modal key cannot leak through a lower dock into ReaderUI")
check(persistent_overlay:forwardReaderEvent("Gesture",navigation)==false
    and reader_events.Gesture==reader_gestures_before_modal,
    "reader forwarding refuses direct delegation while a modal covers the dock")
local previous_calls_before_modal=core_previous_calls
check(core_input.stylus_callback(core_input,{slot=4,id=4,tool=1,x=250,y=300})==false
    and core_previous_calls==previous_calls_before_modal+1,
    "native stylus input preserves the modal's normal input route")
Manager:close(modal)
core_input.stylus_callback(core_input,{slot=4,id=-1,tool=0})
test_now=test_now+0.2
Manager:sendEvent(event_module:new("Gesture",navigation))
check(reader_events.Gesture==reader_gestures_before_modal+1,
    "reader navigation resumes exactly once after the modal closes")
check(core_input.disable_double_tap==false and core_input.allow_concurrent_taps==true
    and core_input.tap_interval_override==17,
    "closing a modal restores the reader's input preferences through the dock")

local ensureStore=plugin.ensureStore
plugin.ensureStore=function() return nil end
plugin.store=nil
local undo_without_store=pcall(tapButton,persistent_overlay,"Undo")
check(undo_without_store and not plugin.store, "visible Undo cannot crash when sidecar loading was refused")
plugin.store,plugin.ensureStore=store,ensureStore
tapButton(persistent_overlay,"Pen")
check(plugin.writing and plugin.selected_tool=="pen" and plugin.overlay==persistent_overlay,
    "Pen control selects drawing without replacing the always-active controls")
core_input.gesture_detector.active_contacts[0]={slot=0}
local consumed_core_pen=core_input.stylus_callback(core_input,{slot=4,id=4,tool=2,x=250,y=300})
check(consumed_core_pen and not core_input.gesture_detector.active_contacts[0],
    "native pen callback consumes duplicate rubber events and cancels stale palm contacts")
check(persistent_overlay:onGesture{ges="swipe",pos={x=250,y=300}}==true,
    "a nearby pen absorbs palm gestures without an explicit writing mode")
core_input.stylus_callback(core_input,{slot=4,id=-1,tool=0,x=250,y=300})
test_now=test_now+0.2
local gestures_before_proximity_leave=reader_events.Gesture
check(persistent_overlay:onGesture{ges="swipe",pos={x=250,y=300}}==true and plugin.writing
    and reader_events.Gesture==gestures_before_proximity_leave+1,
    "finger navigation resumes when the pen leaves proximity while capture remains active")
tapButton(persistent_overlay,"Erase")
check(plugin.selected_tool=="eraser" and plugin.writing, "toolbar offers erasing through the pen tip")
tapButton(persistent_overlay,"Pen")
check(plugin.selected_tool=="pen", "Pen button restores normal drawing")
local menus_before=menu_shows
tapButton(persistent_overlay,"Menu")
check(menu_shows==menus_before+1, "persistent toolbar can open the KOReader menu")
local dock_rect=persistent_overlay.toolbar:getRect()
check(dock_rect.x>0 and dock_rect.w<width/8 and dock_rect.h<height/2 and dock_rect.y>0,
    "controls occupy a compact floating dock at the left edge")
tapButton(persistent_overlay,"Collapse")
local compact_rect=persistent_overlay.toolbar:getRect()
check(compact_rect.h<dock_rect.h and not persistent_overlay.toolbar:getButtonRect("pen")
    and plugin.settings.toolbar_collapsed, "collapse hides tool rows and saves a small handle preference")
tapButton(persistent_overlay,"Collapse")
check(persistent_overlay.toolbar:getButtonRect("pen") and not plugin.settings.toolbar_collapsed,
    "the compact handle restores the full dock")

-- A raw tip tap selects tools directly; its native pen duplicate must not
-- execute a second toolbar action. Rear rubber touches cannot press buttons.
local points_before_toolbar=#store:page(1)
local eraser_button=persistent_overlay.toolbar:getButtonRect("eraser")
local tx,ty=eraser_button.x+eraser_button.w/2,eraser_button.y+eraser_button.h/2
plugin:penEvent{phase="down",x=tx,y=ty,eraser=false}
local native_toolbar_duplicate=core_input.stylus_callback(core_input,{slot=4,id=4,tool=1,x=tx,y=ty})
check(native_toolbar_duplicate and plugin.toolbar_contact=="eraser" and plugin.selected_tool=="pen",
    "native toolbar pen contact does not interrupt or prematurely activate its raw contact")
plugin:penEvent{phase="up",x=tx,y=ty,eraser=false}
core_input.stylus_callback(core_input,{slot=4,id=-1,tool=0})
check(plugin.selected_tool=="eraser" and #store:page(1)==points_before_toolbar,
    "raw pen tap changes the selected tool without drawing an unwanted stroke")
local collapse_button=persistent_overlay.toolbar:getButtonRect("collapse")
local cx,cy=collapse_button.x+collapse_button.w/2,collapse_button.y+collapse_button.h/2
plugin:penEvent{phase="down",x=cx,y=cy,eraser=true}
plugin:penEvent{phase="up",x=cx,y=cy,eraser=true}
check(not persistent_overlay.toolbar.collapsed and plugin.selected_tool=="eraser"
    and #store:page(1)==points_before_toolbar, "rear rubber cannot activate dock controls or alter ink underneath them")
tapButton(persistent_overlay,"Pen")

-- The Pen icon opens KOReader's native modal picker rather than requiring a
-- Tools-menu trip. Selecting a width applies only to subsequent strokes.
test_now=test_now+0.2
local picker_button=persistent_overlay.toolbar:getButtonRect("pen")
persistent_overlay:onGesture{ges="tap",pos={x=picker_button.x+picker_button.w/2,y=picker_button.y+picker_button.h/2}}
local picker=plugin.width_dialog
check(picker and picker.title=="Pen width" and #picker.buttons==5 and windows[#windows]==picker,
    "Pen icon opens a native width dialog with four choices and Close")
local original_width=plugin.settings.width
check(picker.buttons[2][1].text=="✓ 1.25 pt" and picker.buttons[5][1].text=="Close",
    "width picker marks the current choice and provides a dismissal button")
local previous_stroke=store:page(view.state.page)[1]
local previous_stroke_width=previous_stroke.width
local picker_page_count=#store:page(view.state.page)
local previous_callback_count=core_previous_calls
check(core_input.stylus_callback(core_input,{slot=4,id=4,tool=1,x=280,y=300})==false
    and core_previous_calls==previous_callback_count+1,
    "native stylus input follows the width dialog's modal input route")
plugin:penEvent{phase="down",x=280,y=300,eraser=false}
plugin:penEvent{phase="up",x=300,y=300,eraser=false}
check(#store:page(view.state.page)==picker_page_count and not plugin.stroke,
    "touching a width dialog cannot create handwriting behind it")
local writes_before_picker=settings_writes
picker.buttons[4][1].callback()
core_input.stylus_callback(core_input,{slot=4,id=-1,tool=0})
check(plugin.settings.width==3 and settings_writes==writes_before_picker+1
    and not plugin.width_dialog and windows[#windows]==persistent_overlay,
    "choosing a width saves it and closes the native dialog")
plugin:penEvent{phase="down",x=280,y=330,eraser=false}
plugin:penEvent{phase="move",x=300,y=330,eraser=false}
plugin:penEvent{phase="up",x=300,y=330,eraser=false}
check(store:page(view.state.page)[#store:page(view.state.page)].width==3
    and previous_stroke.width==previous_stroke_width,
    "new ink uses the selected width while existing annotations retain their widths")
local invalid_width_writes=settings_writes
for _,invalid in ipairs{0,-1,11,0/0,math.huge,"wide"} do
    check(not plugin:setPenWidth(invalid) and plugin.settings.width==3,
        "invalid pen widths cannot change the active width")
end
check(settings_writes==invalid_width_writes, "invalid widths do not persist settings")
plugin:setPenWidth(original_width)
plugin:showPenWidthPicker()
dismissWidthPicker()
check(not plugin.width_dialog and plugin.settings.width==original_width,
    "Close dismisses the width picker without changing the selected width")

-- The native dialog can execute a choice before the independent raw descriptor
-- drains the same tap. Closing the dialog must discard that backlog before it
-- can be interpreted as a new pen contact on the now-visible PDF.
for _,dismissal in ipairs{"width","close","outside"} do
    plugin:showPenWidthPicker()
    local dialog=plugin.width_dialog
    local before=#store:page(view.state.page)
    local resyncs_before=plugin.adapter.resyncs
    plugin.adapter.pending={
        {phase="down",x=315,y=345,eraser=false},
        {phase="up",x=315,y=345,eraser=false},
    }
    plugin.suppressed=true; plugin.toolbar_contact="pen"
    if dismissal=="width" then dialog.buttons[2][1].callback()
    elseif dismissal=="close" then dialog.buttons[#dialog.buttons][1].callback()
    else dialog.tap_close_callback(); Manager:close(dialog) end
    check(not plugin.width_dialog and #plugin.adapter.pending==0
        and plugin.adapter.resyncs==resyncs_before+1 and not plugin.suppressed and not plugin.toolbar_contact,
        dismissal.." picker dismissal drains native-tap raw backlog and resynchronizes capture")
    plugin:pollPen()
    check(#store:page(view.state.page)==before and not plugin.stroke,
        dismissal.." native picker tap cannot leave a dot behind the closed dialog")
    plugin.adapter.pending={
        {phase="down",x=330,y=360,eraser=false},
        {phase="move",x=340,y=365,eraser=false},
        {phase="up",x=340,y=365,eraser=false},
    }
    plugin:pollPen()
    check(#store:page(view.state.page)==before+1 and not plugin.stroke
        and #store:page(view.state.page)[before+1].points==2,
        dismissal.." picker dismissal permits the following fresh handwriting stroke")
end
plugin:showPenWidthPicker()
local held_dialog=plugin.width_dialog
local held_before=#store:page(view.state.page)
plugin.adapter.pending={{phase="down",x=315,y=345,eraser=false}}
held_dialog.buttons[#held_dialog.buttons][1].callback()
check(plugin.adapter.blocked_contact and #store:page(view.state.page)==held_before,
    "closing a picker during a held native tap blocks that contact until it lifts")
plugin.adapter.pending={{phase="move",x=325,y=345,eraser=false},{phase="up",x=325,y=345,eraser=false}}
plugin:pollPen()
check(not plugin.adapter.blocked_contact and #store:page(view.state.page)==held_before,
    "a held picker contact's remaining move and release cannot draw through the closed modal")

-- New segments must touch only a small framebuffer region and must not replay
-- every old stroke. Real production rasterization runs against the buffer mock.
store.pages={[1]={}}
view.state.page=1
plugin:invalidateCache()
repaintPage()
local function drawStroke(x1,y1,x2,y2,eraser)
    local erasing=eraser or plugin.selected_tool=="eraser"
    plugin:penEvent{phase="down",x=x1,y=y1,eraser=eraser or false}
    plugin:penEvent{phase="move",x=x2,y=y2,eraser=eraser or false}
    plugin:penEvent{phase="up",x=x2,y=y2,eraser=eraser or false}
    if erasing then plugin:pollPen(); Manager:processRepaints() end
end
local first_paint_count=#native_paints
local copies_before=framebuffer_copies
local refreshes_before=#refreshes
drawStroke(100,210,140,210)
local incremental_cost=#native_paints-first_paint_count
plugin:pollPen()
local last_refresh=refreshes[#refreshes]
check(Screen.bb:pixel(110,210)==0 and Screen.bb:pixel(500,500)==99,
    "incremental ink draws into the live framebuffer while preserving unrelated PDF pixels")
check(framebuffer_copies==copies_before and incremental_cost>0 and incremental_cost<15,
    "new horizontal segment uses a bounded number of native spans without copying the page")
check(last_refresh.w==nil and last_refresh.mode=="fast" and last_refresh.rect.w<60
    and last_refresh.rect.h<10,
    "pen polling refreshes only its narrow ink rectangle without requesting a ReaderUI repaint")
local repainted_reader=false
for i=refreshes_before+1,#refreshes do if refreshes[i].w==ui then repainted_reader=true end end
check(not repainted_reader, "normal pen motion avoids repainting the PDF reader")

for i=1,500 do
    store.pages[1][#store.pages[1]+1]={width=1.25,points={{x=10,y=200},{x=200,y=200}}}
end
repaintPage()
local many_strokes_before=#native_paints
drawStroke(100,230,140,230)
check(#native_paints-many_strokes_before==incremental_cost,
    "adding 500 saved strokes does not increase incremental drawing work")
drawStroke(120,190,120,240) -- survives a local endpoint erase of the first stroke
local copies_before_erase=framebuffer_copies
local blits_before_erase=#native_blits
local circles_before_erase=#native_circles
tapButton(persistent_overlay,"Erase")
-- Hover previews the eraser without changing saved ink or flashing the display.
plugin:flushInkRefresh()
local no_contact_refreshes=#refreshes
local no_contact_count=#store:page(1)
plugin:penEvent{phase="hover",x=105,y=210,eraser=false}
plugin:flushInkRefresh()
check(#refreshes==no_contact_refreshes+1 and #store:page(1)==no_contact_count
    and plugin.eraser_cursor and plugin.eraser_cursor.hover
    and refreshes[#refreshes].mode=="fast",
    "hover shows a sparse non-destructive preview with no flashing waveform")
local after_preview=#refreshes
plugin:penEvent{phase="hover",x=105,y=210,eraser=false}
plugin:flushInkRefresh()
check(#refreshes==after_preview,"unchanged hover does not request another screen update")
check(Manager:displayPixel(100,210)==0, "erasure begins from actually presented handwriting")
plugin:penEvent{phase="down",x=105,y=210,eraser=false}
plugin:pollPen()
check(plugin.stroke and plugin.stroke.eraser and not plugin.eraser_cursor
    and #plugin.stroke.erase_path==1,
    "eraser contact queues geometry while painting its temporary mask")
local radius=plugin:eraserRadius()
check(#native_circles==circles_before_erase and Screen.bb:pixel(105,210)==255
    and Screen.bb:pixel(105+radius-1,210)==255,
    "fast capsule paints an opaque eraser footprint without costly cursor redraw")
check(plugin.eraser_cleanup_task==nil,
    "active erasing does not schedule a flashing refresh before release")
local erase_refresh=refreshes[#refreshes]
check(erase_refresh.w==nil and erase_refresh.mode=="fast" and plugin.stroke and plugin.stroke.eraser,
    "active eraser contact requests a direct fast refresh before lift or page navigation (reader="
        ..tostring(erase_refresh.w==ui)..", mode="..tostring(erase_refresh.mode)..", stroke="
        ..tostring(plugin.stroke and plugin.stroke.eraser)..")")
local blits_during_contact=#native_blits
local stored_during_contact=#store:page(1)
plugin:penEvent{phase="move",x=106,y=210,eraser=false}
check(framebuffer_copies==copies_before_erase and #native_blits==blits_during_contact
    and #store:page(1)==stored_during_contact,
    "movement paints incrementally without touching saved strokes or blitting the PDF")
Manager:processRepaints()
check(Manager:displayPixel(100,210)==255 and Manager:displayPixel(140,210)==0
    and Manager:displayPixel(110,210)==255 and view.state.page==1,
    "erasing is visible immediately on the physical display and preserves the uncontacted tail")
plugin:penEvent{phase="move",x=105,y=210,eraser=false}
plugin:penEvent{phase="up",x=105,y=210,eraser=false}
local release_request=refreshes[#refreshes]
check(#native_blits==blits_during_contact and release_request.w==ui
    and release_request.mode=="flashui" and not plugin.eraser_cursor,
    "release requests one authoritative ReaderUI PDF repaint and regional flash")
check(release_request.rect.x<=105 and release_request.rect.x+release_request.rect.w>=105
    and release_request.rect.w<80 and release_request.rect.h<100,
    "ghosting cleanup is localized with a small padding around the white mask")
check(not plugin.refresh_rect and not plugin.eraser_cleanup_task,
    "release discards pending fast refreshes instead of racing the PDF redraw")
Manager:processRepaints()
check(Screen.bb:pixel(100,210)==255 and Screen.bb:pixel(140,210)==0,
    "touching one endpoint clears only the nearby ink and preserves its distant tail")
check(Screen.bb:pixel(110,210)==77 and Screen.bb:pixel(500,500)==99,
    "reader redraw restores nonwhite PDF content beneath the temporary white mask")
check(Screen.bb:pixel(120,210)==0,
    "surviving intersecting ink is repainted on the real PDF page")
check(framebuffer_copies>copies_before_erase,
    "repaint replaces the old clean snapshot with fresh PDF pixels")
check(erase_refresh.rect.x<=105 and erase_refresh.rect.x+erase_refresh.rect.w>=105
    and erase_refresh.rect.w<60 and erase_refresh.rect.h<100,
    "erase refresh covers only the cut and cursor while preserving partial survivors")
local release_refresh=refreshes[#refreshes]
check(release_refresh.w==ui and release_refresh.mode=="flashui"
    and not plugin.eraser_cleanup_task and plugin.eraser_cleanup_rect==nil,
    "release requests a single high-quality refresh attached to an actual reader repaint")
check(Manager:displayPixel(110,210)==77 and Manager:displayPixel(140,210)==0
    and not plugin.eraser_cursor,
    "after release the PDF pixels and surviving ink are visibly restored")
local after_release=#refreshes
plugin.last_eraser_hover=nil
plugin:penEvent{phase="hover",x=105,y=210,eraser=false}
plugin:pollPen()
check(#refreshes==after_release+1 and plugin.eraser_cursor
    and plugin.eraser_cursor.hover and refreshes[#refreshes].mode=="fast",
    "after cleanup hover again previews without erasing or flashing")
plugin:penEvent{phase="leave"}
plugin:pollPen()
check(not plugin.eraser_cursor,"leaving proximity clears the hover preview")
tapButton(persistent_overlay,"Pen")
drawStroke(200,260,220,260)
local count_before_rear=#store:page(1)
drawStroke(205,260,205,260,true)
check(plugin.selected_tool=="pen" and #store:page(1)==count_before_rear
    and Screen.bb:pixel(200,260)==255 and Screen.bb:pixel(220,260)==0,
    "rear eraser works independently of the selected Pen tool and retains the untouched tail")

-- Cache validity follows the rendered page, not just the lifetime of writing
-- mode. Moving pages or changing framebuffer inversion must use normal repaint.
local stale_snapshot=plugin.clean_bb
view.state.page=2
plugin:onPageUpdate()
check(stale_snapshot.freed and not plugin.clean_bb, "page change frees the previous clean framebuffer snapshot")
local paints_before_stale=#native_paints
drawStroke(250,280,270,280)
check(#native_paints==paints_before_stale and refreshes[#refreshes].w==ui,
    "pen input cannot draw incrementally using a different page's snapshot")
view.state.page=1
plugin:onPageUpdate()
repaintPage()
local paints_before_night=#native_paints
Screen.bb.inverse=1
drawStroke(250,290,270,290)
check(#native_paints==paints_before_night and refreshes[#refreshes].w==ui,
    "night-mode framebuffer changes invalidate incremental rendering")
Screen.bb.inverse=0
plugin:invalidateCache()
repaintPage()
local paints_before_forced=#native_paints
Screen.forced_rotation=true
drawStroke(340,330,360,330)
check(#native_paints==paints_before_forced and refreshes[#refreshes].w==ui,
    "forced framebuffer rotation uses the reader's safe painting path")
Screen.forced_rotation=nil
plugin:invalidateCache()
repaintPage()
local copies_before_offscreen=framebuffer_copies
plugin:paintInk(Buffer.new(),0,0)
check(framebuffer_copies==copies_before_offscreen and not plugin.clean_bb,
    "offscreen rendering cannot supply a clean snapshot for the live display")
repaintPage()
local old_dimensions_snapshot=plugin.clean_bb
plugin:onSetDimensions()
check(old_dimensions_snapshot.freed and not plugin.clean_bb
    and plugin.overlay.dimen.w==width and plugin.overlay.dimen.h==height,
    "screen dimension changes update persistent toolbar geometry and free cached screen pixels")
repaintPage()

-- A thin survivor's rounded cap may overlap an erase rectangle even while
-- its centerline lies outside. Regional replay must restore those edge pixels.
local regular_width,regular_zoom=plugin.settings.width,view.state.zoom
store.pages[1]={}
plugin.settings.width=0.75
view.state.zoom=1
plugin:onZoomUpdate()
repaintPage()
drawStroke(100,350,140,350)
drawStroke(117,347.4,117,347.4)
check(Screen.bb:pixel(117,348)==0, "thin pen tap raster includes its rounded edge cap")
tapButton(persistent_overlay,"Erase")
drawStroke(105,350,105,350,false)
check(#store:page(1)==2 and Screen.bb:pixel(117,348)==0,
    "regional erase preserves a survivor's cap even when its center lies outside the restored rectangle")
plugin.settings.width=regular_width
view.state.zoom=regular_zoom
tapButton(persistent_overlay,"Pen")
plugin:onZoomUpdate()
repaintPage()

-- Older annotations can run underneath the newly floating dock. Restoring
-- those strokes' full erase bounds must preserve the dock's visible border.
store.pages[1]={}
local under_dock_a=Geometry.screenToPage({x=35,y=250},plugin:transform())
local under_dock_b=Geometry.screenToPage({x=110,y=250},plugin:transform())
store:add(1,{width=1.25,points={under_dock_a,under_dock_b}})
repaintPage()
local visible_dock=persistent_overlay.toolbar:getRect()
local dock_border_x=visible_dock.x+visible_dock.w-1
check(plugin.clean_bb:pixel(dock_border_x,250)==255 and Screen.bb:pixel(dock_border_x,250)==0,
    "clean PDF snapshot excludes the dock which is painted above it")
drawStroke(95,250,95,250,true)
check(#store:page(1)==2 and Screen.bb:pixel(dock_border_x,250)==0 and Screen.bb:pixel(100,250)==255
    and Screen.bb:pixel(60,250)==0,
    "partial erasing beneath the dock preserves its border and the stroke's distant visible tail")

-- A stale or absent fast-drawing snapshot must not defer visual erasure until
-- the user changes pages. The core redraw is authoritative, and its requested
-- display rectangle covers a changed diagonal's whole former raster extent.
local function presentedMatchesFrameBuffer()
    for y=0,height-1 do for x=0,width-1 do
        if Manager:displayPixel(x,y)~=Screen.bb:pixel(x,y) then return false,x,y end
    end end
    return true
end
for _,cache_state in ipairs{"stale","missing"} do
    store.pages={[1]={}}; store.undo_stack={}
    local transform=plugin:transform()
    store:add(1,{width=1.25,points={Geometry.screenToPage({x=100,y=350},transform),
        Geometry.screenToPage({x=430,y=420},transform)}})
    store:add(1,{width=1.25,points={Geometry.screenToPage({x=300,y=550},transform),
        Geometry.screenToPage({x=350,y=550},transform)}})
    plugin:invalidateCache(); repaintPage()
    check(Manager:displayPixel(265,385)==0,
        cache_state.." cache scenario starts with visibly presented ink")
    if cache_state=="missing" then plugin:invalidateCache() else plugin.clean_key="obsolete" end
    local circles_before=#native_circles
    local blits_before=#native_blits
    plugin:penEvent{phase="down",x=265,y=385,eraser=true}
    check(#store:page(1)==2 and plugin.stroke and plugin.stroke.eraser,
        cache_state.." cache records geometry only on release")
    check(Manager:displayPixel(265,385)==0 and #native_blits==blits_before,
        cache_state.." cache does not confuse pending framebuffer work with a completed physical refresh")
    local requests_before=#refreshes
    plugin:pollPen()
    local request=refreshes[#refreshes]
    check(#refreshes==requests_before+1 and request.w==nil and request.mode=="fast"
        and request.rect.x<=265 and request.rect.x+request.rect.w>=265
        and request.rect.y<=385 and request.rect.y+request.rect.h>=385
        and request.rect.w<60 and request.rect.h<60,
        cache_state.." cache uses a fast direct framebuffer refresh on contact")
    Manager:processRepaints()
    check(Manager:displayPixel(265,385)==255 and Manager:displayPixel(100,350)==0
        and Manager:displayPixel(430,420)==0 and Manager:displayPixel(325,550)==0
        and plugin.stroke and plugin.stroke.eraser and view.state.page==1,
        cache_state.." cache visibly clears the contacted area before eraser lift while preserving tails and unrelated ink")
    local matches,mx,my=presentedMatchesFrameBuffer()
    check(matches,cache_state.." cache partial display refresh matches authoritative repaint at "
        ..tostring(mx)..","..tostring(my))
    plugin:penEvent{phase="up",x=265,y=385,eraser=true}
    local release=refreshes[#refreshes]
    check(release.w==ui and release.mode=="flashui"
        and not plugin.refresh_rect and not plugin.eraser_cleanup_task,
        cache_state.." cache forces a real PDF paint before a localized high-quality refresh")
    plugin:pollPen(); Manager:processRepaints()
    check(#store:page(1)==3 and not plugin.eraser_cursor
        and #native_circles==circles_before,
        cache_state.." cache commits geometry and removes the mask on release")
    check(Manager:displayPixel(265,385)==255
        and Manager:displayPixel(100,350)==0 and Manager:displayPixel(325,550)==0,
        cache_state.." cache restores the reader and surviving ink on lift")
    local before_hover=#refreshes
    plugin:penEvent{phase="hover",x=265,y=385,eraser=true}
    plugin:pollPen(); Manager:processRepaints()
    check(not plugin.eraser_cursor and #refreshes==before_hover,
        cache_state.." cache idle hover does not request a refresh")
end
check(avoid_flash_requests==0,
    "content erasure keeps its native partial waveform without the UI flash-avoidance downgrade")

-- Feed Linux frames through the real decoder into main, rather than assuming
-- an already-decoded eraser=true event. The user's log reports Wacom rubber,
-- BTN_TOUCH and pressure, with two tool entries and repeated contacts.
local ActualInput=real_dofile(base.."input.lua")
local C=ActualInput.codes
local decoder=ActualInput.newDecoder{has_touch=true,eraser_key="BTN_TOOL_RUBBER"}
local original_decoder,original_mapping=plugin.adapter.decoder,plugin.mapping
plugin.adapter.decoder=decoder
plugin.mapping={a=0,b=0.025,c=50,d=0.03,e=0,f=50} -- real raw axes, swapped
store.pages[1]={}
local untouched_a=Geometry.screenToPage({x=430,y=510},plugin:transform())
local untouched_b=Geometry.screenToPage({x=450,y=510},plugin:transform())
store:add(1,{width=1.25,points={untouched_a,untouched_b}})
local emitted_eraser_samples=0
local hits_before_raw=plugin.eraser_stats and plugin.eraser_stats.hits or 0
local function raw(event_type,code,value)
    if event_type==C.EV_SYN then test_now=test_now+0.01 end
    decoder:feed(event_type,code,value,test_now,function(event)
        if event.eraser then emitted_eraser_samples=emitted_eraser_samples+1 end
        plugin:penEvent(event)
    end)
end
local function report() raw(C.EV_SYN,C.SYN_REPORT,0) end
for contact=1,9 do
    local raw_x,raw_y=7000+contact*50,9000+contact*100
    if contact==1 or contact==6 then
        raw(C.EV_KEY,C.BTN_TOOL_RUBBER,1)
        core_input.stylus_callback(core_input,{slot=4,id=-1,tool=2,x=raw_x,y=raw_y})
    end
    raw(C.EV_ABS,C.ABS_X,raw_x); raw(C.EV_ABS,C.ABS_Y,raw_y)
    raw(C.EV_ABS,C.ABS_PRESSURE,0); report()
    local target=Calibration.apply(plugin.mapping,{x=raw_x,y=raw_y})
    local a=Geometry.screenToPage({x=target.x-4,y=target.y},plugin:transform())
    local b=Geometry.screenToPage({x=target.x+4,y=target.y},plugin:transform())
    store:add(1,{width=1.25,points={a,b}})
    repaintPage()
    raw(C.EV_KEY,C.BTN_TOUCH,1); raw(C.EV_ABS,C.ABS_PRESSURE,3472); report()
    local active_stroke=plugin.stroke
    core_input.gesture_detector.active_contacts[4]={slot=4}
    local duplicate_consumed=core_input.stylus_callback(core_input,
        {slot=4,id=4,tool=2,x=target.x,y=target.y})
    check(duplicate_consumed and plugin.stroke==active_stroke and active_stroke.eraser
        and plugin.selected_tool=="pen" and not core_input.gesture_detector.active_contacts[4],
        "core rubber contact cannot interrupt the active raw eraser or change the selected Pen tool")
    raw(C.EV_ABS,C.ABS_Y,raw_y+1); raw(C.EV_ABS,C.ABS_PRESSURE,2300); report()
    raw(C.EV_KEY,C.BTN_TOUCH,0); raw(C.EV_ABS,C.ABS_PRESSURE,0); report()
    check(#store:page(1)==1 and not plugin.stroke and not store.undo_group,
        "decoded Wacom rear contact removes mapped handwriting and completes its undo gesture")
    if contact==5 then
        raw(C.EV_KEY,C.BTN_TOOL_RUBBER,0); report()
        core_input.stylus_callback(core_input,{slot=4,id=-1,tool=0})
    end
end
check(emitted_eraser_samples==27 and plugin.eraser_stats.hits-hits_before_raw==9,
    "two rubber tool sessions with nine contact cycles decode into actual handwriting erasures")
check(near(plugin.eraser_stats.last_screen.x,297.525)
    and near(plugin.eraser_stats.last_page.x,143.7625),
    "physical eraser coordinates pass through the calibrated raw-to-screen-to-PDF transform")
raw(C.EV_KEY,C.BTN_TOOL_RUBBER,0); report()
core_input.stylus_callback(core_input,{slot=4,id=-1,tool=0})
test_now=test_now+0.2
local gestures_before_rubber_leave=reader_events.Gesture
check(persistent_overlay:onGesture{ges="swipe",pos={x=550,y=500}}==true and plugin.writing
    and reader_events.Gesture==gestures_before_rubber_leave+1,
    "finger gestures resume after rear-tool proximity ends without changing capture mode")
plugin.adapter.decoder,plugin.mapping=original_decoder,original_mapping
plugin:invalidateCache(); repaintPage()

local written_before_export=saved
check(plugin.save_task and store.dirty, "recent handwriting awaits its idle save")
local exports_before=export_count
tapButton(persistent_overlay,"Export")
check(not plugin.save_task and not store.dirty and saved==written_before_export+1
    and export_count==exports_before+1, "export immediately flushes queued ink before making a PDF copy")
Manager:close(windows[#windows])

-- The rear eraser diagnostic consumes samples without changing handwriting.
local stroke_count_before_test=#store:page(1)
plugin:testEraser()
check(plugin.eraser_test and plugin.eraser_test_task and tasks[plugin.eraser_test_task]==10,
    "rear eraser diagnostic opens a timed capture window")
plugin:showPenWidthPicker()
check(not plugin.width_dialog, "width picker does not cover a rear eraser diagnostic capture")
drawStroke(120,210,120,210,true)
check(#store:page(1)==stroke_count_before_test, "eraser diagnostics never alter saved ink")
local eraser_test_task=plugin.eraser_test_task
tasks[eraser_test_task]=nil; eraser_test_task()
check(not plugin.eraser_test and notices[#notices]:find("rear eraser samples",1,true),
    "rear eraser diagnostic presents its collected report")
Manager:close(windows[#windows])

drawStroke(280,310,300,310)
test_now=test_now+0.2
local gestures_before_final_navigation=reader_events.Gesture
check(plugin.writing and persistent_overlay:onGesture{ges="swipe",pos={x=550,y=500}}==true
    and reader_events.Gesture==gestures_before_final_navigation+1,
    "finished handwriting does not require a mode switch before finger navigation")
flushSave()
drawStroke(280,320,300,320)
local written_before_suspend=saved
plugin:showPenWidthPicker()
check(plugin.width_dialog and windows[#windows]==plugin.width_dialog,
    "width picker can be open when the reader is suspended")
local suspending_adapter=plugin.adapter
local resyncs_before_suspend=suspending_adapter.resyncs
plugin:onSuspend()
check(not plugin.overlay and not plugin.writing and not plugin.save_task
    and not plugin.width_dialog and saved==written_before_suspend+1 and not next(tasks),
    "suspend forces durable save and removes pen, toolbar, width picker and delayed tasks")
check(suspending_adapter.resyncs==resyncs_before_suspend,
    "suspend closes the picker without draining or resynchronizing a descriptor being torn down")
plugin:onResume()
check(plugin.overlay and plugin.writing, "resume restores the persistent writing toolbar")

local close_callback
Manager.nextTick=function(_,task) close_callback=task end
plugin:onReaderReady()
local opens_before_close=input_opens
plugin:closeReader()
close_callback()
Manager.nextTick=immediate_tick
check(plugin.closing and not plugin.overlay and not plugin.writing and input_opens==opens_before_close,
    "a delayed ReaderReady callback cannot resurrect controls after document close")

-- Rendering must never touch toolbar or page margins, including pen thickness.
local Render=dofile(base.."render.lua")
local painted=0
local bb={paintRect=function(_,x,y,w,h)
    check(x>=30 and x+w<=40 and y>=70 and y+h<=80,"raster clipped to page")
    painted=painted+1
end}
Render.line(bb,{x=30,y=70},{x=40,y=80},8,0,{x=30,y=70,w=10,h=10})
check(painted>0,"clipped stroke renders")
print("UI, calibration and rendering: "..checks.." checks passed")
return checks
