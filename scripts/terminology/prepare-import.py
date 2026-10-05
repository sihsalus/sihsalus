#!/usr/bin/env python3
"""Prepare bounded OCL draft imports from an immutable sihsalus-content revision.

Concepts precede mappings across all sources. Publication is a separate operation
after persisted codes, external IDs and counts have been reconciled.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
from zipfile import ZipFile, ZIP_DEFLATED


def digest(value):
    """Hash bytes without changing their representation."""
    return hashlib.sha256(value).hexdigest()


def prepare(repo, revision, output, batch_size):
    """Read committed catalog exports only; never alter the content checkout."""
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args])

    sha = git('rev-parse', '--verify', revision + '^{commit}').decode().strip()
    paths = git('ls-tree', '-r', '--name-only', sha, 'configuration/ocl').decode().splitlines()
    paths = [path for path in paths if path.endswith('.zip')]
    if not paths:
        raise ValueError('No committed OCL exports found.')
    output.mkdir(parents=True, exist_ok=False)
    sources = {}
    batches = []
    for path in paths:
        raw = git('show', sha + ':' + path)
        with ZipFile(io.BytesIO(raw)) as archive:
            if len(archive.namelist()) != 1:
                raise ValueError('Expected one export document in ' + path)
            export = json.loads(archive.read(archive.namelist()[0]))
        source = export['source']
        if export['type'] != 'Source Version' or source['owner'] != 'SIHSALUS':
            raise ValueError('Unexpected catalog type or owner in ' + path)
        name = source['short_code']
        entry = sources.setdefault(name, {
            'owner': source['owner'], 'source': name, 'version': export['version'],
            'released': export.get('released', False), 'version_description': export.get('description'),
            'concepts': [], 'mappings': [], 'inputs': [],
        })
        if entry['version'] != export['version']:
            raise ValueError('Multiple versions require explicit ordering: ' + name)
        entry['inputs'].append({'path': path, 'sha256': digest(raw)})
        for kind in ('concepts', 'mappings'):
            records = export.get(kind, [])
            entry[kind].extend(records)
            for start in range(0, len(records), batch_size):
                # OCL's supported export converter omits publication for HEAD.
                draft = {'type': 'Source Version', **export, 'version': 'HEAD',
                         'released': False, 'concepts': [], 'mappings': []}
                draft[kind] = records[start:start + batch_size]
                filename = f'{Path(path).stem}-{kind}-{start:06d}.zip'
                target = output / filename
                with ZipFile(target, 'w', ZIP_DEFLATED) as archive:
                    archive.writestr('export.json', json.dumps(draft, ensure_ascii=False))
                batches.append({'file': filename, 'sha256': digest(target.read_bytes()),
                                'source': name, 'kind': kind, 'count': len(draft[kind])})
    for entry in sources.values():
        for kind in ('concepts', 'mappings'):
            records = entry[kind]
            ids = [str(record['id']) for record in records]
            if len(set(ids)) != len(ids):
                raise ValueError('Duplicate codes in ' + entry['source'] + '/' + kind)
            # Preserve expected records for post-import reconciliation, outside Git.
            filename = f"expected-{entry['source']}-{kind}.json"
            raw = json.dumps(records, ensure_ascii=False, sort_keys=True).encode()
            (output / filename).write_bytes(raw)
            entry[kind] = {'count': len(records), 'file': filename, 'sha256': digest(raw)}
    batches.sort(key=lambda item: (item['kind'] != 'concepts', item['file']))
    manifest = {'content_commit': sha, 'batch_size': batch_size,
                'sources': list(sources.values()), 'batches': batches}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f"Prepared {len(sources)} catalogs in {len(batches)} draft batches from {sha}.")


def main():
    """Explicit output prevents overwriting an earlier migration or its evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--batch-size', type=int, default=500)
    args = parser.parse_args()
    if not 1 <= args.batch_size <= 500:
        parser.error('batch-size must be between 1 and 500 for this deployment')
    prepare(args.repo, args.ref, args.output, args.batch_size)


if __name__ == '__main__':
    main()
