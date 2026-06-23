# `stockfish_init()` file-descriptor leak test

A self-contained, runnable reproducer for the fd leak fixed in
`ios/Classes/stockfish16.cpp` (the same fix applies to the `chess` and
`variant` flavor shims).

## Run it

```sh
# Original (buggy) body -> RESULT: FAIL, exit 1
cc -O0 -Wall fd_leak_test.c -o /tmp/fd_leak && /tmp/fd_leak; echo "exit=$?"

# Shipped fix -> RESULT: PASS, exit 0
cc -O0 -Wall -DFD_LEAK_FIXED fd_leak_test.c -o /tmp/fd_leak && /tmp/fd_leak; echo "exit=$?"
```

Or use the helper, which runs both and checks the exit codes:

```sh
./run.sh
```

## What it checks

- **Experiment A** runs 40 start/quit cycles (`stockfish_init()` followed by
  `stockfish_main()`'s child-end close) and counts open descriptors.
  - original: `~2.00 fds/cycle` → `FAIL`
  - fixed: `+0/cycle` (only the single live pipe pair remains) → `PASS`
- **Experiment B** forces `EMFILE` (by holding descriptors open under a tight
  `RLIMIT_NOFILE`) and checks `stockfish_init()`'s return value.
  - original: returns `0` even though `pipe()` failed — the Dart layer's
    `initResult != 0` guard is blind to the failure.
  - fixed: returns `-1` so the failure surfaces.

## Why this is a logic reproduction, not a link against the real symbol

`stockfish_init()` lives in a translation unit that `#include`s the whole
Stockfish engine (`../Stockfish16/src/*.h`), so it cannot be linked into a small
test without building all of Stockfish. This test therefore exercises the
**exact** pipe/`dup2`/close logic. The `FD_LEAK_FIXED` branch of
`stockfish_init()` is copied verbatim from `stockfish16.cpp` and must stay in
sync with it; without the macro the original two-line body is compiled.

The gold-standard end-to-end check is a device/emulator test that drives the
real `Stockfish.start()`/`quit()` and counts `/proc/self/fd` across cycles
(Linux/Android only). That requires building the native engine and is out of
scope for this host-only test.
