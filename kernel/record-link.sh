#!/usr/bin/env bash
# LD for the kernel build on the runner (xnu's LD is "$(KC++) -nostdlib"). Every call is passed to Xcode's clang++
# unchanged. The kernel link (-o .../mach.<config>.unstripped.noctf) is also recorded in $ICE_LINK_RECORD: its working
# directory, its arguments and the linker's own list of the files it loaded (-Wl,-t), and the undefined symbols when it
# stops, so the project machine can repeat exactly this link with the inputs that never leave it.
set -u
cxx=$(xcrun --sdk iphoneos -f clang++)
is_kernel=0
for a in "$@"; do case "$a" in */mach.*.unstripped.noctf) is_kernel=1 ;; esac; done
if [ "$is_kernel" = 0 ] || [ -z "${ICE_LINK_RECORD:-}" ]; then
    exec "$cxx" -nostdlib "$@"
fi
trace="$ICE_LINK_RECORD.trace"; err="$ICE_LINK_RECORD.stderr"
"$cxx" -nostdlib "$@" -Wl,-t > "$trace" 2> "$err"
status=$?
python3 -I - "$ICE_LINK_RECORD" "$status" "$PWD" "$trace" "$err" "$@" <<'PY'
import json, re, sys
out, status, cwd, trace, err = sys.argv[1:6]
argv = sys.argv[6:]
text = open(err, errors='replace').read()
undefined = sorted(set(re.findall(r'^\s+"([^"]+)", referenced from:', text, re.M)))
loaded = [l.strip() for l in open(trace, errors='replace') if l.strip() and not l.startswith('ld:')]
json.dump(dict(cwd=cwd, argv=argv, status=int(status), loaded=loaded, undefined=undefined,
               stderr_tail=text.splitlines()[-60:]), open(out, 'w'), indent=1)
PY
cat "$err" >&2
exit $status
