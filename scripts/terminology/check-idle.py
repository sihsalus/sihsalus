"""Refuse maintenance if either Celery worker or its broker has unfinished work."""
import os
import sys

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'core.settings')

from core.celery import app  # pylint: disable=wrong-import-position
from redis import Redis  # pylint: disable=wrong-import-position

inspector = app.control.inspect(timeout=5)
for operation in ('active', 'reserved', 'scheduled'):
    replies = getattr(inspector, operation)()
    if not replies or len(replies) != 2 or any(replies.values()):
        print('Maintenance deferred: both workers must respond without pending work.')
        sys.exit(75)

broker = Redis.from_url(app.conf.broker_url, socket_timeout=5, socket_connect_timeout=5)
pending = sum(broker.llen(key) for key in broker.scan_iter(_type='list'))
if pending or broker.hlen('unacked'):
    print('Maintenance deferred: broker work has not been acknowledged.')
    sys.exit(75)
print('Both workers and the broker are idle.')
