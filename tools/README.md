# PDF export on a computer

KOReader 2026.07 or newer includes the safe MuPDF ink API used by the plugin's **Export annotated PDF** menu. The plugin detects that API at runtime. On an older build you can keep writing and erasing on the Kindle, then export the saved handwriting with this script.

1. Copy the unchanged original PDF and its adjacent `<filename>.pdf.scribeink.json` file from your Kindle to the computer. Keep a backup of both.
2. Install Python 3.10 or newer, then run `python -m pip install PyMuPDF` once.
3. In this folder run `python export_pdf.py "C:\Books\book.pdf"`. If Python is installed as `py`, use `py` instead of `python`.

The script creates `book-annotated.pdf` beside the original. The PDF's text, page content, and existing annotations are preserved, and handwriting becomes standard PDF Ink annotations with appearance streams. It verifies the sidecar's checksum against the original PDF and supports cropped and rotated pages.

After erasing or adding strokes on the Kindle, copy the latest JSON file and repeat the export with `--overwrite`. Each export rebuilds from the unchanged original, so erased strokes disappear from the new copy. The exporter does not delete other annotations.

Use `--ink "path\notes.json"` for a relocated sidecar, `--output "path\copy.pdf"` for another output filename, and `--password "password"` for an encrypted PDF. Export refuses to overwrite the original or the sidecar. Editing an exported copy further in another PDF app does not update the Kindle's sidecar; use a different output filename to preserve such edits.

The official API sources are [KOReader v2026.07's MuPDF wrapper](https://github.com/koreader/koreader-base/blob/6232b2604873f1aa2b847f95d0364d6f90aa1d3a/ffi/mupdf.lua) and [PyMuPDF's annotation API](https://pymupdf.readthedocs.io/en/latest/page.html#Page.add_ink_annot).
