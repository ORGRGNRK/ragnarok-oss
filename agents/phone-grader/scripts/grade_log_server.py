#!/usr/bin/env python3
"""Private gateway. Run behind HTTPS on Alexus; credentials come only from env.
Requires psycopg v3. No SQL identifiers or connection strings come from requests.
"""
import hmac
import json
import os
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 2 * 1024 * 1024


def validate(path, body):
    if not path.startswith('/grades/'):
        raise ValueError('path')
    identity = str(uuid.UUID(path.removeprefix('/grades/')))
    data = json.loads(body)
    grade = data['grade']
    if type(data['id']) is not int or data['id'] < 1:
        raise ValueError('local id')
    if grade['overall_grade'] not in ('A', 'B', 'C', 'D', 'F'):
        raise ValueError('grade')
    if not isinstance(data['phoneModel'], str) or not isinstance(grade['summary'], str):
        raise ValueError('text')
    timestamp = datetime.fromisoformat(data['createdAt'].replace('Z', '+00:00'))
    if timestamp.tzinfo is None:
        raise ValueError('timezone')
    return identity, data


def store(identity, data):
    import psycopg
    from psycopg.types.json import Jsonb
    # Context commits both writes or rolls both back.
    with psycopg.connect(os.environ['PHONE_GRADES_DATABASE_URL'], connect_timeout=5) as conn:
        conn.execute("SET LOCAL statement_timeout = '10s'")
        conn.execute('''INSERT INTO phone_grades
            (id, local_record_id, phone_model, grade, summary, graded_at, grade_json)
            VALUES (%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT (id) DO UPDATE SET local_record_id=EXCLUDED.local_record_id,
            phone_model=EXCLUDED.phone_model, grade=EXCLUDED.grade, summary=EXCLUDED.summary,
            graded_at=EXCLUDED.graded_at, grade_json=EXCLUDED.grade_json, updated_at=now()''',
            (identity, data['id'], data['phoneModel'], data['grade']['overall_grade'],
             data['grade']['summary'], data['createdAt'], Jsonb(data)))
        conn.execute('INSERT INTO phone_grade_receipts (grade_id) VALUES (%s)', (identity,))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # No request paths, private payloads or auth headers in logs.

    def reply(self, status, body):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_PUT(self):
        if not hmac.compare_digest(self.headers.get('Authorization', '').encode('utf-8'), ('Bearer ' + self.server.token).encode('utf-8')):
            return self.reply(401, {'error': 'unauthorized'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= MAX_BODY:
                return self.reply(413, {'error': 'body size'})
            identity, data = validate(self.path, self.rfile.read(size))
        except (ValueError, KeyError, TypeError, AttributeError):
            return self.reply(400, {'error': 'invalid grade'})
        try:
            store(identity, data)
        except Exception:
            return self.reply(503, {'error': 'database write failed; retry safe'})
        self.reply(200, {'id': identity})

    def setup(self):
        super().setup()
        self.connection.settimeout(15)


if __name__ == '__main__':
    token = os.environ['PHONE_GRADES_TOKEN']
    if len(token) < 32:
        raise SystemExit('PHONE_GRADES_TOKEN must have at least 32 characters')
    os.environ['PHONE_GRADES_DATABASE_URL']
    server = ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('PORT', '8789'))), Handler)
    server.token = token
    server.serve_forever()
