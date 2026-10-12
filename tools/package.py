"""Build install/source archives without research files or test dependencies."""
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.4.0'
DIST = ROOT / 'dist'
PLUGIN = 'scribeink.koplugin'
DIST.mkdir(exist_ok=True)

def write_archive(path, entries):
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for source, target in sorted(entries, key=lambda item: item[1]):
            info = zipfile.ZipInfo(target, date_time=(2026, 10, 12, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, source.read_bytes())
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        assert f'{PLUGIN}/main.lua' in archive.namelist()
        assert not any('.research' in name or '__pycache__' in name for name in archive.namelist())

plugin_files = [(p, f'{PLUGIN}/{p.name}') for p in (ROOT / PLUGIN).glob('*.lua')]
install_entries = plugin_files + [(ROOT / 'README.md', f'{PLUGIN}/README.md'),
                                  (ROOT / 'LICENSE', f'{PLUGIN}/LICENSE')]
for name in ('export_pdf.py', 'README.md'):
    install_entries.append((ROOT / 'tools' / name, f'{PLUGIN}/tools/{name}'))
install = DIST / f'scribeink-{VERSION}-install.zip'
source = DIST / f'scribeink-{VERSION}-source.zip'
write_archive(install, install_entries)
source_entries = plugin_files + [(ROOT / name, name) for name in ('README.md', 'LICENSE')]
for folder in ('tests', 'tools'):
    source_entries += [(p, p.relative_to(ROOT).as_posix()) for p in (ROOT / folder).iterdir()
                       if p.is_file() and p.suffix in ('.py', '.lua', '.md', '.txt')]
write_archive(source, source_entries)
manifest = []
for archive in (install, source):
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest.append(f'{digest}  {archive.name}')
    print(f'{archive.name}: {archive.stat().st_size:,} bytes, SHA256 {digest}')
(DIST / 'SHA256SUMS.txt').write_text('\n'.join(manifest) + '\n', encoding='ascii')
