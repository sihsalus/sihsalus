#!/usr/bin/env python3
"""Opt-in audit endpoint acceptance using dedicated non-production accounts.

Configuration is read from a private JSON file, never from password arguments.
This test appends synthetic events; it does not create or modify patients.
"""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import http.client
import json
from pathlib import Path
import socket
import ssl
import stat
import time
from urllib.parse import urlsplit
import uuid


class AuditAcceptance:
    def __init__(self, config):
        self.config = config
        self.url = urlsplit(config['base_url'])
        if self.url.scheme != 'https' or self.url.username or self.url.password:
            raise ValueError('A credential-free HTTPS base URL is required')
        if config.get('environment') != 'dev':
            raise ValueError('This acceptance runner requires an explicit DEV target')
        self.actors = config['actors']
        if set(self.actors) != {'record', 'review', 'denied'}:
            raise ValueError('Provide three dedicated test accounts: record, review, denied')
        if len({actor['username'] for actor in self.actors.values()}) != 3:
            raise ValueError('The test accounts must be distinct')
        if not all(actor['username'].startswith('audit_dev_') for actor in self.actors.values()):
            raise ValueError('Only dedicated audit_dev_ accounts are accepted')
        self.identities = {}
        self.created_ids = []
        self.passed = []

    def request(self, method, path, actor=None, payload=None, raw=None,
                content_type='application/json', retry_limit=True):
        context = ssl.create_default_context(cafile=self.config.get('ca_file'))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        if self.config.get('ca_file'):
            context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        headers = {'Accept': 'application/json'}
        if actor:
            account = self.actors[actor]
            token = base64.b64encode((account['username'] + ':' + account['password']).encode()).decode()
            headers['Authorization'] = 'Basic ' + token
        body = json.dumps(payload).encode() if payload is not None else raw
        if body is not None:
            headers['Content-Type'] = content_type
        for attempt in range(4):
            connection = http.client.HTTPSConnection(
                self.url.hostname, self.url.port or 443, timeout=20, context=context)
            if self.config.get('connect_address'):
                connection.sock = context.wrap_socket(socket.create_connection(
                    (self.config['connect_address'], self.url.port or 443), timeout=20),
                    server_hostname=self.url.hostname)
            try:
                connection.request(method, path, body=body, headers=headers)
                response = connection.getresponse()
                status = response.status
                response_headers = {k.lower(): v for k, v in response.getheaders()}
                response_body = response.read(1024 * 1024)
            finally:
                connection.close()
            if status == 429 and retry_limit and attempt < 3:
                time.sleep(min(int(response_headers.get('retry-after', '1')), 5))
                continue
            try:
                data = json.loads(response_body)
            except ValueError:
                data = None
            return status, response_headers, data, response_body
        raise RuntimeError('Request retry bound reached')

    def require(self, condition, description):
        if not condition:
            raise AssertionError(description)

    def audit(self, method, actor=None, payload=None, **kwargs):
        suffix = kwargs.pop('suffix', '')
        result = self.request(method, '/openmrs/ws/rest/v1/sihsalus/audit' + suffix,
                              actor, payload, **kwargs)
        status, headers, _, body = result
        self.require('no-store' in headers.get('cache-control', ''), 'Audit response must use no-store')
        if status >= 400:
            for forbidden in (b'org.openmrs', b'java.lang.', b'SQLException', b'componentStack'):
                self.require(forbidden not in body, 'Audit error must not expose diagnostic details')
        return result

    def event(self, **changes):
        event = {'id': str(uuid.uuid4()), 'eventType': 'PATIENT_SEARCH',
                 'timestamp': '2026-01-02T03:04:05Z',
                 'metadata': {'appName': 'esm-patient-search-app', 'outcome': 'SUCCESS', 'offline': True}}
        event.update(changes)
        return event

    def append(self, event):
        status, _, data, _ = self.audit('POST', 'record', [event])
        self.require(status in (200, 201), 'Recorder must be able to append an event')
        self.require(data.get('accepted') == [event['id']] and data.get('count') == 1,
                     'Response must acknowledge the exact event ID')
        if event['id'] not in self.created_ids:
            self.created_ids.append(event['id'])

    def find_events(self, identifiers):
        found = []
        for offset in range(0, 1000, 100):
            status, _, data, _ = self.audit('GET', 'review', suffix=f'?startIndex={offset}&limit=100')
            self.require(status == 200, 'Reviewer must be able to read audit events')
            rows = data.get('results', [])
            found.extend(row for row in rows if row.get('id') in identifiers)
            if len(rows) < 100:
                return found
        raise AssertionError('Audit review exceeded the acceptance scan bound')

    def passed_case(self, description):
        self.passed.append(description)
        print('[PASS] ' + description, flush=True)

    def run(self):
        status, headers, _, _ = self.request('GET', '/openmrs/spa/build-info.json')
        self.require(status == 200 and headers.get('x-sihsalus-node-id') == self.config['expected_node_id'],
                     'Target node identity does not match DEV')
        self.require(self.request('GET', '/ready')[0] == 200, 'DEV must be ready')
        for actor in self.actors:
            status, _, session, _ = self.request('GET', '/openmrs/ws/rest/v1/session', actor)
            self.require(status == 200 and session.get('authenticated') is True,
                         'Every dedicated test account must authenticate')
            self.identities[actor] = session['user']['uuid']
        self.passed_case('DEV identity, readiness and three distinct authenticated accounts')

        for suffix in ('', '/'):
            for method in ('GET', 'POST'):
                payload = [self.event()] if method == 'POST' else None
                for actor in (None, 'denied'):
                    status = self.audit(method, actor, payload, suffix=suffix)[0]
                    self.require(status in (401, 403), 'Unauthorised audit access must be rejected')
        self.passed_case('Anonymous and unprivileged requests rejected on both endpoint paths')
        self.require(self.audit('GET', 'record')[0] == 403, 'Record privilege must not permit review')
        self.require(self.audit('POST', 'review', [self.event()])[0] == 403,
                     'Review privilege must not permit recording')
        self.passed_case('Recording and review privileges are independent')

        started = datetime.now(timezone.utc)
        event = self.event(userUuid=str(uuid.uuid4()), sessionId={'ignored': True})
        event['metadata']['message'] = 'SYNTHETIC_FREE_TEXT_MUST_NOT_PERSIST'
        self.append(event)
        row = self.find_events({event['id']})[0]
        self.require(row['actorUuid'] == self.identities['record'], 'Server must supply the actor')
        received = datetime.fromisoformat(row['receivedAt'].replace('Z', '+00:00'))
        self.require(abs((received - started).total_seconds()) < 120, 'Server must supply receipt time')
        self.require(row['timestamp'] == row['receivedAt'], 'Timestamp alias must use receipt time')
        self.require(row.get('occurredAtAuthoritative') is False, 'Offline client time must be non-authoritative')
        self.require('SYNTHETIC_FREE_TEXT_MUST_NOT_PERSIST' not in json.dumps(row),
                     'Unstructured client text must not become persistent evidence')
        self.require('sessionId' not in row, 'Session credentials must not appear in review')
        self.passed_case('Server actor/time, non-authoritative offline time and metadata minimisation')

        self.append(event)
        self.require(len(self.find_events({event['id']})) == 1, 'Replaying an event must not duplicate it')
        concurrent = self.event()
        with ThreadPoolExecutor(max_workers=3) as pool:
            responses = list(pool.map(lambda _: self.audit('POST', 'record', [concurrent]), range(3)))
        self.require(all(result[0] in (200, 201) for result in responses), 'Concurrent replay must succeed')
        self.require(len(self.find_events({concurrent['id']})) == 1, 'Concurrent replay must persist one event')
        self.created_ids.append(concurrent['id'])
        self.passed_case('Sequential and concurrent retries are idempotent')

        first = self.event()
        conflict = dict(event, eventType='UNHANDLED_ERROR')
        self.require(self.audit('POST', 'record', [first, conflict])[0] == 400, 'Conflicting replay must be rejected')
        self.require(not self.find_events({first['id']}), 'Failed batch must roll back its earlier insert')
        self.passed_case('Conflicting replay rolls back the complete batch')

        malformed = ([], [self.event(unknownField='rejected')],
                     [self.event(eventType='PATIENT_VIEW')], [self.event()] * 2,
                     [self.event() for _ in range(51)])
        for payload in malformed:
            self.require(self.audit('POST', 'record', payload)[0] == 400, 'Invalid batch must be rejected')
        self.require(self.audit('POST', 'record', raw=b'[' + b' ' * 65536 + b']')[0] == 413,
                     'Oversized request must be rejected')
        self.require(self.audit('POST', 'record', raw=b'[]', content_type='text/plain')[0] == 415,
                     'Unsupported media type must be rejected')
        self.require(self.audit('DELETE', 'record')[0] == 405, 'Endpoint must not allow deletion')
        self.passed_case('Validation, payload size, media type and unsupported method protections')

        invalid_clock = self.event(timestamp='invalid-client-clock')
        self.append(invalid_clock)
        row = self.find_events({invalid_clock['id']})[0]
        self.require('occurredAt' not in row, 'Invalid optional client time must be discarded')
        self.passed_case('Invalid client clock does not block an otherwise valid offline event')
        self.require(self.request('GET', '/ready')[0] == 200, 'Readiness must remain healthy')
        self.passed_case('Readiness remains healthy after acceptance')
        return {'passed': self.passed, 'event_ids': self.created_ids,
                'actor_uuids': self.identities, 'completed_at': datetime.now(timezone.utc).isoformat()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='Private JSON configuration with test credentials')
    parser.add_argument('--report', type=Path, required=True, help='New JSON evidence file; contains no passwords')
    args = parser.parse_args()
    if stat.S_IMODE(args.config.stat().st_mode) & 0o077:
        parser.error('Credential configuration must only be accessible to its owner')
    if args.report.exists():
        parser.error('Choose a new report path to preserve previous evidence')
    acceptance = AuditAcceptance(json.loads(args.config.read_text()))
    result = acceptance.run()
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    args.report.chmod(0o600)


if __name__ == '__main__':
    main()
