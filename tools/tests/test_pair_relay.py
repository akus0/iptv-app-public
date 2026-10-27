import http.client
import importlib.util
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch


def load_relay(environment):
    path = Path(__file__).resolve().parents[1] / 'pair_relay/relay.py'
    spec = importlib.util.spec_from_file_location('test_pair_relay_server', path)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, environment, clear=True):
        spec.loader.exec_module(module)
    return module


class PairRelayTests(unittest.TestCase):
    def test_default_page_is_the_bundled_pairing_form(self):
        relay = load_relay({})
        expected = Path(__file__).resolve().parents[2] / 'assets/pair/pair.html'
        self.assertEqual(relay._load_page(), expected.read_bytes())

    def test_page_override_still_works(self):
        with tempfile.TemporaryDirectory() as directory:
            page = Path(directory) / 'custom.html'
            page.write_text('<html>custom pairing form</html>')
            relay = load_relay({'PAIR_PAGE': str(page)})
            self.assertEqual(relay._load_page(), page.read_bytes())

    def test_loopback_pairing_serves_form_and_consumes_payload_once(self):
        relay = load_relay({'PAIR_REQUIRE_APP': '1'})
        server = relay.ThreadingHTTPServer(('127.0.0.1', 0), relay.Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        def request(method, path, body=None, headers=None):
            client.request(method, path, body, headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        try:
            code, headers, page = request('GET', '/p')
            self.assertEqual(code, 200)
            self.assertIn(b'<html', page.lower())
            self.assertEqual(headers['Cache-Control'], 'no-store')
            self.assertEqual(headers['Referrer-Policy'], 'no-referrer')
            path = '/api/s/' + 'fixture-session-12345'
            payload = b'{"iv":"fixture","ct":"encrypted-fixture"}'
            self.assertEqual(request('PUT', path, payload)[0], 204)
            self.assertEqual(request('PUT', path, payload)[0], 409)
            self.assertEqual(request('GET', path)[0], 403)
            code, _, body = request('GET', path, headers={relay.APP_HEADER: '1'})
            self.assertEqual(code, 200)
            self.assertEqual(body, payload)
            self.assertEqual(request('GET', path, headers={relay.APP_HEADER: '1'})[0], 404)
        finally:
            client.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
