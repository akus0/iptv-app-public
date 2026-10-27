"""Collect Flutter frame timings during a reproducible, stream-free remote walk.

Requires an APK built from tools/tv_profile.dart. Keys are Android key codes;
do not include OK/Enter unless the selected control is known not to start TV.
"""
import argparse
import json
import subprocess
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default='adb')
parser.add_argument('--serial', required=True)
actions = parser.add_mutually_exclusive_group(required=True)
actions.add_argument('--keys', help='Comma-separated key codes')
actions.add_argument('--actions', type=Path, help='JSON arrays: key, text, tap, wait, hold; explicit safe setup actions')
parser.add_argument('--interval', type=float, default=.15)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
adb = [args.adb, '-s', args.serial]
pid = subprocess.check_output(adb + ['shell', 'pidof', 'com.akus0.iptvpreview'],
                              text=True).strip()
# Drain setup/route-transition timings before measuring the navigation itself.
time.sleep(2.1)
samples = []
marker = str(uuid.uuid4())
subprocess.run(adb + ['shell', 'log', '-t', 'IPTV_NAV', marker], check=True)
try:
    sequence = (json.loads(args.actions.read_text()) if args.actions else
                [['key', int(key)] for key in args.keys.split(',')])
    for action in sequence:
        kind, *values = action
        if kind == 'wait':
            time.sleep(float(values[0]))
            continue
        # Never send the remaining walk to the TV launcher or another app if
        # a Back/OK action unexpectedly leaves the diagnostic screen.
        activities = subprocess.check_output(
            adb + ['shell', 'dumpsys', 'activity', 'activities'], text=True)
        resumed = next((line for line in activities.splitlines()
                        if 'topResumedActivity=' in line), '')
        if 'com.akus0.iptvpreview/' not in resumed:
            raise RuntimeError('Navigation stopped: IPTV app is no longer foreground')
        if kind == 'hold':
            key, milliseconds = map(int, values)
            if key not in (19, 20) or not 1 <= milliseconds <= 60000:
                raise ValueError('Only bounded Up/Down holds are supported')
            subprocess.run(adb + ['shell',
                'CLASSPATH=/data/local/tmp/iptv-guide-input.dex',
                'app_process', '/', 'HoldGuideKey', str(key), str(milliseconds)],
                check=True, stdout=subprocess.DEVNULL)
            continue
        command = {'key': 'keyevent', 'tap': 'tap', 'text': 'text'}[kind]
        subprocess.run(adb + ['shell', 'input', command] + [str(v) for v in values],
                       check=True, stdout=subprocess.DEVNULL)
        time.sleep(args.interval)
    time.sleep(2.1)  # Flush the diagnostic reporter's final two-second batch.
finally:
    # Read after the walk so logcat startup cannot race the start marker.
    output = subprocess.check_output(adb + ['logcat', '-d', '-v', 'threadtime',
        'flutter:I', 'IPTV_NAV:I', '*:S'], text=True)
    started = False
    for line in output.splitlines():
        if marker in line:
            started = True
        if started and 'IPTV_FRAME ' in line and pid in line.split()[:4]:
            try:
                samples.append(json.loads(line.split('IPTV_FRAME ', 1)[1]))
            except ValueError:
                pass
if not samples:
    raise SystemExit('No frame samples captured; check diagnostic build and navigation focus.')
args.output.write_text(json.dumps(samples, indent=2) + '\n')
print(json.dumps({
    'samples': len(samples),
    'frames': sum(s['frames'] for s in samples),
    'build_over_16ms': sum(s['build_over_16ms'] for s in samples),
    'raster_over_16ms': sum(s['raster_over_16ms'] for s in samples),
    'worst_batch_build_p95_ms': max((s['build_p95_ms'] for s in samples), default=0),
    'worst_batch_raster_p95_ms': max((s['raster_p95_ms'] for s in samples), default=0),
}))
