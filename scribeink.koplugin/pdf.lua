-- Scribe Ink PDF export. Always reopen the original and write an annotated copy.
-- No direct calls into MuPDF: throwing C APIs cannot safely cross LuaJIT FFI.
local Pdf = {}

local UNSUPPORTED = "This KOReader build cannot export PDF ink. Update to KOReader 2026.07 or newer, or use tools/export_pdf.py on a computer. Your saved handwriting is retained."

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function close(object)
    if object and object.close then pcall(object.close, object) end
end

local function open(source, options)
    local ok, mupdf = pcall(require, "ffi/mupdf")
    if not ok then return nil, "MuPDF is unavailable: " .. tostring(mupdf) end
    local document
    ok, document = pcall(mupdf.openDocument, source)
    if not ok then return nil, tostring(document) end
    local success, err = pcall(function()
        if document:needsPassword() then
            if not options or not options.password then
                error("Password-protected PDF export requires a password; use the computer exporter with --password.", 0)
            end
            if not document:authenticatePassword(options.password) then
                error("The PDF password is incorrect.", 0)
            end
        end
    end)
    if not success then close(document); return nil, tostring(err) end
    return document
end

-- Accepts either KOReader's PdfDocument or its underlying MuPDF document.
function Pdf.supported(document)
    document = document and (document._document or document)
    if not document or type(document.openPage) ~= "function" then
        return nil, "Open a PDF before exporting handwriting."
    end
    local ok, page = pcall(document.openPage, document, 1)
    if not ok then return nil, tostring(page) end
    local supported = type(page.addInkAnnotation) == "function"
    close(page)
    if not supported then return nil, UNSUPPORTED end
    return true
end

function Pdf.probe(source, options)
    local document, err = open(source, options)
    if not document then return nil, err end
    local ok
    ok, err = Pdf.supported(document)
    close(document)
    return ok, err
end

local function validatePages(pages, count)
    if type(pages) ~= "table" then error("Invalid handwriting page list.", 0) end
    local sorted, seen = {}, {}
    for key, strokes in pairs(pages) do
        local number = tonumber(key)
        if not finite(number) or number % 1 ~= 0 or number < 1 or number > count or seen[number] then
            error("Invalid handwriting page number: " .. tostring(key), 0)
        end
        seen[number] = true
        if type(strokes) ~= "table" then error("Invalid strokes on page " .. number, 0) end
        local validated = {}
        for _, stroke in ipairs(strokes) do
            if type(stroke) ~= "table" or type(stroke.points) ~= "table" or #stroke.points == 0 then
                error("Invalid handwriting stroke on page " .. number, 0)
            end
            local width = stroke.width or 1
            if not finite(width) or width <= 0 or width > 1000 then error("Invalid ink width.", 0) end
            local points = {}
            for _, point in ipairs(stroke.points) do
                if type(point) ~= "table" or not finite(point.x) or not finite(point.y)
                    or math.abs(point.x) > 10000000 or math.abs(point.y) > 10000000 then
                    error("Invalid ink coordinates.", 0)
                end
                points[#points + 1] = { x = point.x, y = point.y }
            end
            -- Two virtually coincident vertices make pen taps visible across PDF viewers.
            if #points == 1 then points[2] = { x = points[1].x + 0.01, y = points[1].y } end
            validated[#validated + 1] = { points = points, width = width }
        end
        sorted[#sorted + 1] = { number = number, strokes = validated }
    end
    table.sort(sorted, function(a, b) return a.number < b.number end)
    return sorted
end

-- pages: { [page_number] = { { points = { {x=, y=}... }, width = PDF_points }... } }
-- Coordinates are MuPDF native page coordinates, including the PDF's intrinsic rotation.
-- Erasing removes sidecar strokes; rebuilding the copy preserves all original annotations.
function Pdf.export(source, target, pages, options)
    options = options or {}
    if type(source) ~= "string" or type(target) ~= "string" or target == "" then
        return nil, "Choose an original PDF and a different output filename."
    end
    local lfs = require("libs/libkoreader-lfs")
    local ffiUtil = require("ffi/util")
    local source_real = ffiUtil.realpath(source) or source
    local target_real = ffiUtil.realpath(target)
    if not target_real then
        local directory, name = target:match("^(.*)/([^/]+)$")
        target_real = (directory and ffiUtil.realpath(directory) or nil)
        target_real = target_real and (target_real .. "/" .. name) or target
    end
    local source_attr, target_attr = lfs.attributes(source), lfs.attributes(target)
    local same_inode = source_attr and target_attr and source_attr.ino and source_attr.ino ~= 0
        and source_attr.ino == target_attr.ino and source_attr.dev == target_attr.dev
    if source_real == target_real or same_inode then return nil, "The original PDF cannot be overwritten." end
    if target_attr and not options.overwrite then return nil, "The output file already exists." end
    if target_attr and target_attr.mode ~= "file" then return nil, "The output path is not a regular file." end

    local document, err = open(source, options)
    if not document then return nil, err end
    local page, temporary
    local success, result = pcall(function()
        local supported, reason = Pdf.supported(document)
        if not supported then error(reason, 0) end
        local sorted = validatePages(pages, document:getPages())
        for _, item in ipairs(sorted) do
            if #item.strokes > 0 then
                page = document:openPage(item.number)
                for _, stroke in ipairs(item.strokes) do
                    page:addInkAnnotation({ stroke.points }, { r = 0, g = 0, b = 0 }, stroke.width, 1)
                end
                close(page)
                page = nil
            end
        end
        for attempt = 1, 100 do
            local candidate = target .. ".scribeink-tmp-" .. tostring(os.time()) .. "-" .. attempt
            if not lfs.attributes(candidate) then temporary = candidate; break end
        end
        if not temporary then error("Cannot allocate a temporary export file.", 0) end
        document:writeDocument(temporary)
        close(document)
        document = nil
        local file = io.open(temporary, "r+b")
        if file then
            if ffiUtil.fsyncOpenedFile then pcall(ffiUtil.fsyncOpenedFile, file) end
            file:close()
        end
        -- Same-directory rename is atomic on Kindle. Existing export remains on failure.
        local renamed, rename_error = os.rename(temporary, target)
        if not renamed then error("Cannot finish PDF export: " .. tostring(rename_error), 0) end
        temporary = nil
        if ffiUtil.fsyncDirectory then pcall(ffiUtil.fsyncDirectory, target) end
    end)
    close(page)
    close(document)
    if temporary then os.remove(temporary) end
    if not success then return nil, tostring(result) end
    return true
end

return Pdf
