# Security review — October 2026

A security pass over the whole tree ahead of locking the production build: automated scanners plus a line-by-line
review of the four highest-risk surfaces — the root-privileged installer scripts, the 1401 app and its WebView, the
kernel extensions, and the Metal plugin with the Rust translator's C ABI. Every finding below was checked against the
code; the demonstrated ones were reproduced.

Each finding says whether it is **fixed in this branch** or **recorded for the maintainer**. Things are recorded
rather than fixed here when they cannot be built or tested anywhere in this repository's CI (the kernel extensions
link NVIDIA's closed RM/NVKMS, which is not in the tree), when they change kernel pointer or privilege semantics whose
other half is not present (an unverified kernel change can brick display bring-up), or when the fix needs a signing
key or distribution decision that is not ours to make. Each recorded item carries the exact patch.

## Scanners

| Scanner | Scope | Result |
|---|---|---|
| cargo-audit (RustSec db 2026-10-08) | all three Cargo.lock files | 0 vulnerabilities, 0 warnings |
| zizmor | `.github/workflows/build.yml` | 21 findings → 0 after pinning actions and `persist-credentials: false` |
| shellcheck -S warning | every `*.sh` | no injection/quoting findings; the SC2115 lines use literal constants (`/Library/...`, `/Users/Shared/nvfw`), never empty |
| bandit | every `*.py` | only B404/B603/B607 (subprocess in test and build helpers with constant argv); no real issue |
| detect-secrets | working tree and all 735 committed blobs | nothing; the one flagged hex is the public release's SHA-256 in `app/Sources/main.swift`, not a credential |

## Fixed in this branch

### Installer — GSP firmware and GPU bundles were not root-owned (High)
`package/install.sh` / `app/Resources/nullmoth-install.sh` (byte-identical copies). The GSP firmware NRM.kext loads
from `/Users/Shared/nvfw` at every boot (`kexts/NVRM/os-xnu2.cpp:1120` `nv_get_firmware`, no signature check) was
installed with `mkdir -p` into world-writable `/Users/Shared` (mode 1777) and only ever `chmod -R a+rX`, never chowned
to root. A local user could pre-create or symlink that directory, or (in the `sudo ./install.sh` flow) keep it
writable, and replace the firmware the kernel loads. The GPU bundles Metal loads into every process were chowned root
but their mode was never normalised. **Fix:** the installer now creates the firmware directory fresh as root
(`mkdir -m755`, no `-p`, so a reappeared entry fails), refuses to back up through a symlink at that path, and
`chown root:wheel` + `chmod -R go-w,a+rX` both the firmware and the four GPU-bundle entries. Verified: the driver's
install/removal test suite passes in CI with the change.

### Redaction — home paths leaked from JSON-escaped crash reports (Medium)
`app/Sources/redaction.swift`. Apple `.ips` crash reports store paths as JSON with escaped slashes
(`"\/Users\/name\/..."`); the `/Users` rule matched only real slashes, so "Send logs" uploaded the home path the UI
promises to strip, and any other account's username embedded in it. **Fix:** an additive escaped-slash variant of the
rule; plain-slash paths still collapse exactly as before (covered by `tools/test_card_logs.py`). Residual, recorded
below: a non-`/Users` home directory appearing JSON-escaped is still not caught by the home-prefix rule.

### Translator — unbounded recursion in the AIR type parser, demonstrated (Critical/High)
`translator/translator/src/native/parse.rs` `parse_type`. The type parser recursed once per nesting level with no
bound (arrays, vectors, pointer chains, struct fields). A crafted shader with a deeply nested type overflows the
stack and aborts the host process — reachable through the shipping C ABI (`nvmtl_translate`, `nvmtl_reflect` and the
other entry points the plugin calls on app-supplied AIR). A stack overflow is not catchable, so a panic firewall does
not help; it needs a depth bound. **Reproduced** through the real exported `nvmtl_translate`: a ~12 KB input (≈2000
levels) crashes with SIGSEGV on a 512 KiB stack (the size of the secondary thread where Metal compiles), and an
80000-level input crashes on the default stack. **Fix:** a depth guard (`MAX_TYPE_DEPTH = 128`, mirroring the existing
`scalar_align` guard in `buffer_addresses.rs`) threaded through the recursion; past the bound it returns `Err`.
After the fix both reproducers return a clean `rc=-1` and the valid baseline still translates. A regression test
(`deeply_nested_type_is_refused_instead_of_overflowing_the_stack`) is added.

## Recorded for the maintainer

These are real. They are not applied here for the reason each states; the fix is spelled out so it can be made as a
focused, properly-validated change.

### K1 — NVKMS copy-in/out classifies a caller address by its top bit (Critical)
`kexts/NVRM/os-nvkms-xnu.cpp:195-204`. `nvkms_copyin`/`nvkms_copyout` treat any address with bit 63 set as a kernel
pointer and `memcpy` it directly, instead of `copyin`/`copyout` from the user task. An unprivileged process reaching
the NVKMS ioctl path (`NVRM.cpp` selector 4, `sKms`) can set bit 63 on an embedded pointer field and drive an
arbitrary kernel read or write. Verified the heuristic is unconditional. **Why recorded:** both the user path
(`nvkms_xnu_open`, line 129) and the in-kernel display path (`nvkms_open_from_kapi`, line 350) open the handle as
`NVKMS_CLIENT_KERNEL_SPACE`, so the fix is not a one-line client-type check — it must route user-originated ioctls so
NVKMS performs real `copyin`/`copyout` on embedded user pointers, against NVKMS semantics whose source is not in this
tree. It cannot be compiled or hardware-tested here, and an unverified change to this path can break all mode-setting.
**Fix:** carry the address space explicitly (a per-open "user origin" flag set by the `sKms` path, or a kernel-copy
routine used only by genuine KAPI callers); never infer it from the pointer value. Highest priority.

### K2 — NVRMUserClient has no privilege gate; RM privilege hooks are hard-wired to "allow" (High)
`kexts/NVRM/NVRM.cpp:1043-1071` (no `clientHasPrivilege`/entitlement/task check on open), `os-xnu.cpp:174`
(`os_is_administrator` returns true unconditionally), `os-xnu2.cpp:44` (`os_check_access` returns true). Any local
process can open the full RM and NVKMS surface, and RM's own admin gating is defeated. Enables K1 and widens every
RM/NVKMS parsing bug to unprivileged reach. **Why recorded:** same build/test limits as K1; choosing the right gate
(root, or a graphics entitlement for WindowServer) is a design decision with regression risk on a live display stack.
**Fix:** restrict the control device / privileged selectors, and back `os_is_administrator`/`os_check_access` with
real `kauth` checks as the Linux build does.

### K3 — `fKms` lazy-open race in `sKms` vs `clientClose` (Medium)
`kexts/NVRM/NVRM.cpp:1155` reads/initialises `me->fKms` without `gKmsLock`; `clientClose` (1073-1085) frees it. A
multithreaded process can use-after-free it → kernel panic. **Fix:** take `gKmsLock` around the lazy open and the
ioctl, and gate teardown on the same lock plus an in-flight count. Recorded with K1/K2 (same component, untestable here).

### K4 — EDID block index integer overflow (Low)
`kexts/NVRMFB/fb/nvrm-fb.cpp:2315-2320`. `blockNumber * 128` is 32-bit and wraps for `blockNumber ≥ 2^25`, bypassing
the bound and reading out of `fEdid`. **Fix:** compute in 64-bit / check `blockNumber <= fEdidSize/128`. Mechanical;
bundled with the kext patch set since NVRMFB is not built in CI.

### P1 — No panic firewall on the translator C ABI (Medium, structural)
`translator/wrapper/src/lib.rs`. None of the 17 `extern "C"` functions wrap their body in `catch_unwind`, and the
cdylib builds `panic = "unwind"`, so on rustc ≥ 1.81 any Rust panic reachable from an entry point aborts the whole
host process. The main translate/reflect value path showed no reachable panic in 8500 fuzz iterations; the auxiliary
`nvmtl_link_*` / `nvmtl_lower_mesh*` paths were not fuzzed. **Why recorded:** no demonstrated trigger, and a correct
fix wraps 17 FFI bodies — an automated transform risks corrupting the format-string braces in this shipping library,
and the change alters the failure semantics of every entry point, so it deserves its own review. It does **not**
replace the K-less depth fix above (a stack overflow is not an unwind). **Fix:** add
`fn ffi_i32(f: impl FnOnce() -> i32) -> i32 { std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(-1) }`
and wrap each i32-returning export `ffi_i32(move || { <body> })`; wrapping cannot change the success path, only
intercept a panic. Do not switch to `panic = "abort"` (same abort).

### P2 — cubin ELF parser integer overflow (Low, off by default)
`plugin/NVMTLVendorCompiler.m:288-299` (`nvmtl_elf_section`). `shoff + shentsize*shnum` can wrap past the bound →
wild-pointer read; the section-name `strcmp` can read past the buffer. Reachable only when `NVMTL_VENDOR_COMPILER` is
set (off by default) and the cubin comes from NVIDIA's own compiler plugin. **Fix:** branchless bounds
(`shoff <= n && shnum <= (n - shoff)/shentsize && shentsize >= 0x40`) and bound the name read with `strnlen`.

### P3 — dlopen of environment-derived paths; `VK_*`/`MESA_*` not scrubbed (Low, release-mitigated)
`plugin/nvmtl_vk.c:60,573,3850`, `plugin/NVMTLVendorCompiler.m:34,150,175,511`. The release build already `unsetenv`s
inherited `NVMTL_*`/`NVK_*`/`NAK_*`/`NVRM_*` before these reads (`NVMTLObjects.m:82-88`), but `VK_ICD_FILENAMES` and
`MESA_*` are not scrubbed, and the scrub is release-only. **Fix:** in production, ignore `*_LIB`/`*_DYLIB`/`*_PATH`/
`*ICD*` overrides or require the resolved file be root-owned and not group/world-writable; also scrub/pin `VK_*` and
`MESA_*`.

### P4 — `nvrm610.conf` key allowlist permits dlopen-driving keys (Low, root-write only)
`plugin/NVMTLObjects.m:100-124`. The `NVMTL_`/`NVK_`/`NVRM_` prefix allowlist correctly blocks `DYLD_*`/`MESA_*`/`VK_*`
but still permits `NVMTL_ICD_LIB`/`NVMTL_NVK_DYLIB`/`NVMTL_VENDOR_PLUGIN_PATH`, which drive `dlopen` (P3). The file is
root-owned, so this is defence-in-depth. **Fix:** deny keys matching `*_PATH`/`*_LIB`/`*_DYLIB`/`*ICD*`; verify the
file is root-owned 0644 before applying.

### P5 — texture `getBytes` region bound can overflow (Low, same-process)
`plugin/NVMTLObjects.m:1166-1167`. `region.origin.x + region.size.width` can wrap and bypass the check → OOB read of
the app's own process memory. **Fix:** `if (region.origin.x > _i.w || region.size.width > _i.w - region.origin.x) return;`
and sanity-check `_i.bpp`.

### A2 — root scripts and the driver package run from a user-writable, ad-hoc-signed bundle; verify-once/extract-thrice (Medium)
`app/Sources/main.swift:843-845,660-672` run bundle scripts as root; `app/build.sh:50` ad-hoc signs; `nullmoth-setup.sh`
verifies `$PKG`'s SHA once (304-305) then `tar -xzf "$PKG"` three times (312, 489, 594). Same-user code can edit a
privileged script before elevation, or swap the package between check and a later extraction. Requires pre-existing
same-user execution. **Why recorded:** a correct fix verifies then copies the package into a fresh root-owned 0700
directory per root invocation and operates only on that copy; the three extractions span separate invocations
(install, prepare, finish at next boot), and this is the boot-critical install path that cannot be run in this repo's
CI. **Fix:** after the single SHA check, `cp "$PKG"` into the root-owned preflight dir, re-verify, and point every
later `tar` at the copy; stage privileged scripts from a root-owned location (or verify a pinned hash immediately
before elevation) and sign with Developer ID rather than ad-hoc.

### A3 — "Update driver" trusts the release's self-declared checksum (Medium)
`app/Sources/main.swift:506-570`. The first install is gated by `Package.sha256` pinned in the binary, but the update
path reads the SHA from the release's own `SHA256SUMS.txt` with no signature or key pinning: whoever can publish the
"latest" release, or MITM with a valid cert, can ship a malicious driver (kernel code) that the app installs. **Why
recorded:** the fix needs a publisher key to pin, which is a distribution decision, not a code change we can complete
here. **Fix:** verify a detached signature over `SHA256SUMS.txt` against a public key pinned in the app before
trusting any update, and/or pin the GitHub leaf/publisher key.

### Lower severity, recorded
- **Redaction residual:** a non-`/Users` home path appearing JSON-escaped is still not caught (`redaction.swift` home
  rule). Apply the same `(?:/|\\/)` tolerance to the home-prefix rule, or JSON-unescape `.ips` bodies before redacting.
- **A-OOM:** `main.swift:185,260` read a whole crash file before the 120 KB cap; a planted multi-GB file can stall the
  app at login. Stat-cap or stream first.
- **A-perm:** the Desktop crash report is written with default umask; content is redacted and on the user's own
  Desktop. Write 0600.
- **app.js:** `row()` does not escape its value; every current caller passes `esc(...)`, and `esc` omits `'` (safe only
  because attributes use double quotes). Harden the contract.
- **setup env:** `nullmoth-setup.sh:8` sources files from `${NULLMOTH_STATE_DIR:-/Library/NullMoth}`; not reachable
  from the app (elevation sanitises the environment), but a root script should hardcode the directory it sources.

## What the reviews confirmed safe

The privileged command the app builds is **not injectable** — single-quote plus AppleScript escaping round-trips every
metacharacter payload tested. The WebView escapes every dynamic DOM value under a strict CSP, loads only bundle
content, enforces HTTPS, and has no Web Inspector. The IPv4/IPv6/MAC/UUID/serial redaction rules are effective. The
kernel user-client paths other than K1-K4 (clientMemoryForType mapping, page pinning, gpuva/surfshare/pageoff,
IOSurface sharing, AGDC, framebuffer EDID/timing) are bounds-checked and scoped to the calling task. The translator's
`nvmtl_translate_free` ownership round-trip is correct; the function-constants and datalayout parsers are bounds-safe;
the `air-opt` subprocess uses `posix_spawn` with a fixed binary and hash-named files (no shell, no injection). The
diagnostics/DTrace path is inert in the shipping build.

## Production build lock

Pinned inputs: Vulkan-Headers by full commit (`build/inputs.lock`, fetched and verified by `build/fetch-deps.sh`);
Rust by `translator/rust-toolchain.toml`; Mesa by full commit (`nvk/MESA_BASE`); every GitHub Action by commit SHA.
`cargo` runs `--locked` everywhere; checkouts set `persist-credentials: false`. `build/production.sh` builds the open
components with those locked inputs into `out/production` with `SHA256SUMS` and a `BUILD-MANIFEST.txt`, has an opt-in
byte-for-byte reproducibility check (`REPRO=1`), and the CI `production` job attests build provenance on release tags.
A RELEASE build refuses an unpinned Vulkan header or Rust toolchain.
