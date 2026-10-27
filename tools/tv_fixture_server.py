"""Local-only IPTV playback fixture. Never proxies a subscription stream.

Serve an existing ffmpeg HLS vod.m3u8 and its segments as a rolling live
playlist, plus the VOD source for seek tests. Create/remove `stall` in the
media directory to return HTTP 503 and exercise recovery. Bind a LAN address
and use fixture.m3u in a temporary playlist; remove it after testing.
"""
import argparse
import math
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--directory', required=True, type=Path)
p.add_argument('--host', required=True)
p.add_argument('--port', type=int, default=8911)
a = p.parse_args()
lines = (a.directory / 'vod.m3u8').read_text().splitlines()
segments = [(float(line.split(':')[1].rstrip(',')), lines[i + 1])
            for i, line in enumerate(lines) if line.startswith('#EXTINF:')]
period = sum(d for d, _ in segments)
started = time.monotonic() - period


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(a.directory), **kwargs)

    def do_GET(self):
        path = urlsplit(self.path).path
        if (a.directory / 'stall').exists() and path != '/fixture.m3u':
            self.send_error(503, 'Local diagnostic outage')
            return
        base = f'http://{a.host}:{a.port}'
        if path == '/fixture.m3u':
            data = ('#EXTM3U\n'
                    '#EXTINF:-1 tvg-id="tv-test-live" group-title="Performance test",Local live test\n'
                    f'{base}/live.m3u8\n'
                    '#EXTINF:-1 tvg-id="tv-test-seek" group-title="Performance test",Local seek test\n'
                    f'{base}/vod.m3u8\n')
        elif path == '/live.m3u8':
            elapsed = time.monotonic() - started
            cycle = int(elapsed // period)
            remainder = elapsed % period
            end = cycle * len(segments)
            for duration, _ in segments:
                if remainder < duration:
                    break
                remainder -= duration
                end += 1
            start = max(0, end - 6)
            rows = ['#EXTM3U', '#EXT-X-VERSION:3',
                    f'#EXT-X-TARGETDURATION:{math.ceil(max(d for d, _ in segments))}',
                    f'#EXT-X-MEDIA-SEQUENCE:{start}',
                    f'#EXT-X-DISCONTINUITY-SEQUENCE:{start // len(segments)}']
            for i in range(start, end):
                if i > start and i % len(segments) == 0:
                    rows.append('#EXT-X-DISCONTINUITY')
                duration, name = segments[i % len(segments)]
                rows.extend([f'#EXTINF:{duration:.6f},', name])
            data = '\n'.join(rows) + '\n'
        else:
            return super().do_GET()
        body = data.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


print(f'Fixture: http://{a.host}:{a.port}/fixture.m3u', flush=True)
ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()
