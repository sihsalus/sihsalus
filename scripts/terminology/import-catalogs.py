#!/usr/bin/env python3
"""Load prepared draft batches sequentially, retaining task IDs for safe resumption."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward an administrator token to a redirected endpoint."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    """Require a fresh SIHSALUS organization or the existing migration journal."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', type=Path, required=True)
    parser.add_argument('--catalogs', type=Path, required=True)
    parser.add_argument('--limit', type=int, default=0, help='Maximum new batches in this invocation; 0 loads all.')
    parser.add_argument('--parallel', type=int, choices=(1, 2), default=2,
                        help='At most two execution tasks share the existing CPU and memory limits.')
    args = parser.parse_args()
    os.umask(0o077)
    lock_file = (args.catalogs / '.import.lock').open('a')
    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if args.env.stat().st_mode & 0o077:
        parser.error('The private environment file must have mode 600.')
    env = dict(line.split('=', 1) for line in args.env.read_text().splitlines()
               if line and not line.startswith('#') and '=' in line)
    host = env['TERMINOLOGY_API_HOST']
    if not re.fullmatch(r'[a-zA-Z0-9.-]+', host):
        parser.error('Invalid deployment hostname.')
    base = 'https://' + host
    opener = urllib.request.build_opener(NoRedirect())

    def api(path, data=None, content_type='application/json'):
        request = urllib.request.Request(base + path, data=data, headers={
            'Authorization': 'Token ' + env['TERMINOLOGY_ADMIN_TOKEN'],
            'Content-Type': content_type, 'Accept': 'application/json',
        })
        with opener.open(request, timeout=120) as response:
            return json.load(response)

    manifest_bytes = (args.catalogs / 'manifest.json').read_bytes()
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    manifest = json.loads(manifest_bytes)
    journal_path = args.catalogs / 'journal.json'
    profile = api('/user/')
    if profile.get('username') != 'ocladmin' or not profile.get('is_superuser'):
        raise RuntimeError('Expected the bootstrap administrator for the initial migration.')
    if journal_path.exists():
        journal = json.loads(journal_path.read_text())
        if journal['manifest_sha256'] != manifest_hash or journal['api'] != base:
            raise RuntimeError('Migration journal belongs to a different manifest or server.')
    else:
        try:
            sources = api('/orgs/SIHSALUS/sources/?limit=1')
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            sources = []
        if sources:
            raise RuntimeError('Initial migration requires empty SIHSALUS sources.')
        journal = {'manifest_sha256': manifest_hash, 'api': base, 'batches': {}}

    def save():
        temporary = journal_path.with_suffix('.partial')
        temporary.write_text(json.dumps(journal, indent=2) + '\n')
        temporary.replace(journal_path)

    completed = 0
    for position, batch in enumerate(manifest['batches'], start=1):
        filename = batch['file']
        state = journal['batches'].get(filename)
        if state and state.get('accepted'):
            continue
        if args.limit and completed >= args.limit:
            break
        if not state and (args.catalogs / 'PAUSE').exists():
            print('Pause requested; no further batch submitted.', flush=True)
            break
        raw = (args.catalogs / filename).read_bytes()
        if hashlib.sha256(raw).hexdigest() != batch['sha256']:
            raise RuntimeError('Prepared batch checksum mismatch: ' + filename)
        if not state:
            state = {'submitted_at': time.time(), 'task': None}
            journal['batches'][filename] = state
            save()
            boundary = 'terminology-' + uuid.uuid4().hex
            body = (
                f'--{boundary}\r\nContent-Disposition: form-data; name="parallel"\r\n\r\n{args.parallel}\r\n'
                f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="export.zip"\r\n'
                'Content-Type: application/zip\r\n\r\n'
            ).encode() + raw + f'\r\n--{boundary}--\r\n'.encode()
            response = api('/importers/bulk-import/?update_if_exists=false&index=true', body,
                           'multipart/form-data; boundary=' + boundary)
            state['task'] = response.get('task') or response['id']
            save()
        if not state['task']:
            raise RuntimeError('Submission outcome unknown; reconcile server tasks before resuming ' + filename)
        deadline = time.monotonic() + 3600
        while time.monotonic() < deadline:
            response = api('/importers/bulk-import/?task=' + urllib.parse.quote(state['task']) + '&result=json')
            if response['state'] in ('SUCCESS', 'FAILURE', 'REVOKED'):
                break
            time.sleep(5)
        else:
            raise RuntimeError('Task still running; resume using its saved ID: ' + state['task'])
        (args.catalogs / (filename + '.result.json')).write_text(json.dumps(response, indent=2, default=str))
        report = response.get('report') or {}
        failed = any(report.get(key) for key in ('failed', 'invalid', 'exception', 'unknown', 'permission_denied'))
        if response['state'] != 'SUCCESS' or failed or report.get('processed') != report.get('total') or not report:
            raise RuntimeError('Batch needs reconciliation; inspect its private result: ' + filename)
        state['accepted'] = True
        state['report'] = report
        save()
        completed += 1
        print(f"Accepted {position}/{len(manifest['batches'])}: {batch['source']} {batch['kind']} {batch['count']}", flush=True)
    print('Draft loading stopped at the requested boundary. Publication and reconciliation remain separate.', flush=True)


if __name__ == '__main__':
    main()
