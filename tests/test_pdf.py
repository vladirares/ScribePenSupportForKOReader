"""PDF copy export and native wrapper failure-path regression checks.

Run with Python 3.10+ and PyMuPDF/lupa installed:
    python -m unittest discover -s tests -p test_pdf.py -v
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import pymupdf
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("scribeink_export_pdf", ROOT / "tools" / "export_pdf.py")
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


class DesktopPDFExportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "original.pdf"
        self.sidecar = self.root / "original.pdf.scribeink.json"
        self.output = self.root / "copy.pdf"
        with pymupdf.open() as doc:
            for rotation in (0, 90, 180, 270):
                page = doc.new_page(width=420, height=600)
                page.insert_text((80, 130), f"Searchable text {rotation}")
                page.set_cropbox(pymupdf.Rect(30, 50, 380, 550))
                annotation = page.add_rect_annot(pymupdf.Rect(20, 20, 50, 50))
                annotation.set_info(content="Existing annotation")
                annotation.update()
                page.set_rotation(rotation)
            doc.save(self.source)
        self.original_bytes = self.source.read_bytes()
        self.ink = {
            "format": "koreader-scribe-ink", "version": 1, "coordinate_space": "mupdf-page",
            "source": {"path": "/mnt/us/documents/original.pdf", "size": len(self.original_bytes),
                       "md5": hashlib.md5(self.original_bytes).hexdigest()},
            "pages": {str(index): [{"points": [{"x": 100, "y": 120}, {"x": 150, "y": 170}], "width": 2}]
                      for index in range(1, 5)},
        }
        self.write_sidecar()

    def write_sidecar(self):
        self.sidecar.write_text(json.dumps(self.ink), encoding="utf-8")

    def test_copy_preserves_original_text_and_existing_annotations_with_rotation(self):
        self.assertEqual(EXPORTER.export_pdf(self.source, self.sidecar, self.output), 4)
        self.assertEqual(self.source.read_bytes(), self.original_bytes)
        with pymupdf.open(self.source) as source, pymupdf.open(self.output) as copy:
            for index in range(4):
                old_page, page = source[index], copy[index]
                self.assertEqual(page.get_text(), old_page.get_text())
                annots = list(page.annots())
                self.assertEqual(len(annots), 2)
                self.assertEqual(annots[0].info["content"], "Existing annotation")
                self.assertEqual(annots[1].type[0], pymupdf.PDF_ANNOT_INK)
                self.assertEqual(annots[1].flags, pymupdf.PDF_ANNOT_IS_PRINT)
                self.assertIn("/AP", copy.xref_object(annots[1].xref))
                # Transform back to the page's native rotated coordinates.
                recovered = [pymupdf.Point(*point) * page.rotation_matrix for point in annots[1].vertices[0]]
                for actual, expected in zip(recovered, ((100, 120), (150, 170))):
                    self.assertAlmostEqual(actual.x, expected[0], places=3)
                    self.assertAlmostEqual(actual.y, expected[1], places=3)

    def test_reexport_erased_strokes_preserves_other_annotations(self):
        EXPORTER.export_pdf(self.source, self.sidecar, self.output)
        self.ink["pages"]["1"] = []
        self.write_sidecar()
        self.assertEqual(EXPORTER.export_pdf(self.source, self.sidecar, self.output, overwrite=True), 3)
        with pymupdf.open(self.output) as copy:
            page = copy[0]
            annots = list(page.annots())
            self.assertEqual(len(annots), 1)
            self.assertEqual(annots[0].info["content"], "Existing annotation")

    def test_partial_eraser_fragments_export_with_a_visible_gap(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        geometry = lua.execute('return dofile(...)', str(ROOT / 'scribeink.koplugin' / 'geometry.lua'))
        original = lua.eval('{ width=2, points={{x=80,y=250},{x=240,y=250}} }')
        point = lua.table_from({'x': 160, 'y': 250})
        fragments, _ = geometry.eraseStroke(original, point, point, 10)
        self.assertEqual(len(fragments), 2)
        self.ink['pages'] = {'1': [
            {'width': fragment['width'], 'points': [
                {'x': p['x'], 'y': p['y']} for p in fragment['points'].values()
            ]} for fragment in fragments.values()
        ]}
        self.write_sidecar()
        self.assertEqual(EXPORTER.export_pdf(self.source, self.sidecar, self.output), 2)
        with pymupdf.open(self.source) as source, pymupdf.open(self.output) as copy:
            page = copy[0]
            self.assertEqual(page.get_text(), source[0].get_text())
            self.assertEqual(len(list(page.annots())), 3)  # existing annotation + two surviving paths
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(2, 2), alpha=False)
            self.assertEqual(pixmap.pixel(320, 500)[:3], (255, 255, 255))
            self.assertEqual(pixmap.pixel(200, 500)[:3], (0, 0, 0))
            self.assertEqual(pixmap.pixel(440, 500)[:3], (0, 0, 0))
        self.assertEqual(self.source.read_bytes(), self.original_bytes)

    def test_checks_source_identity_and_keeps_existing_output_on_invalid_input(self):
        self.output.write_bytes(b"previous output")
        self.ink["source"]["md5"] = "0" * 32
        self.write_sidecar()
        with self.assertRaisesRegex(ValueError, "different or modified"):
            EXPORTER.export_pdf(self.source, self.sidecar, self.output, overwrite=True)
        self.assertEqual(self.output.read_bytes(), b"previous output")
        self.assertEqual(self.source.read_bytes(), self.original_bytes)

    def test_rejects_source_sidecar_overwrite_and_bad_strokes(self):
        with self.assertRaisesRegex(ValueError, "original PDF"):
            EXPORTER.export_pdf(self.source, self.sidecar, self.source, overwrite=True)
        with self.assertRaisesRegex(ValueError, "sidecar"):
            EXPORTER.export_pdf(self.source, self.sidecar, self.sidecar, overwrite=True)
        self.ink["pages"]["1"][0]["points"][0]["x"] = float("nan")
        self.write_sidecar()
        with self.assertRaisesRegex(ValueError, "coordinates"):
            EXPORTER.export_pdf(self.source, self.sidecar, self.output)
        self.assertFalse(self.output.exists())

    def test_dot_strokes_and_overwrite_opt_in(self):
        self.ink["pages"] = {"1": [{"points": [{"x": 100, "y": 120}], "width": 2}]}
        self.write_sidecar()
        self.assertEqual(EXPORTER.export_pdf(self.source, self.sidecar, self.output), 1)
        with pymupdf.open(self.output) as copy:
            page = copy[0]
            annotation = list(page.annots())[-1]
            self.assertEqual(len(annotation.vertices[0]), 2)
        with self.assertRaisesRegex(ValueError, "already exists"):
            EXPORTER.export_pdf(self.source, self.sidecar, self.output)


class NativeLuaPDFExportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source.pdf"
        self.output = self.root / "output.pdf"
        self.source.write_text("untouched original", encoding="utf-8")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().python_attrs = self.attributes
        self.lua.globals().python_realpath = self.realpath
        self.lua.execute('''
            package.preload["libs/libkoreader-lfs"] = function()
                return { attributes = function(path) return python_attrs(path) end }
            end
            package.preload["ffi/util"] = function()
                return { realpath = function(path) return python_realpath(path) end }
            end
            calls, pages_closed, docs_closed = {}, 0, 0
            unsupported, fail_save, encrypted = false, false, false
            package.preload["ffi/mupdf"] = function()
                return { openDocument = function(source)
                    return {
                        needsPassword = function() return encrypted end,
                        authenticatePassword = function(_, password) return password == "secret" end,
                        getPages = function() return 2 end,
                        close = function() docs_closed = docs_closed + 1 end,
                        openPage = function(_, number)
                            return {
                                close = function() pages_closed = pages_closed + 1 end,
                                addInkAnnotation = not unsupported and function(_, strokes, color, width, opacity)
                                    table.insert(calls, { number = number, strokes = strokes, width = width })
                                end or nil,
                            }
                        end,
                        writeDocument = function(_, target)
                            local f = assert(io.open(target, "wb")); f:write("annotated copy"); f:close()
                            if fail_save then error("simulated MuPDF save failure") end
                        end,
                    }
                end }
            end
        ''')
        self.pdf = self.lua.execute((ROOT / "scribeink.koplugin" / "pdf.lua").read_text(encoding="utf-8"))
        self.pages = self.lua.eval('{ [2] = { { points = {{ x=10, y=20 }}, width=2 } } }')

    def attributes(self, path):
        path = Path(path)
        if not path.exists():
            return None
        info = path.stat()
        return self.lua.table_from({"mode": "directory" if path.is_dir() else "file", "ino": str(info.st_ino), "dev": str(info.st_dev)})

    @staticmethod
    def realpath(path):
        path = Path(path)
        return str(path.resolve()) if path.exists() else None

    def test_copy_and_dot_native_api(self):
        self.assertTrue(self.pdf.export(str(self.source), str(self.output), self.pages))
        self.assertEqual(self.source.read_text(), "untouched original")
        self.assertEqual(self.output.read_text(), "annotated copy")
        self.assertEqual(self.lua.globals().calls[1]["number"], 2)
        self.assertEqual(len(self.lua.globals().calls[1]["strokes"][1]), 2)
        self.assertEqual(self.lua.globals().docs_closed, 1)
        self.assertEqual(self.lua.globals().pages_closed, 2)  # probe page + annotation page

    def test_unsupported_fails_without_output(self):
        self.lua.globals().unsupported = True
        result, reason = self.pdf.export(str(self.source), str(self.output), self.pages)
        self.assertIsNone(result)
        self.assertIn("2026.07", reason)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.lua.globals().docs_closed, 1)

    def test_failed_save_cleans_temp_and_keeps_previous_export(self):
        self.output.write_text("previous export")
        self.lua.globals().fail_save = True
        result, reason = self.pdf.export(str(self.source), str(self.output), self.pages, self.lua.table_from({"overwrite": True}))
        self.assertIsNone(result)
        self.assertIn("simulated", reason)
        self.assertEqual(self.output.read_text(), "previous export")
        self.assertFalse(list(self.root.glob("*.scribeink-tmp-*")))
        self.assertEqual(self.lua.globals().docs_closed, 1)

    def test_refuses_overwriting_source_and_wrong_password(self):
        result, reason = self.pdf.export(str(self.source), str(self.source), self.pages, self.lua.table_from({"overwrite": True}))
        self.assertIsNone(result)
        self.assertIn("original PDF", reason)
        self.lua.globals().encrypted = True
        result, reason = self.pdf.probe(str(self.source), self.lua.table_from({"password": "incorrect"}))
        self.assertIsNone(result)
        self.assertIn("incorrect", reason)
        self.assertEqual(self.lua.globals().docs_closed, 1)


if __name__ == "__main__":
    unittest.main()
