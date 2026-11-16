#!/usr/bin/env bash
# Creates ./connection.json with a fresh random pairing key.
#   scripts/new-pairing.sh 192.168.1.20
# MacIP is only a discovery hint; the sender finds the Mac by authenticated UDP broadcast.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "Использование: scripts/new-pairing.sh <IP Mac в локальной сети>" >&2; exit 1; }
[ ! -e connection.json ] || { echo "connection.json уже есть. Удалите его, если нужна новая пара." >&2; exit 1; }
python3 -I - "$1" <<'PY'
import base64, json, secrets, sys
from pathlib import Path
config = {'MacIP': sys.argv[1], 'Port': 49152,
          'Key': base64.b64encode(secrets.token_bytes(32)).decode(),
          'DownloadToken': secrets.token_hex(8)}
Path('connection.json').write_text(json.dumps(config, indent=2))
PY
chmod 600 connection.json
echo "Создан connection.json. Не публикуйте его: в нём ключ пары."
