#!/usr/bin/env python3
"""Patch only the existing /tmp Douyin test copy's preload entry.

The caller must re-sign the test bundle afterwards. This script never starts apps.
The installed original is read only, for identity/backup verification.
"""
from pathlib import Path
import hashlib
import json
import os
import struct

ROOT = Path('/tmp/ProxyLauncher-Douyin-4K-Test')
ARCHIVE = ROOT / 'douyin.app/Contents/Resources/app.asar'
ORIGINAL = Path('/Applications/douyin.app/Contents/Resources/app.asar')
# 补丁源码现在在 Sources/ 下（已并入主程序，这里只用于实验期的临时副本）
PATCH = Path(__file__).resolve().parent.parent / 'Sources' / 'douyin-hq-preload.js'
BACKUP = ROOT / 'app.asar.before-h266-test'


def unpack(data):
    if len(data) < 16 or struct.unpack_from('<I', data)[0] != 4:
        raise ValueError('Unexpected ASAR header')
    header_size = struct.unpack_from('<I', data, 4)[0]
    json_size = struct.unpack_from('<I', data, 12)[0]
    if 16 + json_size > 8 + header_size:
        raise ValueError('ASAR header length mismatch')
    return json.loads(data[16:16 + json_size]), data[8 + header_size:]


def get_file(header, payload, entry):
    item = header['files'][entry]
    offset, size = int(item['offset']), item['size']
    if offset < 0 or offset + size > len(payload):
        raise ValueError('ASAR entry outside payload')
    return payload[offset:offset + size]


def digest(data):
    return hashlib.sha256(data).hexdigest()


original = ORIGINAL.read_bytes()
if not BACKUP.exists():
    current = ARCHIVE.read_bytes()
    if current != original:
        raise SystemExit('Refusing to back up an already modified test archive')
    BACKUP.write_bytes(current)
backup = BACKUP.read_bytes()
if backup != original:
    raise SystemExit('Installed app differs from the stored baseline; rebuild the test copy')
header, payload = unpack(backup)
preload = get_file(header, payload, 'preload.js')
patch = PATCH.read_bytes()
new_preload = patch + b'\n' + preload
entry = header['files']['preload.js']
entry['offset'] = str(len(payload))
entry['size'] = len(new_preload)
block_size = 4 * 1024 * 1024
entry['integrity'] = {
    'algorithm': 'SHA256', 'hash': digest(new_preload), 'blockSize': block_size,
    'blocks': [digest(new_preload[i:i + block_size]) for i in range(0, len(new_preload), block_size)],
}
# Keep every other entry and byte of the original payload unchanged. The old,
# unreferenced preload bytes remain in place; the replacement is appended.
payload += new_preload
encoded = json.dumps(header, ensure_ascii=False, separators=(',', ':')).encode()
string_data = struct.pack('<I', len(encoded)) + encoded
string_data += b'\0' * ((-len(string_data)) % 4)
header_pickle = struct.pack('<I', len(string_data)) + string_data
result = struct.pack('<II', 4, len(header_pickle)) + header_pickle + payload
new_header, new_payload = unpack(result)
old_header, old_payload = unpack(backup)
assert get_file(new_header, new_payload, 'preload.js') == new_preload
assert new_payload[:len(old_payload)] == old_payload
for key, value in old_header['files'].items():
    if key != 'preload.js':
        assert new_header['files'][key] == value, key
assert ORIGINAL.read_bytes() == original
staging = ARCHIVE.with_name('app.asar.h266-staging')
staging.write_bytes(result)
os.replace(staging, ARCHIVE)
(ROOT / 'h266-patch-manifest.json').write_text(json.dumps({
    'original_sha256': digest(original), 'patched_sha256': digest(result),
    'patch_sha256': digest(patch), 'changed_entry': 'preload.js',
    'backup': str(BACKUP), 'app_started': False,
}, indent=2) + '\n')
print('Patched test copy preload only:', ARCHIVE)
print('Original unchanged:', digest(original))
