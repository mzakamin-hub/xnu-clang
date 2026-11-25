# xnu clang

Compiles a patched XNU (`xnu-12377.121.6`, Apple open source) with **Xcode's clang** on GitHub's macOS runner, for the
`iceland` macOS port (OnePlus Pad 4, SM8850), the way UniXNU's sheng port builds its kernel (Xcode 26.6, macos-26).

- **Inputs, all public:** Apple's open-source repositories at the exact commits in `kernel/pins.json`, plus our patch
  series `kernel/series/<series>.patch` (source changes only).
- **Only the compile runs here.** The kernel is linked elsewhere with inputs that never come to this repository
  (cryptography and storage archives, firmware objects). The link step here is expected to stop on those symbols;
  `kernel/collect.py` checks that this is the only reason.
- **Gate:** `kernel/rule-gate.py` refuses a series that carries a build tree, a binary patch, key material, a
  firmware-sized byte array, an address, a personal path or an unknown UUID. Three unit identifiers are placeholders.
- **Runs:** `workflow_dispatch` only (`gh workflow run xnu-clang.yml -f series=k1 -f xcode=26.6`); artifacts are kept 1 day.

Licences: changes to XNU and other Apple open-source files are under the Apple Public Source License 2.0, as the files
they change. Our own new files carry their own licence headers (one third-party file, libzbitmap, is used under MIT).
