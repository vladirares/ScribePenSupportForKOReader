"""Run device-independent LuaJIT and real-PDF checks. Requires lupa and PyMuPDF."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
# Local development dependencies are never part of the installable plugin.
DEPS = ROOT / '.research' / 'test-runtime'
if DEPS.exists():
    sys.path.insert(0, str(DEPS))
from lupa.luajit21 import LuaRuntime, lua_type


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    metatable = lua.eval('getmetatable')

    def from_lua(value):
        if lua_type(value) != 'table':
            return value
        entries = dict(value.items())
        meta = metatable(value)
        kind = meta['__json_type'] if meta else None
        if kind == 'array' or (kind != 'object' and entries and
                              set(entries) == set(range(1, len(entries) + 1))):
            return [from_lua(entries[i]) for i in range(1, len(entries) + 1)]
        return {str(k): from_lua(v) for k, v in entries.items()}

    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        return value

    lua.globals()['__json_encode'] = lambda value, *_: json.dumps(from_lua(value), ensure_ascii=False)
    lua.globals()['__json_decode'] = lambda value: to_lua(json.loads(value))
    lua.globals()['__md5'] = lambda value: hashlib.md5(value.encode()).hexdigest()
    return lua


if __name__ == '__main__':
    compiler = runtime()
    compile_lua = compiler.eval('function(path) local f,e=loadfile(path); if not f then error(e) end end')
    for path in sorted((ROOT / 'scribeink.koplugin').glob('*.lua')):
        compile_lua(str(path))
    print('All plugin files compile under LuaJIT 2.1', flush=True)
    for name in ('test_input.lua', 'test_eraser_feedback.lua', 'test_input_adapter.lua', 'test_coreinput.lua', 'test_model.lua', 'test_render.lua', 'test_toolbar.lua', 'test_ui.lua'):
        path = ROOT / 'tests' / name
        if path.exists():
            count = runtime().execute('return dofile(...)', str(path))
            if name.startswith('test_input'):
                print(f'{name}: {count} checks passed', flush=True)
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'), pattern='test_pdf.py')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
