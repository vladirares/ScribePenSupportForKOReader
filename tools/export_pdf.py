#!/usr/bin/env python3
"""Export Scribe Ink JSON sidecars to standard Ink annotations in a PDF copy.

Install dependency with: python -m pip install PyMuPDF
Example: python export_pdf.py book.pdf --ink book.pdf.scribeink.json
Always starts from the original PDF, so re-exporting reflects erased strokes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile


def finite_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def source_md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_ink(sidecar: Path, source: Path) -> dict:
    with sidecar.open("r", encoding="utf-8") as stream:
        ink = json.load(stream)
    if not isinstance(ink, dict) or ink.get("format") != "koreader-scribe-ink" or ink.get("version") != 1:
        raise ValueError("Not a supported Scribe Ink sidecar (expected version 1).")
    if ink.get("coordinate_space") != "mupdf-page":
        raise ValueError("Unknown ink coordinate space.")
    identity = ink.get("source")
    if not isinstance(identity, dict):
        raise ValueError("The sidecar has no original PDF identity.")
    expected_md5 = identity.get("md5", "")
    if not isinstance(expected_md5, str) or not re.fullmatch(r"[0-9a-fA-F]{32}", expected_md5):
        raise ValueError("The sidecar has no valid original PDF checksum.")
    if identity.get("size") != source.stat().st_size or expected_md5.lower() != source_md5(source):
        raise ValueError("This sidecar belongs to a different or modified PDF. Use the unchanged original PDF.")
    if not isinstance(ink.get("pages"), dict):
        raise ValueError("Invalid handwriting page list.")
    return ink


def validate_strokes(pages: dict, page_count: int) -> list[tuple[int, list]]:
    result = []
    for page_key, strokes in pages.items():
        if not isinstance(page_key, str) or not re.fullmatch(r"[1-9][0-9]*", page_key):
            raise ValueError(f"Invalid page number: {page_key!r}.")
        page_number = int(page_key)
        if page_number > page_count or not isinstance(strokes, list):
            raise ValueError(f"Invalid handwriting data on page {page_number}.")
        checked = []
        for stroke in strokes:
            if not isinstance(stroke, dict) or not isinstance(stroke.get("points"), list) or not stroke["points"]:
                raise ValueError(f"Invalid stroke on page {page_number}.")
            width = stroke.get("width", 1)
            if not finite_number(width) or not 0 < width <= 1000:
                raise ValueError("Invalid ink width.")
            points = []
            for point in stroke["points"]:
                if not isinstance(point, dict) or any(
                    not finite_number(point.get(axis)) or abs(point[axis]) > 10_000_000
                    for axis in ("x", "y")
                ):
                    raise ValueError("Invalid ink coordinates.")
                points.append((point["x"], point["y"]))
            if len(points) == 1:
                points.append((points[0][0] + 0.01, points[0][1]))
            checked.append((points, width))
        result.append((page_number, checked))
    return sorted(result)


def export_pdf(source: Path, sidecar: Path, output: Path, *, overwrite: bool = False, password: str | None = None) -> int:
    try:
        import pymupdf
    except ImportError as exc:
        raise RuntimeError("Install the PDF exporter dependency: python -m pip install PyMuPDF") from exc

    source, sidecar, output = source.resolve(), sidecar.resolve(), output.resolve()
    if output == source or (output.exists() and os.path.samefile(source, output)):
        raise ValueError("The original PDF cannot be overwritten. Choose a different output filename.")
    if output == sidecar or (output.exists() and os.path.samefile(sidecar, output)):
        raise ValueError("The handwriting sidecar cannot be overwritten.")
    if output.exists() and not overwrite:
        raise ValueError("Output already exists; choose another filename or pass --overwrite.")
    ink = load_ink(sidecar, source)
    temporary = None
    annotation_count = 0
    try:
        with pymupdf.open(source) as document:
            if not document.is_pdf:
                raise ValueError("The input must be a PDF.")
            if document.needs_pass and (password is None or not document.authenticate(password)):
                raise ValueError("The PDF needs a password; pass --password.")
            checked = validate_strokes(ink["pages"], len(document))
            for page_number, strokes in checked:
                page = document[page_number - 1]
                # KOReader uses native MuPDF coordinates, with the document's /Rotate.
                # PyMuPDF's annotation API expects unrotated coordinates instead.
                matrix = page.derotation_matrix
                for points, width in strokes:
                    vertices = [tuple(pymupdf.Point(x, y) * matrix) for x, y in points]
                    annotation = page.add_ink_annot([vertices])
                    annotation.set_border(width=width)
                    annotation.set_colors(stroke=(0, 0, 0))
                    annotation.set_opacity(1)
                    annotation.set_flags(pymupdf.PDF_ANNOT_IS_PRINT)
                    annotation.set_info(title="KOReader Scribe Ink", subject="Scribe Ink handwriting")
                    annotation.update()
                    annotation_count += 1
            with tempfile.NamedTemporaryFile(prefix=f".{output.name}.scribeink-", suffix=".pdf", dir=output.parent, delete=False) as handle:
                temporary = Path(handle.name)
            document.save(temporary, garbage=0, deflate=True, encryption=pymupdf.PDF_ENCRYPT_KEEP)
        with temporary.open("r+b") as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return annotation_count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pdf", type=Path, help="Unchanged original PDF copied from the Kindle")
    parser.add_argument("--ink", type=Path, help="Sidecar JSON (default: <pdf>.scribeink.json)")
    parser.add_argument("--output", "-o", type=Path, help="Annotated PDF copy (default: <stem>-annotated.pdf)")
    parser.add_argument("--overwrite", action="store_true", help="Replace an existing output copy")
    parser.add_argument("--password", help="Password for an encrypted PDF")
    args = parser.parse_args(argv)
    sidecar = args.ink or Path(str(args.pdf) + ".scribeink.json")
    output = args.output or args.pdf.with_name(args.pdf.stem + "-annotated.pdf")
    try:
        count = export_pdf(args.pdf, sidecar, output, overwrite=args.overwrite, password=args.password)
    except (ValueError, OSError, RuntimeError) as exc:
        print(f"Export failed: {exc}", file=sys.stderr)
        return 1
    print(f"Saved {count} handwriting strokes to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
