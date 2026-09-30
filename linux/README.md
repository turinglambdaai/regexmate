# Linux host (GTK4)

The third first-party host: a GTK4 window over one embedded Racket CS
backend, speaking RVT1 through the shared `runtime/` codec. The embedding
contract mirrors `platform/windows/runtime` — the same public Racket CS C API
and the same threading rules — with a connected `socketpair` standing in for
the Win32 named pipe pair. The Racket input and output ports receive distinct
descriptors for that socket so their ownership and shutdown behavior are
unambiguous.

Status: **developer preview**. CI compiles the runtime bridge against Racket's
public embedding headers and exercises startup, concurrent RPCs, State access,
cancellation, overload, shutdown, project scaffolding, CLI build, packaging,
and verification against a real embedded Racket CS instance.

## Layout

```text
platform/linux/
├── runtime/
│   ├── backend.hpp        # rivet::linux_runtime::Backend — same contract as rivet::windows
│   └── backend.cpp        # racketcs boot + RVT1-over-socketpair transport
└── host/
    ├── GeneratedBackend.hpp  # scaffold schema; raco rivet build replaces it
    ├── CMakeLists.txt
    └── src/main.cpp       # GTK4 counter demo over the generated client
```

## Building by hand

Requirements: an embeddable Racket CS build, CMake ≥ 3.24, pkg-config, GTK 4,
zlib, LZ4, curses, and a graphical session (or Xvfb) to run. The standard
prebuilt Linux Racket installer does not ship `libracketcs` or the three boot
files; build and install
Racket CS from a source distribution as described by Racket's embedding guide.
The CI workflow uses the official minimal "source + built libraries" archive so
the build remains reasonably small.

```bash
export RIVET_ROOT="$PWD"
export RIVET_RACKET_INCLUDE=/path/to/racket/include
export RIVET_RACKET_LIBRARY=/path/to/racket/lib/libracketcs.a
cmake -S platform/linux/host -B /tmp/rivet-linux-build
cmake --build /tmp/rivet-linux-build
```

The executable must sit beside a staged runtime to start: put `runtime/*.boot`
and `res/core.zo` (produced by `raco ctool --mods`, the same artifacts every
platform host consumes) next to `RivetHost`. `raco rivet build`, `dev`, and
`package` create this layout automatically.

## Honest gaps

- Production signing and distro-native installers are not defined yet; Linux
  packaging currently produces a verified self-contained application directory
  whose GTK/system-library dependencies are audited with `ldd`.
- GTK is a toolkit, not a display protocol: global hotkeys and always-on-top
  overlays are compositor-dependent. Application hosts that need them must
  define an explicit X11/Wayland policy.
