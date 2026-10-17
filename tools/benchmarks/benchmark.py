#!/usr/bin/env python3
"""Benchmark a release app using synthetic data; never opens the user's history."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

project_root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--record-bytes', type=int, default=10000)
parser.add_argument('--records', type=int, default=1000)
parser.add_argument('--output', type=Path, default=project_root / 'build' / 'performance.json')
args = parser.parse_args()

class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in [
        'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired',
        'resident', 'footprint', 'start', 'exit', 'child_user', 'child_system',
        'child_idle', 'child_interrupt', 'child_pageins', 'child_elapsed', 'disk_read', 'disk_write']]

libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]

def footprint(pid):
    usage = Usage()
    return usage.footprint if libproc.proc_pid_rusage(pid, 2, ctypes.byref(usage)) == 0 else 0

with tempfile.TemporaryDirectory(prefix='peel-perf-') as directory:
    bin_dir = subprocess.check_output(['swift', 'build', '--package-path', str(project_root), '-c', 'release', '--show-bin-path'], text=True).strip()
    subprocess.run([str(Path(bin_dir) / 'PeelBench'), 'seed', directory, str(args.records), str(args.record_bytes)], check=True)
    env = dict(os.environ, PEEL_DATA_DIRECTORY=directory, PEEL_SKIP_MIGRATION='1', PEEL_METRICS='1', PEEL_BENCHMARK='1')
    executable = project_root / 'build' / 'Peel.app' / 'Contents' / 'MacOS' / 'Peel'
    started = time.monotonic()
    process = subprocess.Popen([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    metrics = {'history_records': args.records, 'history_record_bytes': args.record_bytes,
               'machine': subprocess.check_output(['uname', '-m'], text=True).strip(),
               'macos': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
               'edit_metric': 'editor insertion plus synchronous AppKit redraw; excludes keyboard dispatch and display scan-out'}
    peak = 0
    pending = b''
    def consume(line):
        line = line.decode('utf-8', errors='replace').strip()
        if line.startswith('PEEL_'):
            print(line, flush=True)
            name, value = line.split('=', 1)
            metrics[name] = float(value)
            if name == 'PEEL_READY_MS':
                metrics['process_launch_to_ready_ms'] = (time.monotonic() - started) * 1000
    try:
        while process.poll() is None:
            if time.monotonic() - started > 90:
                raise TimeoutError('Peel benchmark exceeded 90 seconds')
            children = []
            for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True).splitlines():
                pid, parent = map(int, line.split())
                if parent == process.pid:
                    children.append(pid)
            peak = max(peak, footprint(process.pid) + sum(footprint(pid) for pid in children))
            for key, _ in selector.select(timeout=0.2):
                pending += os.read(key.fileobj.fileno(), 65536)
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    consume(line)
        pending += process.stdout.read()
        for line in pending.splitlines():
            consume(line)
        if process.returncode != 0:
            raise RuntimeError(f'Peel benchmark exited with {process.returncode}')
        required = ['PEEL_READY_MS', 'PEEL_EDIT_DRAW_P95_MS', 'PEEL_IDLE_FOOTPRINT_BYTES', 'PEEL_CLOSED_FOOTPRINT_BYTES']
        if any(name not in metrics for name in required):
            raise RuntimeError('Peel benchmark did not finish all measurements')
        metrics['sampled_peak_total_footprint_bytes'] = peak
        metrics['measurement_date'] = time.strftime('%Y-%m-%d')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + '\n')
        print(f'Report: {args.output}')
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
        process.wait()
