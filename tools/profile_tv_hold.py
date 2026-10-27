"""Measure one genuine remote hold on an instrumented TV build (no streams).

Install tools/HoldGuideKey.java as a shell-only DEX first. Unlike repeated
`input keyevent` commands, this sends one down, repeat events and one release.
"""
import argparse
import json
import subprocess
import threading
import time
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--adb', required=True)
p.add_argument('--serial', required=True)
p.add_argument('--seconds', type=float, default=12)
p.add_argument('--direction', choices=['up', 'down'], default='down')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
adb = [a.adb, '-s', a.serial]
pid = subprocess.check_output(adb + ['shell', 'pidof', 'com.akus0.iptvpreview'], text=True).strip()
rows = []
log = subprocess.Popen(adb + ['logcat', '-T', '1', '--pid=' + pid, 'flutter:I', '*:S'], stdout=subprocess.PIPE, text=True)
def read():
    for line in log.stdout:
        if 'IPTV_FRAME ' in line:
            rows.append(json.loads(line.split('IPTV_FRAME ', 1)[1]))
thread = threading.Thread(target=read, daemon=True)
thread.start()
try:
    subprocess.run(adb + ['shell', 'CLASSPATH=/data/local/tmp/iptv-guide-input.dex', 'app_process', '/', 'HoldGuideKey',
                         '20' if a.direction == 'down' else '19', str(int(a.seconds * 1000))], check=True)
    time.sleep(2.1)
finally:
    log.terminate()
    log.wait(timeout=5)
    thread.join(timeout=5)
a.output.write_text(json.dumps(rows, indent=2) + '\n')
print(json.dumps({'frames': sum(r['frames'] for r in rows),
                  'ui_over_16ms': sum(r['build_over_16ms'] for r in rows),
                  'raster_over_16ms': sum(r['raster_over_16ms'] for r in rows),
                  'worst_batch_ui_p95_ms': max((r['build_p95_ms'] for r in rows), default=0)}))
