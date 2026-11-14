import json
import sys
import types
import unittest
from unittest.mock import patch
import grade_log_server as log

ID = '32b0479c-4107-482d-a85a-613128affdd0'
DATA = {'id': 7, 'phoneModel': 'Test phone', 'grade': {'overall_grade': 'B', 'summary': 'Unicode 日本語'},
        'createdAt': '2026-11-12T10:00:00Z'}


class GradeLogServerTests(unittest.TestCase):
    def test_valid_roundtrip(self):
        self.assertEqual(log.validate('/grades/' + ID, json.dumps(DATA)), (ID, DATA))

    def test_invalid_paths(self):
        for path in ['/other/' + ID, '/grades/not-a-uuid', '/grades/' + ID + '?x=1']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                log.validate(path, json.dumps(DATA))

    def test_invalid_payloads(self):
        for field, value in [('id', True), ('id', -1), ('grade', {'overall_grade': 'Z'}),
                             ('phoneModel', 12), ('createdAt', '2026-11-12')]:
            with self.subTest(field=field), self.assertRaises((ValueError, KeyError)):
                log.validate('/grades/' + ID, json.dumps({**DATA, field: value}))

    def test_atomic_parameterized_write(self):
        from unittest.mock import MagicMock
        conn = MagicMock()
        pg = types.ModuleType('psycopg'); pg.connect = MagicMock(return_value=conn)
        json_module = types.ModuleType('psycopg.types.json'); json_module.Jsonb = lambda data: data
        with patch.dict(sys.modules, {'psycopg': pg, 'psycopg.types.json': json_module}), \
             patch.dict(log.os.environ, {'PHONE_GRADES_DATABASE_URL': 'test-only'}):
            log.store(ID, DATA)
        calls = conn.__enter__.return_value.execute.call_args_list
        self.assertEqual(len(calls), 3)
        self.assertIn('ON CONFLICT (id) DO UPDATE', calls[1].args[0])
        self.assertNotIn(DATA['phoneModel'], calls[1].args[0])
        self.assertEqual(calls[1].args[1][0], ID)
        self.assertEqual(calls[2].args[1], (ID,))
        conn.__exit__.assert_called_once_with(None, None, None)


class GradeLogHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import threading
        cls.server = log.ThreadingHTTPServer(('127.0.0.1', 0), log.Handler)
        cls.server.token = 'x' * 32
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()

    def request(self, body, token=None):
        from http.client import HTTPConnection
        conn = HTTPConnection(*self.server.server_address, timeout=3)
        headers = {'Content-Type': 'application/json'}
        if token is not None:
            headers['Authorization'] = 'Bearer ' + token
        conn.request('PUT', '/grades/' + ID, body=body, headers=headers)
        response = conn.getresponse()
        result = (response.status, json.loads(response.read()))
        conn.close()
        return result

    def test_unauthorized_never_writes(self):
        with patch.object(log, 'store') as store:
            self.assertEqual(self.request(json.dumps(DATA))[0], 401)
            store.assert_not_called()

    def test_invalid_body_never_writes(self):
        with patch.object(log, 'store') as store:
            self.assertEqual(self.request('not json', 'x' * 32)[0], 400)
            store.assert_not_called()

    def test_database_failure_does_not_leak_details(self):
        with patch.object(log, 'store', side_effect=RuntimeError('private DSN password')):
            status, body = self.request(json.dumps(DATA), 'x' * 32)
            self.assertEqual(status, 503)
            self.assertNotIn('password', str(body))

    def test_successful_receipt_matches_identity(self):
        with patch.object(log, 'store') as store:
            self.assertEqual(self.request(json.dumps(DATA), 'x' * 32), (200, {'id': ID}))
            store.assert_called_once_with(ID, DATA)


if __name__ == '__main__':
    unittest.main()
