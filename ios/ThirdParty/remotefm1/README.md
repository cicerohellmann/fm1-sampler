# libremotefm1 (vendored)

The portable core of RemoteFM1's host library, used by the iOS app to drive an FM-1 that runs the
[RemoteFM1](https://github.com/Quixotic7/RemoteFM1) firmware (USB or Bluetooth MIDI). Copied unchanged from
RemoteFM1 commit `9642d846d0b0ec7da6878e8e997a275f48892bcc`:

| here | there |
|---|---|
| `src/{codec,session,panel,screen,tiles_ref,fake}.c` | `host/src/` |
| `include/rfm/*.h` | `host/include/rfm/` |
| `proto/rfm1.h` | `proto/rfm1.h` |
| `firmware/src/remote_proto.h` | `firmware/src/remote_proto.h` |

License: **MPL-2.0** (`LICENSE`), file by file, as each file's SPDX line says (RemoteFM1's LICENSING.md: the host
library's portable core is MPL-2.0 so that other hosts can use it). Changes to these files stay under MPL-2.0 and
must be published; the rest of this app is not affected. None of RemoteFM1's GPL-3.0 files (its macOS back ends,
tools, site) are used. Protocol: RemoteFM1's `docs/PROTOCOL.md`.
