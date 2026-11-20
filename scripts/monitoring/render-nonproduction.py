#!/usr/bin/env python3
"""Generate non-secret monitoring configurations for DEV, QLTY or an observer."""
import argparse
import json
from pathlib import Path
import re

TARGETS = {
    'dev': ('https://gidis-hsc-dev.inf.pucp.edu.pe', '700e430a-1c32-5241-b7cf-78ccea17f8c1'),
    'qlty': ('https://gidis-hsc-qlty.inf.pucp.edu.pe', '0cefb0c8-c860-48c5-856f-408594775cbb'),
}


def configuration(environment, sender, recipient):
    if environment not in (*TARGETS, 'observer'):
        raise ValueError('Unsupported environment')
    for address in (sender, recipient):
        if not re.fullmatch(r'[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', address):
            raise ValueError('Use one valid mailbox per address')
    jobs = [{'job_name': 'prometheus', 'static_configs': [{'targets': ['localhost:9090']}]},
            {'job_name': 'alertmanager', 'static_configs': [{'targets': ['alertmanager:9093']}]}]
    if environment != 'observer':
        jobs += [{'job_name': name, 'static_configs': [{'targets': [target]}]}
                 for name, target in [('node-exporter', 'node-exporter:9100'), ('cadvisor', 'cadvisor:8080')]]
    for name in (TARGETS if environment == 'observer' else [environment]):
        base, node = TARGETS[name]
        for kind, endpoint in [('ready', '/ready'), ('identity', '/openmrs/spa/build-info.json')]:
            jobs.append({'job_name': 'sihsalus-' + name + '-' + kind, 'metrics_path': '/probe',
                         'params': {'module': ['http_2xx_verified' if kind == 'ready' else 'http_' + name + '_identity']},
                         'static_configs': [{'targets': [base + endpoint], 'labels': {'environment': name, 'check': kind}}],
                         'relabel_configs': [
                             {'source_labels': ['__address__'], 'target_label': '__param_target'},
                             {'source_labels': ['__param_target'], 'target_label': 'instance'},
                             {'target_label': '__address__', 'replacement': 'blackbox:9115'}]})
    prometheus = {'global': {'scrape_interval': '1m', 'evaluation_interval': '1m',
                            'external_labels': {'cluster': 'sihsalus-' + environment, 'environment': environment}},
                  'rule_files': ['/etc/prometheus/alerts/*.yml'],
                  'alerting': {'alertmanagers': [{'static_configs': [{'targets': ['alertmanager:9093']}]}]},
                  'scrape_configs': jobs}
    alertmanager = {'global': {'resolve_timeout': '5m', 'smtp_smarthost': 'smtp.gmail.com:587',
                              'smtp_from': 'SIHSalus <' + sender + '>', 'smtp_auth_username': sender,
                              'smtp_auth_password_file': '/run/secrets/smtp-password', 'smtp_require_tls': True},
                    'route': {'receiver': 'sihsalus-ia', 'group_by': ['environment', 'alertname', 'instance'],
                              'group_wait': '30s', 'group_interval': '5m', 'repeat_interval': '4h'},
                    'receivers': [{'name': 'sihsalus-ia', 'email_configs': [{'to': recipient, 'send_resolved': True}]}],
                    'inhibit_rules': [{'source_matchers': ['alertname="HostFilesystemSpaceCritical"'],
                                       'target_matchers': ['alertname="HostFilesystemSpaceLow"'],
                                       'equal': ['environment', 'instance', 'mountpoint']}]}
    return {'prometheus.json': prometheus, 'alertmanager.json': alertmanager}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', choices=[*TARGETS, 'observer'], required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--sender', default='sihsalus@gmail.com')
    parser.add_argument('--recipient', default='sih.salus.ia-grupo@pucp.edu.pe')
    args = parser.parse_args()
    configs = configuration(args.environment, args.sender, args.recipient)
    args.output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, content in configs.items():
        path = args.output_dir / name
        if path.exists() or path.is_symlink():
            raise SystemExit('Refusing to overwrite an existing monitoring configuration: ' + name)
    for name, content in configs.items():
        path = args.output_dir / name
        with path.open('x') as file:
            json.dump(content, file, indent=2)
            file.write('\n')
        # Configs contain no credential. The SMTP secret is a separate private mount.
        path.chmod(0o644)
    print('Generated configurations for ' + args.environment + '; SMTP credential not included.')


if __name__ == '__main__':
    main()
