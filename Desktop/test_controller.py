import copy
from contextlib import closing
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from controller import Repository, default_config, handler, validate, ThreadingHTTPServer


class ControllerTests(unittest.TestCase):
    def test_invalid_config_does_not_overwrite_previous(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Repository(Path(directory))
            before = (Path(directory) / 'config.json').read_bytes()
            bad = copy.deepcopy(repository.config)
            bad['owner']['name'] = ''
            with self.assertRaises(ValueError): repository.update(bad)
            self.assertEqual((Path(directory) / 'config.json').read_bytes(), before)

    def test_http_rejects_unauthenticated_and_preserves_phone_state(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Repository(Path(directory))
            server = ThreadingHTTPServer(('127.0.0.1', 0), handler(repository))
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                with closing(http.client.HTTPConnection(*server.server_address)) as connection:
                    connection.request('GET', '/config')
                    response = connection.getresponse(); self.assertEqual(response.status, 401); response.read()
                state = dict(schemaVersion=3, memories=[], messages=[{'content': '保留对话'}],
                             owner=dict(name='手机昵称', account='', region='', signature=''))
                headers = {'Authorization': 'Bearer ' + repository.token, 'Content-Type': 'application/json'}
                with closing(http.client.HTTPConnection(*server.server_address)) as connection:
                    connection.request('POST', '/state', json.dumps(state), headers)
                    response = connection.getresponse(); self.assertEqual(response.status, 200); response.read()
                stored = json.loads((Path(directory) / 'phone-state.json').read_text(encoding='utf-8'))
                self.assertEqual(stored['messages'], state['messages'])
                self.assertEqual(repository.config['owner']['name'], '手机昵称')
            finally:
                server.shutdown(); server.server_close(); thread.join()

    def test_duplicate_memory_and_invalid_parameters_rejected(self):
        config = default_config()
        config['settings']['proactivity'] = 2
        with self.assertRaises(ValueError): validate(config)


if __name__ == '__main__': unittest.main()
