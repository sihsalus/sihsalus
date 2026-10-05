#!/usr/bin/env python3
"""Compare server exports with the immutable catalog records before publication."""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request
from zipfile import ZipFile


# Stable fields supported by SourceDetailSerializer. Database IDs, timestamps,
# generated checksums and computed counts belong to the destination server.
SOURCE_FIELDS = (
    'name', 'full_name', 'description', 'source_type', 'custom_validation_schema',
    'public_access', 'default_locale', 'supported_locales', 'website', 'extras',
    'external_id', 'canonical_url', 'identifier', 'publisher', 'contact',
    'jurisdiction', 'purpose', 'copyright', 'content_type', 'revision_date',
    'text', 'experimental', 'case_sensitive', 'collection_reference',
    'hierarchy_meaning', 'compositional', 'version_needed', 'hierarchy_root_url',
    'meta', 'properties', 'filters', 'match_algorithms',
    'autoid_concept_mnemonic', 'autoid_concept_external_id',
    'autoid_concept_name_external_id', 'autoid_concept_description_external_id',
    'autoid_mapping_mnemonic', 'autoid_mapping_external_id',
    'autoid_concept_mnemonic_start_from', 'autoid_concept_external_id_start_from',
    'autoid_mapping_mnemonic_start_from', 'autoid_mapping_external_id_start_from',
)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep API credentials out of signed storage requests."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def project(record, fields):
    """Compare stable clinical identity and content, excluding local database IDs."""
    return {field: record.get(field) for field in fields}


def source_metadata(record):
    """Omit only OCL's generated export duration; preserve every catalog extra."""
    result = project(record, SOURCE_FIELDS)
    if isinstance(result['extras'], dict):
        result['extras'] = {key: value for key, value in result['extras'].items() if key != '__export_time'}
    return result


def locales(records, text, kind):
    """Locale order may change; text, external UUIDs and retirement must not."""
    fields = (text, kind, 'locale', 'locale_preferred', 'external_id', 'retired', 'retire_reason')
    return sorted(json.dumps(project(record, fields), sort_keys=True) for record in records)


def compare(expected, actual, kind):
    """Require exactly the expected codes and stable fields in each exported record."""
    index = {str(record['id']): record for record in actual}
    if len(index) != len(actual) or set(index) != {str(record['id']) for record in expected}:
        raise ValueError(kind + ': missing, duplicate or unexpected codes')
    fields = ('external_id', 'retired', 'retire_reason', 'extras')
    fields += ('concept_class', 'datatype') if kind == 'concepts' else (
        'map_type', 'sort_weight', 'from_concept_code', 'to_concept_code',
        'from_source_url', 'to_source_url', 'from_source_version', 'to_source_version',
        'from_concept_name', 'to_concept_name',
    )
    for original in expected:
        saved = index[str(original['id'])]
        for field in fields:
            if original.get(field) != saved.get(field):
                raise ValueError(f'{kind}/{original["id"]}: {field} differs')
        if kind == 'concepts':
            if sorted(original.get('parent_concept_urls') or []) != sorted(saved.get('parent_concept_urls') or []):
                raise ValueError(f'concepts/{original["id"]}: parent relationships differ')
            for key, text, label_type in (('names', 'name', 'name_type'),
                                          ('descriptions', 'description', 'description_type')):
                if locales(original.get(key) or [], text, label_type) != locales(saved.get(key) or [], text, label_type):
                    raise ValueError(f'concepts/{original["id"]}: {key} differ')


def main():
    """Export one catalog at a time and retain hashes of the compared snapshots."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', type=Path, required=True)
    parser.add_argument('--catalogs', type=Path, required=True)
    parser.add_argument('--source', help='Reconcile only this manifest source.')
    parser.add_argument('--published', action='store_true', help='Check the original released version instead of HEAD.')
    parser.add_argument('--restore-source-settings', action='store_true',
                        help='Restore source metadata omitted by ZIP import, after all records have loaded.')
    args = parser.parse_args()
    if args.published and args.restore_source_settings:
        parser.error('Restore source settings before creating the published versions.')
    os.umask(0o077)
    lock_file = (args.catalogs / '.import.lock').open('a')
    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if args.env.stat().st_mode & 0o077:
        parser.error('The private environment file must have mode 600.')
    env = dict(line.split('=', 1) for line in args.env.read_text().splitlines()
               if line and not line.startswith('#') and '=' in line)
    base = 'https://' + env['TERMINOLOGY_API_HOST']
    opener = urllib.request.build_opener(NoRedirect())

    def request(path, method='GET', data=None):
        req = urllib.request.Request(base + path, method=method,
                                     data=json.dumps(data).encode() if data is not None else None, headers={
            'Authorization': 'Token ' + env['TERMINOLOGY_ADMIN_TOKEN'], 'Accept': 'application/json',
            'Content-Type': 'application/json',
        })
        try:
            return opener.open(req, timeout=120)
        except urllib.error.HTTPError as error:
            if error.code == 302:
                return error
            raise

    manifest_bytes = (args.catalogs / 'manifest.json').read_bytes()
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    manifest = json.loads(manifest_bytes)
    journal = json.loads((args.catalogs / 'journal.json').read_text())
    if journal['manifest_sha256'] != manifest_hash or journal['api'] != base:
        raise ValueError('Migration journal does not match this manifest and API.')
    selected = [source for source in manifest['sources'] if not args.source or source['source'] == args.source]
    if not selected:
        parser.error('No matching source in the manifest.')
    names = {source['source'] for source in selected}
    if any(not journal['batches'].get(batch['file'], {}).get('accepted')
           for batch in manifest['batches'] if batch['source'] in names):
        raise ValueError('All selected concept and mapping batches must be accepted first.')
    output = args.catalogs / ('reconciled-published' if args.published else 'reconciled-head')
    output.mkdir(mode=0o700, exist_ok=True)
    report_path = output / 'report.json'
    report = {'manifest_sha256': manifest_hash, 'api': base, 'sources': {}}
    if report_path.exists():
        report = json.loads(report_path.read_text())
        if report['manifest_sha256'] != manifest_hash or report['api'] != base:
            raise ValueError('Reconciliation report belongs to a different migration.')
    for source in selected:
        version = source['version'] if args.published else 'HEAD'
        source_path = '/orgs/SIHSALUS/sources/' + urllib.parse.quote(source['source'], safe='') + '/'
        batch = next(item for item in manifest['batches'] if item['source'] == source['source'])
        original = (args.catalogs / batch['file']).read_bytes()
        if hashlib.sha256(original).hexdigest() != batch['sha256']:
            raise ValueError('Source metadata checksum mismatch.')
        with ZipFile(io.BytesIO(original)) as archive:
            expected_source = source_metadata(json.loads(archive.read('export.json'))['source'])
        with request(source_path) as response:
            current_source = json.load(response)
        if (current_source['short_code'] != source['source'] or current_source['owner'] != 'SIHSALUS'
                or current_source['external_id'] != expected_source['external_id']):
            raise ValueError('Source identity differs from the original catalog.')
        differences = {key: value for key, value in expected_source.items()
                       if source_metadata(current_source).get(key) != value}
        if differences and args.restore_source_settings:
            before_path = output / (source['source'] + '-settings-before.json')
            if not before_path.exists():
                before_path.write_text(json.dumps(current_source, indent=2) + '\n')
            with request(source_path, 'PATCH', differences) as response:
                if response.status != 200:
                    raise ValueError('Source settings were not saved.')
            with request(source_path) as response:
                current_source = json.load(response)
            differences = {key: value for key, value in expected_source.items()
                           if source_metadata(current_source).get(key) != value}
        if differences:
            raise ValueError(source['source'] + ': source settings differ: ' + ', '.join(differences))
        path = source_path + urllib.parse.quote(version, safe='') + '/export/'
        # Force a current snapshot; never accept a cached export of an earlier HEAD.
        with request(path + '?noRedirect=true&force=true', 'POST') as response:
            if response.status not in (202, 204, 208):
                raise ValueError('Unexpected export submission status: ' + str(response.status))
        deadline = time.monotonic() + 3600
        while time.monotonic() < deadline:
            with request(path) as response:
                if response.status == 302:
                    signed_url = response.headers['Location']
                    break
                if response.status not in (204, 208):
                    raise ValueError('Unexpected export status: ' + str(response.status))
            time.sleep(5)
        else:
            raise TimeoutError('Export remains pending for ' + source['source'])
        url = urllib.parse.urlsplit(signed_url)
        if (url.scheme != 'https' or url.netloc != env['TERMINOLOGY_HOST']
                or not url.path.startswith('/terminology-exports/')):
            raise ValueError('Export URL does not use the configured HTTPS storage gateway.')
        # This request has no Authorization header and does not follow redirects.
        with opener.open(urllib.request.Request(signed_url), timeout=120) as response:
            raw = response.read()
        with ZipFile(io.BytesIO(raw)) as archive:
            if len(archive.namelist()) != 1:
                raise ValueError('Expected a single export document.')
            exported = json.loads(archive.read(archive.namelist()[0]))
        if (exported['version'] != version or exported['short_code'] != source['source']
                or exported['owner'] != 'SIHSALUS'):
            raise ValueError('Unexpected source or version in export.')
        if args.published and exported.get('released') != source['released']:
            raise ValueError('Published state differs from the original release.')
        if args.published and source_metadata(exported.get('source') or {}) != expected_source:
            raise ValueError('Published source settings differ from the original release.')
        for kind in ('concepts', 'mappings'):
            expected = (args.catalogs / source[kind]['file']).read_bytes()
            if hashlib.sha256(expected).hexdigest() != source[kind]['sha256']:
                raise ValueError('Expected catalog checksum mismatch.')
            compare(json.loads(expected), exported.get(kind) or [], kind)
        (output / (source['source'] + '.zip')).write_bytes(raw)
        report['sources'][source['source']] = {
            'version': version, 'export_sha256': hashlib.sha256(raw).hexdigest(),
            'concepts': len(exported['concepts']), 'mappings': len(exported['mappings']),
            'verified_at': time.time(),
        }
        temporary = report_path.with_suffix('.partial')
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(report_path)
        print(f"Reconciled {source['source']} {version}: {len(exported['concepts'])} concepts, "
              f"{len(exported['mappings'])} mappings.", flush=True)


if __name__ == '__main__':
    main()
