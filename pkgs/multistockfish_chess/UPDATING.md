# Updating the vendored Stockfish

The engine under `ios/multistockfish_chess/Sources/multistockfish_chess/Stockfish/`
is a copy of upstream Stockfish, currently version 18. It is **not** pristine: it
carries a small patch that has to be re-applied whenever the copy is refreshed.

This document exists so that re-applying it is mechanical. Everything here also
applies to `multistockfish_sf16` and `multistockfish_variant`, whose engines carry
the same patch — but those two are pinned to closed versions and are not expected
to be updated, so this is written for Stockfish.

## Why the patch exists

Upstream reads `std::cin` and writes `std::cout`. Those are process-wide, and on
iOS all three flavours of this plugin are statically linked into a single binary,
so two engines reading and writing them cannot both be resident: their output
lands in one channel, and whichever one redirected the descriptors last wins.

The patch replaces the engine's use of the standard streams with a pair the plugin
owns, `sfio::in()` and `sfio::out()`. They live in `sfio.cpp` **next to the shim**,
outside the vendored tree, and are bound to this library's pipe by the shim before
the engine boots. The engine namespace keeps them apart: each flavour has its own
`sfio::out()` because each flavour compiles into its own namespace.

Nothing else in the vendored tree is modified.

## The patch

Eight hunks across three files. `sfio::in()` and `sfio::out()` are declared by the
first of them, so none of the others need an include.

### 1. `src/misc.h` — declare the streams and point `sync_cout` at them

This is the hunk that does most of the work: `sync_cout` covers nearly all engine
output, including every `info` and `bestmove` line. Replace the `sync_cout`
definition, leaving `sync_endl` as it is:

```cpp
// multistockfish: this library's private I/O, defined in the plugin's sfio.cpp
// alongside the shim. It replaces std::cin and std::cout so that more than one
// flavour of the engine can be resident in a process without sharing the
// standard descriptors. Declared here rather than included, so the vendored
// sources never reach into the plugin directory.
namespace sfio {
std::istream& in();
std::ostream& out();
}

#define sync_cout sfio::out() << IO_LOCK
```

The declaration must stay **inside** `namespace Stockfish`, which is where the
`sync_cout` definition already lives. `sync_cout` is deliberately left unqualified
so that this hunk is identical in all three flavours; if upstream ever uses
`sync_cout` outside the engine namespace it will fail to compile, loudly, rather
than resolve to the wrong stream.

### 2. `src/misc.cpp` — the four remaining `std::cout` / `std::cin` uses

`Logger` (three hunks) ties the engine's streams to a file for the `Debug Log File`
option. It names the streams explicitly, so it has to follow them:

```cpp
    Logger() :
        in(sfio::in().rdbuf(), file.rdbuf()),
        out(sfio::out().rdbuf(), file.rdbuf()) {}
```

```cpp
            sfio::out().rdbuf(l.out.buf);
            sfio::in().rdbuf(l.in.buf);
```

```cpp
            sfio::in().rdbuf(&l.in);
            sfio::out().rdbuf(&l.out);
```

And `sync_cout_start` / `sync_cout_end`, a second output path that does not go
through the macro:

```cpp
void sync_cout_start() { sfio::out() << IO_LOCK; }
void sync_cout_end() { sfio::out() << IO_UNLOCK; }
```

### 3. `src/uci.cpp` — reading commands, and two writes outside `sync_cout`

The command loop:

```cpp
        if (cli.argc == 1
            && !getline(sfio::in(), cmd))  // Wait for an input or an end-of-file (EOF) indication
```

`print_info_string`, which writes between `sync_cout_start()` and `sync_cout_end()`:

```cpp
            sfio::out() << "info string " << line << '\n';
```

And the `bestmove` tail, which starts with `sync_cout` but continues on the raw
stream — **this one matters more than it looks**. If it is missed, the `ponder`
text goes to the process's stdout and `sync_endl` flushes the wrong stream, so the
`bestmove` line never reaches the GUI at all:

```cpp
    sync_cout << "bestmove " << bestmove;
    if (!ponder.empty())
        sfio::out() << " ponder " << ponder;
    sfio::out() << sync_endl;
```

## Finding the sites again in a new version

Line numbers will move and upstream may add sites. Do not go by this document
alone — re-derive the list:

```bash
cd ios/multistockfish_chess/Sources/multistockfish_chess/Stockfish/src

# 1. Everything that writes to or reads from the standard streams.
grep -rn 'std::cout\|std::cin' . --include='*.cpp' --include='*.h'

# 2. Anything that takes a stream's buffer -- this is how Logger is found,
#    and it is invisible to the grep above once Logger has been patched.
grep -rn 'rdbuf' . --include='*.cpp' --include='*.h'
```

Every hit must be either patched or consciously left alone. Two rules of thumb:

- **`std::cerr` is never patched.** The shim only ever redirected fd 0 and fd 1;
  stderr always belonged to the host application and still does.
- **`sync_cout` sites need nothing** — the macro already carries them.

## Deliberately not patched

These are the sites the grep will find and that are correct to skip. If a future
version makes any of them reachable, they need patching.

| Site | Why it is left alone |
| --- | --- |
| `src/main.cpp` | Upstream's command-line entry point. Excluded from the iOS build and never called on Android, where the shim provides the entry point instead. |
| `src/tune.cpp` | The `std::cout` there is in `make_option`, reached only from a `TUNE(...)` registration. A stock build has none, so it is dead code. Confirm with `grep -rn 'TUNE(' . --include='*.cpp' --include='*.h'` — it should match only `tune.h`, where the macro itself is defined. |
| every `std::cerr` | See above. |

## Verifying the result

From the repository root:

```bash
# Fast: the shim's own behaviour, against a real engine. Covers all three
# flavours, since the shim is identical across them.
pkgs/multistockfish_variant/test/run_shim_test.sh

# Slow (compiles two engines): links sf16 and Fairy-Stockfish into one binary,
# the way iOS does, and searches on both at once. This is the test that fails if
# a flavour is still writing to a shared stream.
test/run_two_flavours_test.sh
```

Both must print `PASS`. The checks that specifically catch a missed patch site
are *"the process keeps its own stdout"* and *"the variant's traffic never
reached sf16's channel"*.

A missed `bestmove` tail will not show up as a compile error — it shows up as the
engine going silent after `go`. If a search never returns a move, that hunk is the
first place to look.
