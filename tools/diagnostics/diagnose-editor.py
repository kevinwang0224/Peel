#!/usr/bin/env python3
"""Render empty/trailing-empty-line documents under ASan in an isolated app bundle.

This catches the Scintilla 5.6.7 layout under-read, and stresses cursor registration
and editor destruction. Passing does not prove an intermittent OS cursor crash fixed.
"""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile

project_root = Path(__file__).resolve().parents[2]
subprocess.run(['bash', str(project_root / 'scripts/prepare-dependencies.sh')], check=True)
build = ['swift', 'build', '--package-path', str(project_root), '--sanitize', 'address']
subprocess.run(build + ['--product', 'Peel'], check=True)
bin_dir = Path(subprocess.check_output(build + ['--show-bin-path'], text=True).strip())
combined = bin_dir / 'PeelEditor.o'
objects = [combined] if combined.exists() else sorted((bin_dir / 'PeelEditor.build').rglob('*.o'))
if not objects:
    raise RuntimeError('Cannot locate instrumented PeelEditor object files')

with tempfile.TemporaryDirectory(prefix='peel-editor-diagnostic-') as directory:
    root = Path(directory)
    app = root / 'Peel Editor Diagnostic.app'
    contents = app / 'Contents'
    resources = contents / 'Resources'
    executable = contents / 'MacOS/PeelEditorDiagnostic'
    resources.mkdir(parents=True)
    executable.parent.mkdir()
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': executable.name,
        'CFBundleIdentifier': 'com.peel.editor-diagnostic',
        'CFBundleName': 'Peel Editor Diagnostic',
        'CFBundlePackageType': 'APPL',
        'LSUIElement': True,
    }))
    for cursor in ['busy', 'flipped']:
        subprocess.run(['sips', '-s', 'format', 'tiff', str(project_root / f'Sources/PeelEditor/Vendor/scintilla/cocoa/res/mac_cursor_{cursor}.png'),
                        '--out', str(resources / f'mac_cursor_{cursor}.tiff')], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-g', '-fsanitize=address',
                    '-I', str(project_root / 'Sources/PeelEditor/include'),
                    str(project_root / 'tools/diagnostics/EditorLifecycle.mm'), *map(str, objects),
                    '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'CoreText',
                    '-framework', 'CoreGraphics', '-o', str(executable)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    # This is a command-line diagnostic with an unshown render window. The bundle
    # provides Scintilla's resources; execute it directly to verify its own exit code.
    result = subprocess.run([str(executable)], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'),
                            capture_output=True, text=True, timeout=60)
    print(result.stdout, end='')
    if result.returncode != 0 or 'EDITOR_LIFECYCLE_PASS=500' not in result.stdout or 'AddressSanitizer' in result.stderr:
        print(result.stderr)
        raise RuntimeError(f'Editor lifecycle diagnostic failed: exit {result.returncode}')
