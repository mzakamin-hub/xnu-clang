#!/usr/bin/env python3
"""Refuse a kernel patch series that holds anything this public repository must never carry.

    rule-gate.py SERIES.patch [--forbid FILE]

Checked on every line the series ADDS, and on every path it touches. A refusal names the file and line. Refused:
  path      anything under BUILD/ (a build tree: objects, logs, a linked kernel), backup files (*.bak-*, *.orig, *.rej)
  binary    a binary patch (GIT binary patch / Binary files differ)
  key       PEM blocks, "PRIVATE KEY", base64 runs of 120+ characters, hex runs of 256+ digits
  blob      byte arrays of 512+ 0xNN items in one run (firmware-sized; register tables and digests are far smaller)
  address   MAC / BD addresses written aa:bb:cc:dd:ee:ff (other than all-zero or broadcast prefixes)
  path-id   personal paths: /home/<user>, /Users/<user>, /mnt/<drive>/, C:\\Users
  mail      e-mail addresses other than the allow-listed domains of third-party code authors
  uuid      UUID literals other than the public ones below and this repository's placeholders (pins.json)
  forbid    any string of the --forbid file (the project machine's list of real unit identifiers; never committed)
  size      a series over 16 MiB
Exit 0 with a one-line PASS, or 1 with every refusal printed.
"""
import argparse, json, re, sys
from pathlib import Path

PUBLIC_UUIDS = {
    '7A23BAC7-E86D-4DF4-B181-E6D80F212AE5',   # UniXNU's iPadOS root default (kern_exec.c fallback)
    '84581E99-85BE-4957-AC53-2947E887B3E4',   # UniXNU macos-27.3-26C5035r profile: boot-uuid
    '6678E466-2F88-4C56-9408-DC7361BAA0BA',   # UniXNU macos-27.3-26C5035r profile: systemos_volume_uuid
}
MAIL_OK = re.compile(r'@(apple\.com|corellium\.com|users\.noreply\.github\.com|example\.(com|org))\b', re.I)
rx = [
    ('key', re.compile(r'-----BEGIN [A-Z ]+-----|PRIVATE KEY|(?<![A-Za-z0-9+/_])[A-Za-z0-9+/]{120,}={0,2}|\b[0-9a-fA-F]{256,}\b')),
    ('address', re.compile(r'\b(?!00:00:00)(?!ff:ff:ff)(?!FF:FF:FF)[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b')),
    ('path-id', re.compile(r'/home/[a-z_][a-z0-9_-]*/|/Users/(?!Shared/)[A-Za-z][A-Za-z0-9._-]*/|/mnt/[a-z]/|[Cc]:\\\\?Users')),
]
mail = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
uuid = re.compile(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b')
hexitem = re.compile(r'0x[0-9a-fA-F]{2}\b')
badpath = re.compile(r'(^|/)BUILD/|\.bak-|\.orig$|\.rej$')

ap = argparse.ArgumentParser()
ap.add_argument('series')
ap.add_argument('--forbid')
a = ap.parse_args()
here = Path(__file__).resolve().parent
allowed = set(PUBLIC_UUIDS)
pins = here / 'pins.json'
if pins.exists():
    for v in json.loads(pins.read_text()).get('placeholders', {}).values():
        if isinstance(v, dict) and uuid.fullmatch(v.get('text', '')):
            allowed.add(v['text'].upper())
forbid = []
if a.forbid:
    forbid = [l.strip() for l in Path(a.forbid).read_text().splitlines() if l.strip() and not l.startswith('#')]
data = Path(a.series).read_bytes()
refusals = []
if len(data) > 16 << 20:
    refusals.append(('size', '-', 0, '%d bytes' % len(data)))
f, run, run_at, added, files = '-', 0, 0, 0, set()
def flush():
    global run
    if run >= 512:
        refusals.append(('blob', f, run_at, '%d byte items in one run' % run))
    run = 0
for n, line in enumerate(data.decode('utf-8', errors='replace').splitlines(), 1):
    if line.startswith('diff --git '):
        flush()
        parts = line.split(' ')
        for p in parts[2:4]:
            if badpath.search(p[2:]):
                refusals.append(('path', p[2:], n, 'build tree or backup file'))
        f = parts[-1][2:]; files.add(f)
        continue
    if line.startswith('GIT binary patch') or (line.startswith('Binary files') and line.endswith('differ')):
        refusals.append(('binary', f, n, line[:80])); continue
    if not line.startswith('+') or line.startswith('+++ '):
        flush(); continue
    body = line[1:]; added += 1
    k = len(hexitem.findall(body))
    if k >= 4:
        if run == 0: run_at = n
        run += k
    else:
        flush()
    for cat, r in rx:
        m = r.search(body)
        if m: refusals.append((cat, f, n, m.group(0)[:60]))
    for m in mail.findall(body):
        if not MAIL_OK.search(m): refusals.append(('mail', f, n, m))
    for u in uuid.findall(body):
        if u.upper() not in allowed: refusals.append(('uuid', f, n, u))
    for s in forbid:
        if s.lower() in body.lower(): refusals.append(('forbid', f, n, '(a listed unit identifier)'))
flush()
if refusals:
    for cat, f, n, what in refusals[:200]:
        print('REFUSED %-8s %s:%s  %s' % (cat, f, n, what))
    print('rule gate: %d refusals in %s (%d files, %d added lines)' % (len(refusals), a.series, len(files), added))
    sys.exit(1)
print('rule gate PASS: %s, %d files, %d added lines, %d bytes' % (a.series, len(files), added, len(data)))
