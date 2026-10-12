-- Run with tests/run_tests.py (real JSON and MD5 bridges) or provide those
-- three globals in another Lua 5.1/LuaJIT harness. Device dependencies and
-- filesystem failures are modelled here; the production modules are unchanged.
assert(__json_encode and __json_decode and __md5, "JSON/MD5 test bridges are required")
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") .. "../scribeink.koplugin/"
local Geometry = dofile(root .. "geometry.lua")
local checks = 0
local function check(condition, label)
    checks = checks + 1
    assert(condition, label)
end
local function near(a, b) return math.abs(a - b) < 1e-8 end

-- Independent geometry cases: crossing segments, degenerate taps, collinear
-- overlap, stroke thickness and an eraser sweeping across missed samples.
check(Geometry.segmentDistance2(0, 0, 10, 10, 0, 10, 10, 0) == 0, "diagonals cross")
check(Geometry.segmentDistance2(0, 0, 10, 0, 5, 0, 15, 0) == 0, "collinear overlap")
check(Geometry.segmentDistance2(0, 0, 0, 0, 3, 4, 3, 4) == 25, "point segments")
check(Geometry.segmentDistance2(0, 0, 10, 0, 0, 3, 10, 3) == 9, "parallel separation")
local thin = { width = 2, points = { { x = 5, y = -10 }, { x = 5, y = 10 } } }
check(Geometry.strokeHit(thin, { x = -5, y = 0 }, { x = 20, y = 0 }, 0), "fast eraser crosses stroke")
local dot = { width = 4, points = { { x = 5, y = 5 } } }
check(Geometry.strokeHit(dot, { x = 8, y = 5 }, { x = 8, y = 5 }, 1), "ink width counts at contact")
check(not Geometry.strokeHit(dot, { x = 8.01, y = 5 }, { x = 8.01, y = 5 }, 1), "outside eraser capsule")
local clip = { x = 10, y = 20, w = 30, h = 40 }
local a, b = Geometry.clipSegment({ x = 0, y = 40 }, { x = 50, y = 40 }, clip)
check(a.x == 10 and b.x == 40 and a.y == 40, "clip crossing line")
check(not Geometry.clipSegment({ x = 0, y = 0 }, { x = 50, y = 0 }, clip), "clip excludes outside")
a, b = Geometry.clipSegment({ x = 10, y = 20 }, { x = 10, y = 20 }, clip)
check(a.x == 10 and b.y == 20, "clip retains a dot on boundary")
local transform = { zoom = 2.5, visible = { x = 200, y = 75 }, offset = { x = 40, y = 130 } }
local screen = Geometry.pageToScreen({ x = 100, y = 20 }, transform)
check(screen.x == 90 and screen.y == 105, "pan and margins in zoomed pixel transform")
local restored = Geometry.screenToPage(screen, transform)
check(near(restored.x, 100) and near(restored.y, 20), "inverse screen transform")

-- Partial erasing interpolates sparse segments instead of discarding the
-- entire pen gesture. Round caps of the surviving paths stay outside rubber.
local long = { width = 2, points = { { x = 0, y = 0 }, { x = 100, y = 0 } } }
local fragments, cut_bounds = Geometry.eraseStroke(long, { x = 50, y = 0 }, { x = 50, y = 0 }, 10)
check(#fragments == 2 and fragments[1].width == 2 and fragments[2].width == 2,
    "middle erasure splits a sparse line into two ordinary strokes")
check(fragments[1].points[1].x == 0 and near(fragments[1].points[2].x, 39)
    and near(fragments[2].points[1].x, 61) and fragments[2].points[2].x == 100,
    "cut endpoints include ink radius so new caps cannot repaint the erased gap")
check(cut_bounds.x == 38 and cut_bounds.w == 24 and cut_bounds.y == -1 and cut_bounds.h == 2,
    "partial erasure returns only the changed region with ink thickness")
check(#long.points == 2 and long.points[1].x == 0 and long.points[2].x == 100,
    "geometry preserves the original path for exact undo")
check(not Geometry.eraseStroke(fragments[1], { x = 50, y = 0 }, { x = 50, y = 0 }, 10)
    and not Geometry.eraseStroke(fragments[2], { x = 50, y = 0 }, { x = 50, y = 0 }, 10),
    "holding a stationary eraser does not repeatedly split its existing boundaries")
local diagonal = { width = 2, points = { { x = 0, y = 0 }, { x = 100, y = 100 } } }
fragments = Geometry.eraseStroke(diagonal, { x = 50, y = 50 }, { x = 50, y = 50 }, 5)
check(#fragments == 2 and near(fragments[1].points[2].x, 50 - 6 / math.sqrt(2))
    and near(fragments[2].points[1].y, 50 + 6 / math.sqrt(2)),
    "diagonal intersection is interpolated in page coordinates")
fragments = Geometry.eraseStroke(long, { x = 30, y = 0 }, { x = 70, y = 0 }, 5)
check(#fragments == 2 and near(fragments[1].points[2].x, 24)
    and near(fragments[2].points[1].x, 76), "collinear sweep cuts its rectangle and both round ends")
fragments = Geometry.eraseStroke(long, { x = 30, y = -50 }, { x = 70, y = 50 }, 5)
check(#fragments == 2 and near(fragments[1].points[2].x, 50 - 6 * math.sqrt(11600) / 100)
    and near(fragments[2].points[1].x, 50 + 6 * math.sqrt(11600) / 100),
    "fast oblique motion clips the complete swept capsule between samples")
fragments = Geometry.eraseStroke(long, { x = 0, y = 0 }, { x = 100, y = 0 }, 1)
check(#fragments == 0, "a sweep covering the whole path removes it")
check(not Geometry.eraseStroke(long, { x = 50, y = 30 }, { x = 50, y = 40 }, 2),
    "distant capsule leaves ink untouched")
check(#Geometry.eraseStroke(dot, { x = 8, y = 5 }, { x = 8, y = 5 }, 1) == 0,
    "a touched dot is removed including its width")
check(not Geometry.eraseStroke(dot, { x = 8.01, y = 5 }, { x = 8.01, y = 5 }, 1),
    "a dot outside the rubber is preserved")
local loop = { width = 2, points = {
    { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 20 },
    { x = 0, y = 20 }, { x = 0, y = 40 }, { x = 100, y = 40 } } }
fragments = Geometry.eraseStroke(loop, { x = 50, y = -10 }, { x = 50, y = 50 }, 5)
check(#fragments == 4 and #fragments[2].points == 4 and #fragments[3].points == 4,
    "one sweep cuts every crossing while preserving the turns between crossings")
check(fragments[1].points[1].x == 0 and fragments[4].points[2].x == 100
    and fragments[2].points[2].x == 100 and fragments[3].points[2].x == 0,
    "multiple fragments retain pen direction and path ordering")
local duplicate = { width = 2, points = { { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 100, y = 0 } } }
fragments = Geometry.eraseStroke(duplicate, { x = 0, y = 0 }, { x = 0, y = 0 }, 5)
check(#fragments == 1 and #fragments[1].points == 2 and near(fragments[1].points[1].x, 6),
    "duplicate pen samples cannot reconnect an erased endpoint")
local vertex = { width = 2, points = { { x = 0, y = 0 }, { x = 50, y = 0 }, { x = 100, y = 0 } } }
fragments = Geometry.eraseStroke(vertex, { x = 50, y = 0 }, { x = 50, y = 0 }, 5)
check(#fragments == 2 and near(fragments[1].points[2].x, 44)
    and near(fragments[2].points[1].x, 56), "a cut across an original vertex never bridges its gap")
local tiny = { width = 2, points = { { x = 5, y = 5 }, { x = 5 + 1e-10, y = 5 } } }
check(#Geometry.eraseStroke(tiny, { x = 5, y = 5 }, { x = 5, y = 5 }, 1) == 0,
    "an almost stationary stroke erases as a dot instead of surviving numerical filtering")

-- Compare against densely sampled point-to-capsule distances, independently
-- of the clipping formulas, for taps and sweeps in many directions.
math.randomseed(20261012)
for case = 1, 60 do
    local function randomPoint() return { x = math.random(-100, 100), y = math.random(-100, 100) } end
    local p, q, eraser_a, eraser_b = randomPoint(), randomPoint(), randomPoint(), randomPoint()
    if case % 3 == 0 then eraser_b = eraser_a end
    local width, radius = math.random(1, 8), math.random(1, 20)
    local path = { width = width, points = { p, q } }
    local pieces = Geometry.eraseStroke(path, eraser_a, eraser_b, radius) or { path }
    local reach = radius + width / 2
    local caps_clear = true
    for _, piece in ipairs(pieces) do
        for i = 2, #piece.points do
            local v, w = piece.points[i - 1], piece.points[i]
            if Geometry.segmentDistance2(v.x, v.y, w.x, w.y,
                    eraser_a.x, eraser_a.y, eraser_b.x, eraser_b.y) < reach * reach - 1e-7 then
                caps_clear = false
            end
        end
    end
    check(caps_clear, "surviving caps lie outside random eraser footprint " .. case)
    local classified = true
    for sample = 0, 100 do
        local t = sample / 100
        local x, y = p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t
        local distance2 = Geometry.segmentDistance2(x, y, x, y,
            eraser_a.x, eraser_a.y, eraser_b.x, eraser_b.y)
        if math.abs(distance2 - reach * reach) > 1e-7 then
            local present = false
            for _, piece in ipairs(pieces) do
                for i = 2, #piece.points do
                    local v, w = piece.points[i - 1], piece.points[i]
                    if Geometry.segmentDistance2(x, y, x, y, v.x, v.y, w.x, w.y) < 1e-12 then present = true end
                end
            end
            if present ~= (distance2 > reach * reach) then classified = false end
        end
    end
    check(classified, "random clipping preserves exactly the uncovered centerline " .. case)
end

local files, events, faults = {}, {}, {}
local original_open, original_rename = io.open, os.rename
local module_names = { "rapidjson", "libs/libkoreader-lfs", "ffi/util", "ffi/sha2" }
local original_loaded, original_preload = {}, {}
for _, name in ipairs(module_names) do
    original_loaded[name], original_preload[name] = package.loaded[name], package.preload[name]
    package.loaded[name] = nil
end
local function put(path, bytes, mtime)
    files[path] = { bytes = bytes, modification = mtime or 100 }
end
package.preload["rapidjson"] = function()
    return {
        encode = __json_encode, decode = __json_decode,
        array = function(t) return setmetatable(t or {}, { __json_type = "array" }) end,
        object = function(t) return setmetatable(t or {}, { __json_type = "object" }) end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path)
        local entry = files[path]
        if not entry then return nil, "No such file" end
        return { mode = "file", size = #entry.bytes, modification = entry.modification }
    end }
end
package.preload["ffi/sha2"] = function()
    return { md5 = function()
        local chunks = {}
        return function(chunk)
            if chunk then chunks[#chunks + 1] = chunk else return __md5(table.concat(chunks)) end
        end
    end }
end
package.preload["ffi/util"] = function()
    return {
        fsyncOpenedFile = function(file)
            events[#events + 1] = { "sync-file", file.path }
            if faults.sync_file then return false, "Simulated full disk" end
            return true
        end,
        fsyncDirectory = function(path)
            events[#events + 1] = { "sync-directory", path }
            if faults.sync_directory == true or faults.sync_directory == path then
                return false, "Simulated directory sync failure"
            end
            return true
        end,
    }
end
io.open = function(path, mode)
    if faults.open == path then return nil, "Simulated permission error" end
    if mode == "wb" then put(path, "") end
    if not files[path] then return nil, "No such file" end
    local file = { path = path, cursor = 1 }
    function file:read(amount)
        if self.cursor > #files[path].bytes then
            if amount == "*all" then return "" else return nil end
        end
        local last = amount == "*all" and #files[path].bytes or self.cursor + amount - 1
        local bytes = files[path].bytes:sub(self.cursor, last)
        self.cursor = self.cursor + #bytes
        return bytes
    end
    function file:write(bytes)
        if faults.write then return nil, "Simulated write failure" end
        files[path].bytes = files[path].bytes .. bytes
        events[#events + 1] = { "write", path }
        return self
    end
    function file:flush() return true end
    function file:close() return true end
    return file
end
os.rename = function(from, to)
    events[#events + 1] = { "rename", from, to }
    if faults.rename == to then return nil, "Simulated rename failure" end
    if not files[from] then return nil, "No such file" end
    files[to], files[from] = files[from], nil
    return true
end

local Store = dofile(root .. "store.lua")
local source, sidecar = "/books/drawing.pdf", "/books/drawing.pdf.scribeink.json"
put(source, "%PDF-1.7 mock source\n")
local original_pdf = files[source].bytes
local store, err = Store.open(source)
check(store and not err and not store:hasInk(), "new PDF creates empty memory model")
local first = { width = 1.25, points = { { x = 10, y = 10 }, { x = 30, y = 10 } } }
local second = { width = 2, points = { { x = 10, y = 50 }, { x = 30, y = 50 } } }
check(store:add(1, first), "add first stroke")
first.points[1].x = 999
check(store:page(1)[1].points[1].x == 10, "model owns added point copies")
check(store:add(1, second) and store:add(2, dot), "multiple pages")
check(store:save(), "durable first save")
local last_write, last_sync, install
for index, event in ipairs(events) do
    if event[1] == "write" and event[2] == sidecar .. ".tmp" then last_write = index end
    if event[1] == "sync-file" and event[2] == sidecar .. ".tmp" then last_sync = index end
    if event[1] == "rename" and event[3] == sidecar then install = index end
end
check(last_write < last_sync and last_sync < install
    and events[install + 1][1] == "sync-directory", "durable bytes precede atomic install and directory sync")
local decoded = __json_decode(files[sidecar].bytes)
check(decoded.format == "koreader-scribe-ink" and decoded.version == 1
    and decoded.coordinate_space == "mupdf-page", "interoperable sidecar schema")
check(decoded.pages["1"][1].width == 1.25 and decoded.pages["2"][1].points[1].y == 5,
    "page map and unscaled coordinates survive real JSON")
check(decoded.source.md5 == __md5(original_pdf) and decoded.source.size == #original_pdf,
    "source identity hashes entire source PDF")
check(files[source].bytes == original_pdf, "all saves preserve original PDF")
local reloaded = assert(Store.open(source))
check(#reloaded:page(1) == 2 and #reloaded:page(2) == 1, "saved pages reopen")
check(not reloaded:undo(), "undo starts fresh on reopen")
local exported = reloaded:exportPages()
exported[1][1].points[1].x = 500
check(reloaded:page(1)[1].points[1].x == 10, "export snapshot cannot modify active ink")
local erased_count, erased_bounds = reloaded:erase(1, { x = 20, y = 30 }, { x = 20, y = 30 }, 25)
check(erased_count == 2 and near(erased_bounds.x, 9) and near(erased_bounds.y, 9.375)
    and near(erased_bounds.w, 22) and near(erased_bounds.h, 41.625),
    "eraser refresh bounds cover complete removed strokes including their thickness")
check(reloaded:undo() and #reloaded:page(1) == 2, "bounds computation preserves eraser undo")
erased_count, erased_bounds = reloaded:erase(1, { x = -10, y = -10 }, { x = -5, y = -5 }, 0)
check(erased_count == 0 and erased_bounds == nil, "empty eraser sweep needs no repaint region")
reloaded:add(9, { width = 2, points = { { x = 0, y = 100 }, { x = 600, y = 100 } } })
erased_count, erased_bounds = reloaded:erase(9, { x = 0, y = 100 }, { x = 0, y = 100 }, 1)
check(erased_count == 1 and erased_bounds.x == -1 and erased_bounds.y == 99
    and erased_bounds.w == 602 and erased_bounds.h == 2
    and #reloaded:page(9) == 1 and near(reloaded:page(9)[1].points[1].x, 2)
    and reloaded:page(9)[1].points[2].x == 600,
    "tiny endpoint contact preserves most ink while refreshing the complete rasterized original extent")

store:beginUndo()
check(store:erase(1, { x = 20, y = 0 }, { x = 20, y = 20 }, 1) == 1, "erase first stroke")
check(store:erase(1, { x = 20, y = 40 }, { x = 20, y = 60 }, 1) == 1, "erase second sample")
store:endUndo()
check(#store:page(1) == 4 and store:undo() and #store:page(1) == 2, "one undo restores entire partial-erasure gesture")
check(store:page(1)[1].width == 1.25 and store:page(1)[2].width == 2, "undo preserves paint order")
check(store:page(1)[1].points[1].x == 10 and store:page(1)[1].points[2].x == 30
    and store:page(1)[2].points[1].y == 50 and store:page(1)[2].points[2].x == 30,
    "partial-erasure undo restores the exact original endpoints")
check(store:erase(1, { x = -10, y = -10 }, { x = -5, y = -5 }, 0) == 0, "erase no contact")
check(store:undo() and #store:page(2) == 0, "empty eraser sweep does not consume undo")
check(store:save(), "save after undo")
check(files[sidecar .. ".bak"] and #__json_decode(files[sidecar .. ".bak"].bytes).pages["2"] == 1,
    "backup contains preceding valid saved version")

-- Splitting existing fragments repeatedly in one gesture must undo by exact
-- original stroke order, rather than retaining any intermediate cut endpoints.
local partial_source = "/books/partial.pdf"
put(partial_source, "%PDF-1.7 original text and highlights\n")
local partial = assert(Store.open(partial_source))
local before_ink = { width = 3, points = { { x = 0, y = -30 } } }
local after_ink = { width = 4, points = { { x = 100, y = 60 } } }
partial:add(1, before_ink); partial:add(1, loop); partial:add(1, after_ink)
partial:add(2, long)
local original_loop, untouched_first, untouched_last = partial:page(1)[2], partial:page(1)[1], partial:page(1)[3]
check(partial:save(), "save original ink before partial erasing")
partial:beginUndo()
check(partial:erase(1, { x = 50, y = -10 }, { x = 50, y = 50 }, 5) == 1
    and #partial:page(1) == 6, "one crossed original stroke becomes four fragments between untouched ink")
check(partial:page(1)[1] == untouched_first and partial:page(1)[6] == untouched_last,
    "partial erase preserves untouched strokes in their paint positions")
check(partial:erase(1, { x = 80, y = -10 }, { x = 80, y = 50 }, 5) == 2
    and #partial:page(1) == 9, "later sweep can split multiple survivors of the same original stroke")
check(partial:erase(2, { x = 50, y = 0 }, { x = 50, y = 0 }, 10) == 1,
    "an eraser undo group can also include another page")
partial:endUndo()
local fragment_snapshot = partial:exportPages()
check(#fragment_snapshot[1] == 9 and #fragment_snapshot[2] == 2
    and fragment_snapshot[2][1].points[2].x == 39 and fragment_snapshot[2][2].points[1].x == 61,
    "export receives separate paths with the erased gaps and original widths")
fragment_snapshot[2][1].points[2].x = 999
check(partial:page(2)[1].points[2].x == 39, "exported partial fragments cannot modify live notes")
check(partial:save(), "partially erased notes save durably")
local partial_json = __json_decode(files[partial.path].bytes)
check(partial_json.version == 1 and #partial_json.pages["1"] == 9
    and #partial_json.pages["2"] == 2 and partial_json.pages["2"][1].width == 2,
    "partial erasing stays interoperable with the original stroke-only JSON format")
local reopened_partial = assert(Store.open(partial_source))
check(#reopened_partial:page(1) == 9 and #reopened_partial:page(2) == 2
    and reopened_partial:page(2)[1].points[2].x == 39
    and reopened_partial:page(2)[2].points[1].x == 61,
    "reopening preserves the erased gap without reconnecting split fragments")
check(files[partial_source].bytes == "%PDF-1.7 original text and highlights\n",
    "partial erasing never changes PDF text or existing highlights")
check(partial:undo() and #partial:page(1) == 3 and #partial:page(2) == 1
    and partial:page(1)[2] == original_loop and partial:page(1)[1] == untouched_first
    and partial:page(1)[3] == untouched_last,
    "one undo restores exact original stroke objects and ordering across all cuts")
check(#partial:page(1)[2].points == 6 and partial:page(2)[1].points[1].x == 0
    and partial:page(2)[1].points[2].x == 100,
    "whole-gesture undo discards every interpolated boundary")
check(partial:save() and #assert(Store.open(partial_source)):page(1) == 3,
    "undo of partial erasing persists correctly after reopen")
partial:beginUndo()
check(partial:erase(1, { x = 500, y = 500 }, { x = 600, y = 600 }, 5) == 0,
    "unaffected bounding boxes need no clipping changes")
partial:endUndo()
check(partial:undo() and #partial:page(2) == 0,
    "empty grouped eraser gesture adds no undo item")

local good_bytes = files[sidecar].bytes
store:add(3, dot)
faults.write = true
local saved, save_error = store:save()
check(not saved and save_error and store.dirty and #store:page(3) == 1,
    "write failure retains unsaved in-memory ink")
check(files[sidecar].bytes == good_bytes, "write failure cannot truncate installed sidecar")
faults.write = nil
faults.sync_file = true
saved = store:save()
check(not saved and files[sidecar].bytes == good_bytes, "fsync failure does not install unsafe bytes")
faults.sync_file = nil
faults.rename = sidecar
saved = store:save()
check(not saved and files[sidecar].bytes == good_bytes and store.dirty,
    "rename failure leaves prior save usable")
faults.rename = nil
faults.sync_directory = sidecar
saved = store:save()
check(not saved and store.dirty, "directory sync failure stays retryable")
faults.sync_directory = nil
check(store:save() and not store.dirty, "retry saves retained ink")

local conflict = assert(Store.open(source))
conflict:add(4, dot)
files[sidecar].bytes = files[sidecar].bytes .. "\n"
saved, save_error = conflict:save()
check(not saved and save_error:find("outside this session", 1, true), "external sidecar edits fail closed")
-- Recover the backup explicitly with a warning; preserve ink and the backup.
files[sidecar].bytes = "{ malformed JSON"
local recovered, warning = Store.open(source)
check(recovered and warning and recovered.dirty and recovered:hasInk(), "corrupt primary recovers validated backup with warning")
local backup_bytes = files[sidecar .. ".bak"].bytes
check(recovered:save() and files[sidecar .. ".bak"].bytes == backup_bytes,
    "recovery save preserves good backup")
files[sidecar] = nil
recovered, warning = Store.open(source)
check(recovered and warning and recovered:hasInk(), "missing primary recovers backup")
check(recovered:save(), "missing-primary recovery can save")

local supported_bytes = files[sidecar].bytes
local future = __json_decode(supported_bytes)
future.version = 2
files[sidecar].bytes = __json_encode(future)
local future_store, future_error = Store.open(source)
check(not future_store and future_error:find("Unsupported", 1, true),
    "future schema never falls back to older backup and overwrites newer ink")
local different = __json_decode(supported_bytes)
different.source.md5 = "00000000000000000000000000000000"
files[sidecar].bytes = __json_encode(different)
local different_store, different_error = Store.open(source)
check(not different_store and different_error:find("different PDF", 1, true),
    "source mismatch fails closed even when a matching older backup exists")
files[sidecar].bytes = supported_bytes

local same_length = original_pdf:gsub("source", "SOURCE")
put(source, same_length, 100) -- same byte length and mtime; full hash still differs
local mismatch, mismatch_error = Store.open(source)
check(not mismatch and mismatch_error:find("different PDF", 1, true),
    "same-size different PDF cannot silently inherit another document's ink")
put(source, original_pdf, 101)
local changed = assert(Store.open(source))
changed:add(5, dot)
files[source].modification = 102
saved, save_error = changed:save()
check(not saved and changed.dirty and save_error:find("Source PDF changed", 1, true),
    "source changes during session block save without losing ink")
local malformed = __json_decode(files[sidecar].bytes)
malformed.pages["1"][1].points[1].x = "bad"
files[sidecar].bytes = __json_encode(malformed)
files[sidecar .. ".bak"] = nil
local rejected = Store.open(source)
check(not rejected, "invalid coordinate data cannot load or silently reset")
check(not changed:add(1, { width = 0, points = { { x = 0, y = 0 } } }), "zero-width stroke rejected")
check(not changed:add(0, dot), "invalid page rejected")

-- KOReader's own confirmed annotation writer may change the source bytes;
-- rebinding is allowed only after verifying the exact old source first.
files, events, faults = {}, {}, {}
put(source, original_pdf)
local trusted = assert(Store.open(source))
trusted:add(1, second)
check(trusted:save(), "save before trusted core PDF edits")
check(not trusted:adoptSourceWrite(), "unguarded source adoption refused")
check(trusted:sourceMatches(), "full baseline match before trusted writer")
put(source, original_pdf .. "% core highlight annotation\n", 103)
check(trusted:adoptSourceWrite() and trusted:save(), "trusted core annotation write rebinds ink")
local rebound = Store.open(source)
check(rebound and #rebound:page(1) == 1, "ink reopens against trusted updated PDF")
local rebound_backup = __json_decode(files[sidecar .. ".bak"].bytes)
check(rebound_backup.source.md5 == __md5(files[source].bytes),
    "previous ink backup also matches trusted PDF revision")
files[sidecar].bytes = "{ corrupt after trusted core PDF write"
local recovered_rebound = Store.open(source)
check(recovered_rebound and #recovered_rebound:page(1) == 1,
    "backup recovery remains usable after core annotation write")
put(source, original_pdf .. "% external reordering or replacement\n", 104)
local match, match_error = rebound:sourceMatches()
check(not match and match_error:find("outside", 1, true), "external edits refused by full identity check")
check(not rebound:adoptSourceWrite(), "failed baseline check cannot authorize adoption")

files, events, faults = {}, {}, {}
put(source, original_pdf)
local interrupted = assert(Store.open(source))
interrupted:add(1, dot)
faults.rename = sidecar
check(not interrupted:save() and files[sidecar .. ".tmp"] and not files[sidecar],
    "interrupted first save leaves its durable temporary bytes")
faults.rename = nil
local from_temporary, temporary_warning = Store.open(source)
check(from_temporary and temporary_warning and from_temporary:hasInk(),
    "unfinished first save is recovered explicitly instead of reset")
check(from_temporary:save(), "recovered first-save temporary bytes install safely")

io.open, os.rename = original_open, original_rename
for _, name in ipairs(module_names) do
    package.loaded[name], package.preload[name] = original_loaded[name], original_preload[name]
end
print("Model and geometry: " .. checks .. " checks passed")
return checks
