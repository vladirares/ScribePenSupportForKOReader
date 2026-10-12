local module_path = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or ""
local Geometry = dofile(module_path .. "geometry.lua")
local JSON = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5

local Store = {}
Store.__index = Store

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function positiveInteger(value)
    return finite(value) and value >= 1 and value == math.floor(value)
end

local function cloneStroke(stroke)
    local copy = { width = stroke.width, points = {} }
    for i, p in ipairs(stroke.points) do copy.points[i] = { x = p.x, y = p.y } end
    return copy
end

local function validateStroke(stroke)
    if type(stroke) ~= "table" or not finite(stroke.width)
        or stroke.width <= 0 or stroke.width > 1000 or type(stroke.points) ~= "table"
        or #stroke.points == 0 then return nil, "Invalid ink stroke" end
    local count = 0
    for k, p in pairs(stroke.points) do
        if not positiveInteger(k) or k > #stroke.points or type(p) ~= "table"
            or not finite(p.x) or not finite(p.y)
            or math.abs(p.x) > 1000000 or math.abs(p.y) > 1000000 then
            return nil, "Invalid ink point"
        end
        count = count + 1
    end
    if count ~= #stroke.points then return nil, "Ink points must be an array" end
    return true
end

local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local data, read_error = file:read("*all")
    local closed, close_error = file:close()
    if not data then return nil, read_error end
    if not closed then return nil, close_error end
    return data
end

local function fingerprint(path)
    local attributes, err = lfs.attributes(path)
    if not attributes or attributes.mode ~= "file" then
        return nil, "Cannot read source PDF: " .. tostring(err or path)
    end
    local file, open_error = io.open(path, "rb")
    if not file then return nil, open_error end
    local update = md5()
    while true do
        local chunk, read_error = file:read(1024 * 1024)
        if not chunk then
            if read_error then file:close(); return nil, read_error end
            break
        end
        update(chunk)
    end
    local closed, close_error = file:close()
    if not closed then return nil, close_error end
    local after = lfs.attributes(path)
    if not after or after.size ~= attributes.size
        or after.modification ~= attributes.modification then
        return nil, "The source PDF changed while it was being read"
    end
    return { path = path, size = attributes.size, md5 = update() }, attributes
end

local function validateDocument(document, source)
    if type(document) ~= "table" then
        return nil, "Malformed Scribe Ink sidecar"
    end
    -- A newer schema or another PDF is not corruption. Falling back to an
    -- older backup in that case could silently discard newer/different ink.
    if document.format ~= "koreader-scribe-ink" or document.version ~= 1
        or document.coordinate_space ~= "mupdf-page" then
        return nil, "Unsupported Scribe Ink sidecar format, version or coordinate space", true
    end
    if type(document.source) ~= "table" or type(document.pages) ~= "table" then
        return nil, "Unsupported or malformed Scribe Ink sidecar"
    end
    if document.source.size ~= source.size or document.source.md5 ~= source.md5 then
        return nil, "Ink belongs to a different PDF; preserve the sidecar and restore the matching original PDF", true
    end
    local pages = {}
    for key, strokes in pairs(document.pages) do
        local page = type(key) == "string" and tonumber(key)
        if not positiveInteger(page) or tostring(page) ~= key or type(strokes) ~= "table" then
            return nil, "Invalid ink page"
        end
        local copy, count = {}, 0
        for i, stroke in pairs(strokes) do
            if not positiveInteger(i) or i > #strokes then return nil, "Ink strokes must be an array" end
            local ok, err = validateStroke(stroke)
            if not ok then return nil, err end
            copy[i] = cloneStroke(stroke)
            count = count + 1
        end
        if count ~= #strokes then return nil, "Ink strokes must be an array" end
        pages[page] = copy
    end
    return pages
end

local function loadDocument(path, source)
    local bytes, err = readFile(path)
    if not bytes then return nil, err end
    local called, document, decode_error = pcall(JSON.decode, bytes)
    if not called or not document then return nil, tostring(decode_error or document), bytes end
    local pages, validation_error, fatal = validateDocument(document, source)
    if not pages then return nil, validation_error, bytes, fatal end
    return pages, bytes, bytes
end

-- Checked write + fsync before the atomic POSIX rename. Never write the
-- installed sidecar in place, even when making its previous-version backup.
local function durableWrite(path, bytes)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local written, write_error = file:write(bytes)
    if not written then file:close(); return nil, write_error end
    local flushed, flush_error = file:flush()
    if not flushed then file:close(); return nil, flush_error end
    local synced, sync_error = ffiUtil.fsyncOpenedFile(file, true)
    if not synced then file:close(); return nil, sync_error or "File sync failed" end
    local closed, close_error = file:close()
    if not closed then return nil, close_error end
    return true
end

function Store.open(pdf_path)
    local source, attributes = fingerprint(pdf_path)
    if not source then return nil, attributes end
    local path = pdf_path .. ".scribeink.json"
    local pages, warning, original_bytes, disk_bytes, recovered
    if lfs.attributes(path) then
        local fatal
        pages, original_bytes, disk_bytes, fatal = loadDocument(path, source)
        if not pages then
            local primary_error = original_bytes
            if fatal then return nil, primary_error end
            if not disk_bytes then
                return nil, "Cannot read ink safely: " .. tostring(primary_error)
            end
            pages, original_bytes = loadDocument(path .. ".bak", source)
            if not pages then
                return nil, "Cannot open ink safely: " .. tostring(primary_error)
                    .. ". Backup: " .. tostring(original_bytes)
            end
            recovered = true
            warning = "Recovered ink from the previous saved version in " .. path .. ".bak"
        end
    elseif lfs.attributes(path .. ".bak") then
        pages, original_bytes = loadDocument(path .. ".bak", source)
        if not pages then return nil, "Cannot recover ink backup: " .. tostring(original_bytes) end
        recovered = true
        warning = "Recovered ink from " .. path .. ".bak"
    elseif lfs.attributes(path .. ".tmp") then
        -- An interrupted first save has no installed sidecar or backup yet.
        -- A temporary file never takes precedence over either installed file.
        pages, original_bytes = loadDocument(path .. ".tmp", source)
        if not pages then return nil, "Cannot recover unfinished ink save: " .. tostring(original_bytes) end
        recovered = true
        warning = "Recovered ink from an unfinished first save in " .. path .. ".tmp"
    else
        pages = {}
    end
    return setmetatable({ pdf_path = pdf_path, path = path, source = source,
        source_attributes = attributes, pages = pages, undo_stack = {},
        dirty = recovered or false, original_bytes = original_bytes,
        disk_bytes = disk_bytes, recovered = recovered or false }, Store), warning
end

function Store:page(number)
    return self.pages[number] or {}
end

-- Record inverse operations, keeping whole eraser gestures as one undo item.
function Store:beginUndo()
    if self.undo_group then return nil, "An undo gesture is already active" end
    self.undo_group = {}
    return true
end

function Store:endUndo()
    if self.undo_group and #self.undo_group > 0 then
        self.undo_stack[#self.undo_stack + 1] = self.undo_group
    end
    self.undo_group = nil
    -- Keep bounded session history without retaining copies of the whole book.
    if #self.undo_stack > 100 then table.remove(self.undo_stack, 1) end
    return true
end

function Store:_record(operation)
    if self.undo_group then
        self.undo_group[#self.undo_group + 1] = operation
    else
        self.undo_stack[#self.undo_stack + 1] = { operation }
        if #self.undo_stack > 100 then table.remove(self.undo_stack, 1) end
    end
    self.dirty = true
end

function Store:add(page, stroke)
    if not positiveInteger(page) then return nil, "Invalid page number" end
    local ok, err = validateStroke(stroke)
    if not ok then return nil, err end
    if not self.pages[page] then self.pages[page] = {} end
    local strokes = self.pages[page]
    local copy = cloneStroke(stroke)
    strokes[#strokes + 1] = copy
    self:_record({ action = "remove", page = page, index = #strokes })
    return true
end

function Store:erase(page, a, b, radius)
    if not positiveInteger(page) or not finite(radius) or radius < 0
        or not a or not b or not finite(a.x) or not finite(a.y)
        or not finite(b.x) or not finite(b.y) then return nil, "Invalid eraser geometry" end
    local strokes = self.pages[page]
    if not strokes then return 0 end
    local changed, affected, local_group = 0, nil, not self.undo_group
    if local_group then self:beginUndo() end
    -- Replace in reverse order. Undo reverses the replacements again, restoring
    -- exact original paths and paint ordering across an entire eraser gesture.
    for i = #strokes, 1, -1 do
        local fragments, cut_bounds = Geometry.eraseStroke(strokes[i], a, b, radius)
        if fragments then
            local removed = table.remove(strokes, i)
            -- Only the erased segment needs immediate recomposition. Previously
            -- we repainted the entire original path, even for a tiny cut.
            local bounds = cut_bounds or Geometry.bounds(removed)
            for fragment = #fragments, 1, -1 do
                table.insert(strokes, i, fragments[fragment])
            end
            if affected then
                local right = math.max(affected.x + affected.w, bounds.x + bounds.w)
                local bottom = math.max(affected.y + affected.h, bounds.y + bounds.h)
                affected.x, affected.y = math.min(affected.x, bounds.x), math.min(affected.y, bounds.y)
                affected.w, affected.h = right - affected.x, bottom - affected.y
            else
                affected = bounds
            end
            self:_record({ action = "replace", page = page, index = i,
                stroke = removed, count = #fragments })
            changed = changed + 1
        end
    end
    if local_group then self:endUndo() end
    -- Allow the caller to refresh only the edited portion of long paths;
    -- it adds raster padding and recomposes surviving ink from the sidecar.
    return changed, affected
end

-- One replacement and one grouped undo operation per original stroke,
-- regardless of how many eraser samples crossed it.
function Store:erasePath(page,path,radius)
    if not positiveInteger(page) or not finite(radius) or radius<0
        or type(path)~="table" then return nil,"Invalid eraser path" end
    local strokes=self.pages[page]
    if not strokes or #path==0 then return 0 end
    local changed,affected,local_group=0,nil,not self.undo_group
    if local_group then self:beginUndo() end
    for i=#strokes,1,-1 do
        local fragments,bounds=Geometry.eraseStrokePath(strokes[i],path,radius)
        if fragments then
            local removed=table.remove(strokes,i)
            for j=#fragments,1,-1 do table.insert(strokes,i,fragments[j]) end
            self:_record({action="replace",page=page,index=i,
                stroke=removed,count=#fragments})
            affected=affected and {x=math.min(affected.x,bounds.x),
                y=math.min(affected.y,bounds.y),
                w=math.max(affected.x+affected.w,bounds.x+bounds.w)-math.min(affected.x,bounds.x),
                h=math.max(affected.y+affected.h,bounds.y+bounds.h)-math.min(affected.y,bounds.y)} or bounds
            changed=changed+1
        end
    end
    if local_group then self:endUndo() end
    return changed,affected
end

function Store:undo()
    self:endUndo()
    local group = table.remove(self.undo_stack)
    if not group then return false end
    for i = #group, 1, -1 do
        local operation = group[i]
        local strokes = self.pages[operation.page]
        if operation.action == "remove" then
            table.remove(strokes, operation.index)
        elseif operation.action == "replace" then
            for _ = 1, operation.count do table.remove(strokes, operation.index) end
            table.insert(strokes, operation.index, operation.stroke)
        else
            table.insert(strokes, operation.index, operation.stroke)
        end
    end
    self.dirty = true
    return true
end

function Store:hasInk()
    for _, strokes in pairs(self.pages) do if #strokes > 0 then return true end end
    return false
end

function Store:exportPages()
    local pages = {}
    for page, strokes in pairs(self.pages) do
        if #strokes > 0 then
            pages[page] = {}
            for i, stroke in ipairs(strokes) do pages[page][i] = cloneStroke(stroke) end
        end
    end
    return pages
end

-- Re-read every source byte before a trusted KOReader PDF writer runs. The
-- size/mtime cache used for ordinary stroke saves does not establish trust.
function Store:sourceMatches()
    self.trusted_write_ready = nil
    local source, attributes = fingerprint(self.pdf_path)
    if not source then return nil, attributes end
    if source.size ~= self.source.size or source.md5 ~= self.source.md5 then
        return nil, "Source PDF changed outside Scribe Ink; preserve the matching original PDF and sidecar"
    end
    self.source_attributes = attributes
    self.trusted_write_ready = true
    return true
end

-- ONLY the original KOReader writer, after sourceMatches() succeeded and
-- after that writer completed successfully, may call this method. This is
-- not a way to adopt arbitrary external PDF edits: ink coordinates could
-- otherwise attach to unrelated/reordered/resized pages.
function Store:adoptSourceWrite()
    if not self.trusted_write_ready then
        return nil, "A trusted PDF write requires a successful source identity check first"
    end
    self.trusted_write_ready = nil
    local source, attributes = fingerprint(self.pdf_path)
    if not source then return nil, attributes end
    -- Preserve the preceding saved ink as a usable backup against the new
    -- trusted PDF revision. Do not alter disk_bytes used for conflict checks.
    local backup_bytes
    if self.original_bytes then
        local decoded, document, decode_error = pcall(JSON.decode, self.original_bytes)
        if not decoded or not document then return nil, tostring(decode_error or document) end
        document.source = source
        local encoded, bytes, encode_error = pcall(JSON.encode, document, { pretty = true })
        if not encoded or not bytes then return nil, tostring(encode_error or bytes) end
        backup_bytes = bytes
    end
    self.source, self.source_attributes = source, attributes
    self.trusted_backup_bytes = backup_bytes
    self.dirty = true
    return true
end

function Store:save()
    if not self.dirty then return true end
    local attributes = lfs.attributes(self.pdf_path)
    if not attributes or attributes.size ~= self.source_attributes.size
        or attributes.modification ~= self.source_attributes.modification then
        return nil, "Source PDF changed; ink remains in memory. Restore the original PDF before saving"
    end
    local pages = JSON.object({})
    for page, strokes in pairs(self.pages) do
        if #strokes > 0 then
            local copies = JSON.array({})
            for i, stroke in ipairs(strokes) do
                local copy = cloneStroke(stroke)
                copy.points = JSON.array(copy.points)
                copies[i] = copy
            end
            pages[tostring(page)] = copies
        end
    end
    local called, bytes, encode_error = pcall(JSON.encode, {
        format = "koreader-scribe-ink", version = 1,
        coordinate_space = "mupdf-page", source = self.source, pages = pages,
    }, { pretty = true })
    if not called or not bytes then return nil, tostring(encode_error or bytes) end

    -- Reject a concurrently changed sidecar instead of silently overwriting it.
    local installed = lfs.attributes(self.path)
    if installed then
        local current, err = readFile(self.path)
        if not current then return nil, err end
        if current ~= self.disk_bytes then
            return nil, "Ink sidecar changed outside this session; ink remains in memory"
        end
    elseif self.disk_bytes then
        return nil, "Ink sidecar was removed outside this session; ink remains in memory"
    end

    local temporary = self.path .. ".tmp"
    local written, write_error = durableWrite(temporary, bytes)
    if not written then return nil, "Cannot save ink temporary file: " .. tostring(write_error) end
    -- Keep the last known-good version. Recovery must not back up malformed
    -- primary bytes over the good recovery file.
    if self.original_bytes and (not self.recovered or self.trusted_backup_bytes) then
        local backup_tmp = self.path .. ".bak.tmp"
        local backed, backup_error = durableWrite(backup_tmp, self.trusted_backup_bytes or self.original_bytes)
        if not backed then return nil, "Cannot save ink backup: " .. tostring(backup_error) end
        local renamed, rename_error = os.rename(backup_tmp, self.path .. ".bak")
        if not renamed then return nil, "Cannot install ink backup: " .. tostring(rename_error) end
        local synced, sync_error = ffiUtil.fsyncDirectory(self.path .. ".bak")
        if not synced then return nil, "Cannot sync ink backup: " .. tostring(sync_error) end
    end
    local renamed, rename_error = os.rename(temporary, self.path)
    if not renamed then return nil, "Cannot install ink sidecar: " .. tostring(rename_error) end
    -- If the final directory sync fails, the bytes may already be installed.
    -- Retain dirty state for retry while tracking them for conflict checking.
    self.original_bytes, self.disk_bytes, self.recovered = bytes, bytes, false
    self.trusted_backup_bytes = nil
    local synced, sync_error = ffiUtil.fsyncDirectory(self.path)
    if not synced then return nil, "Ink written but directory sync failed: " .. tostring(sync_error) end
    self.dirty = false
    return true
end

return Store
