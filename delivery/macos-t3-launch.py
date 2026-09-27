"""Protocol-1 native launcher; preserve stdin/stdout and replace this process."""
import json
import os
from pathlib import Path
import sys

try:
    path = Path(sys.argv[1])
    config = json.loads(path.read_text(encoding='utf-8'))
    if config['schemaVersion'] != 1:
        raise ValueError('protocol')
    os.execv(config['node'], [config['node'], config['script'], '--bridge-config', str(path), *sys.argv[2:]])
except (OSError, ValueError, KeyError, IndexError):
    sys.stderr.write('HotPl8: routing_delivery_invalid\n')
    sys.exit(1)
