#!/usr/bin/env python3
"""Check the runner's kernel compile and pack what the project machine needs to link it (xnu-kernel.yml, step 5).

The kernel link on the runner is a record (kernel/record-link.sh): it is expected to stop on undefined symbols, the ones
the corecrypto and source storage archives define on the project machine. This script refuses the run when
  - no kernel link was attempted (the compile failed earlier: the log's error lines are printed),
  - the link stopped for any reason other than undefined symbols,
  - an object the link names is missing or is not an arm64e Mach-O object.
It packs, under <out>:
  xnu-objects.tar.gz   obj/<path under BUILD/obj>  every object of the link, link.filelist (paths made relative),
                       all-alias.exp, symbolsets.plist, the .LDFLAGS of this build (for comparison only);
                       lib/libfirehose_kernel.a, lib/libpthread_kext.a (built here from Apple's open source)
  link-record.json     the link's arguments with the runner's paths replaced by @OBJ@ / @XNU@ / @KSDK@ / @XCODE@
  undefined.txt        the symbols the project machine's archives must define
  manifest.json        SHA-256 of every packed file, the toolchain, the pins, the series' SHA-256
  build-errors.txt     the compiler's error lines, if any (BUILD_WERROR=0: warnings are not errors here)
Nothing else is packed: no Xcode file (the stand-in -lcc_kext stays behind), no SDK file, no source.
"""
import argparse, hashlib, json, os, re, shutil, struct, subprocess, sys, tarfile
from pathlib import Path

ap = argparse.ArgumentParser()
for name in ('xnu', 'record', 'log', 'sdk-lib', 'pins', 'series', 'out'):
    ap.add_argument('--' + name, required=True)
a = ap.parse_args()
xnu, out, sdk_lib = Path(a.xnu), Path(a.out), Path(a.sdk_lib)
objroot = xnu / 'BUILD' / 'obj'
out.mkdir(parents=True, exist_ok=True)
log = Path(a.log).read_text(errors='replace').splitlines()
errors = [l for l in log if re.search(r'(^|\s)error: ', l) and 'linker command failed' not in l]
(out / 'build-errors.txt').write_text('\n'.join(errors) + '\n')
rec_path = Path(a.record)
if not rec_path.exists():
    print('\n'.join(log[-60:]))
    sys.exit('REFUSED: no kernel link was attempted; the compile stopped first (%d error lines, build-errors.txt)' % len(errors))
rec = json.loads(rec_path.read_text())
cwd = Path(rec['cwd'])
stderr = '\n'.join(rec['stderr_tail'])
if rec['status'] != 0:
    other = [l for l in rec['stderr_tail'] if l.startswith('ld: ') and 'symbol(s) not found' not in l
             and not l.startswith('ld: warning')]
    if other or not rec['undefined']:
        print(stderr)
        sys.exit('REFUSED: the kernel link stopped for another reason than undefined symbols')
print('kernel link: status %d, %d undefined symbols (the project machine\'s archives)' % (rec['status'], len(rec['undefined'])))

def macho_arm64e(p):
    h = p.read_bytes()[:12]
    if len(h) < 12 or h[:4] != b'\xcf\xfa\xed\xfe':
        return False
    cputype, subtype = struct.unpack('<ii', h[4:12])
    return cputype == 0x0100000C and (subtype & 0xff) == 2

objects = [Path(l.strip()) for l in (cwd / 'link.filelist').read_text().splitlines() if l.strip()]
objects += [cwd / x if not os.path.isabs(x) else Path(x) for x in rec['argv'] if x.endswith('.o')]
bad = [str(o) for o in objects if not o.is_file() or not macho_arm64e(o)]
if bad:
    sys.exit('REFUSED: %d link objects missing or not arm64e: %s' % (len(bad), ', '.join(bad[:10])))
outside = [str(o) for o in objects if objroot.resolve() not in o.resolve().parents]
if outside:
    sys.exit('REFUSED: link objects outside BUILD/obj: %s' % ', '.join(outside[:10]))
extras = [cwd / n for n in ('all-alias.exp', 'symbolsets.plist', '.LDFLAGS')]
libs = [sdk_lib / 'libfirehose_kernel.a', sdk_lib / 'libpthread_kext.a']

stage = out / 'stage'
shutil.rmtree(stage, ignore_errors=True)
files = {}
def put(src, rel):
    dst = stage / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    files[rel] = hashlib.sha256(dst.read_bytes()).hexdigest()
for o in sorted(set(objects)):
    put(o, 'obj/' + o.resolve().relative_to(objroot.resolve()).as_posix())
for e in extras:
    if e.is_file():
        put(e, 'obj/' + e.resolve().relative_to(objroot.resolve()).as_posix())
for l in libs:
    put(l, 'lib/' + l.name)
target_rel = cwd.resolve().relative_to(objroot.resolve()).as_posix()
filelist = '\n'.join('@OBJ@/' + Path(l.strip()).resolve().relative_to(objroot.resolve()).as_posix()
                     for l in (cwd / 'link.filelist').read_text().splitlines() if l.strip()) + '\n'
(stage / 'obj' / target_rel / 'link.filelist').write_text(filelist)
files['obj/%s/link.filelist' % target_rel] = hashlib.sha256(filelist.encode()).hexdigest()

xcode = os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer').rsplit('/Contents/Developer', 1)[0]
ksdk = str(sdk_lib.parents[3])
def portable(s):
    for prefix, tag in ((str(objroot.resolve()), '@OBJ@'), (str(objroot), '@OBJ@'), (str(xnu.resolve()), '@XNU@'),
                        (str(xnu), '@XNU@'), (ksdk, '@KSDK@'), (xcode, '@XCODE@')):
        s = s.replace(prefix, tag)
    return s
record = dict(target='@OBJ@/' + target_rel, argv=[portable(x) for x in rec['argv']],
              loaded=[portable(x) for x in rec['loaded']], status=rec['status'], undefined=rec['undefined'])
(out / 'link-record.json').write_text(json.dumps(record, indent=1) + '\n')
(out / 'undefined.txt').write_text('\n'.join(rec['undefined']) + '\n')
leaks = [x for x in record['argv'] + record['loaded'] if '/Users/' in x and '@' not in x[:1]]
if leaks:
    print('note: runner paths left in the record (not under the build, the SDK or Xcode): %s' % leaks[:5])

with tarfile.open(out / 'xnu-objects.tar.gz', 'w:gz') as t:
    t.add(stage, arcname='.')
shutil.rmtree(stage)

def run(*c):
    try:
        return subprocess.run(c, capture_output=True, text=True).stdout.strip() or 'unknown'
    except OSError:
        return 'unknown'
manifest = dict(
    series=Path(a.series).name, series_sha256=hashlib.sha256(Path(a.series).read_bytes()).hexdigest(),
    pins=json.loads(Path(a.pins).read_text())['sources'],
    xcode=run('xcodebuild', '-version').replace('\n', ' '), clang=run('xcrun', '--sdk', 'iphoneos', 'clang', '--version').splitlines()[0],
    iphoneos_sdk=run('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'), files=files,
    tarball_sha256=hashlib.sha256((out / 'xnu-objects.tar.gz').read_bytes()).hexdigest(),
    link_status=rec['status'], undefined=len(rec['undefined']), compiler_error_lines=len(errors))
(out / 'manifest.json').write_text(json.dumps(manifest, indent=1) + '\n')
size = (out / 'xnu-objects.tar.gz').stat().st_size
print('PASS: %d objects, %d files packed, tarball %d bytes sha256 %s' % (len(set(objects)), len(files), size,
                                                                          manifest['tarball_sha256'][:16]))
