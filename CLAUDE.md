# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

A small collection of files that automate building a Windows 11 development VM on Proxmox VE from the host shell:

- **`win11.sh`** — the main script. Creates the VM (`qm create`/`qm set`), sources `download-isos.sh` to locate/download the Windows 11 and VirtIO ISOs, builds an unattended-answer-file ISO from `autounattend.xml` (via `genisoimage`), attaches everything to the new VM, then **starts the VM itself** and sends Enter via `qm sendkey` for ~15s to clear Windows Setup's boot prompt (see below) — this is genuinely hands-off end to end, not just up to VM creation.
- **`download-isos.sh`** — `validate_iso_filename()`, `download_windows_iso()`, `download_virtio_iso()`, and `VIRTIO_STABLE_URL`. `win11.sh` sources it (`source "$SCRIPT_DIR/download-isos.sh"`, resolved relative to the script's own location); it can also be run directly (`./download-isos.sh`) to pre-fetch both ISOs without creating a VM — see "download-isos.sh extraction" below for the dual-mode design.
- **`autounattend.xml`** — Windows unattended-setup answer file. Creates a local `Admin` user, disables telemetry/consumer features/search suggestions, forces the network to Private and disables the firewall entirely, enables RDP and OpenSSH, and uses `FirstLogonCommands` to install Chocolatey, then Git and Visual Studio 2022 Professional.
- **`README.md`** — user-facing usage docs.

There used to be a separate `install.sh` wrapper and a file named `Proxmox script.sh`; both were removed/renamed to `win11.sh` in history. Don't reintroduce references to either filename.

These scripts are meant to run **on the Proxmox host** (needs `qm`, `pvesm`, `genisoimage` on PATH) with `autounattend.xml` and `download-isos.sh` present in the same working directory as `win11.sh`. There is no test suite — it can't be meaningfully unit tested outside a real Proxmox host, so treat any change as needing careful manual/read-through review rather than `npm test`-style verification. `autounattend.xml` itself CAN be checked for well-formedness without a Proxmox host: `python3 -c "import xml.dom.minidom as m; m.parse('autounattend.xml')"` - always run this after editing it, and also check that `<FirstLogonCommands>`'s `<Order>` values are still contiguous with no gaps/dupes (a one-line Python `re.findall` over the block is enough). `win11.sh`/`download-isos.sh` CAN be smoke-tested without a real Proxmox host by putting fake `sudo`/`qm`/`pvesm`/`genisoimage`/`curl`/`wget` shims earlier on `$PATH` that just echo their arguments and touch/write fake output files. PowerShell snippets destined for `<CommandLine>`/`<Path>` elements can be syntax-checked and dry-run tested with `pwsh` (available in this sandbox) against mocked cmdlets before ever committing them — do this for anything non-trivial; see the "new Outlook" saga below for why a syntax-clean, logically-correct PowerShell command can still break Setup for reasons no sandbox can catch (timing/servicing collisions, not syntax).

## Auto-start + clear the "Press any key" boot prompt

The Windows install media's UEFI bootloader shows "Press any key to boot from CD or DVD..." and waits only a few seconds before falling through to the next (non-bootable, at that point) boot device — without a keypress this silently defeats automation. `win11.sh` calls `sudo qm start "$VMID"` itself, then loops `sudo qm sendkey "$VMID" ret` for 15 iterations/1s each (~15s total; originally 45×2s/~90s, shortened after live-testing showed the prompt clears well within 15s). Sending Enter after Setup has already moved past that screen is harmless. Chose `qm sendkey` (inject via QMP) over patching the ISO's `bootx64.efi`→`cdboot.efi` (a documented technique, but re-mastering a hybrid El Torito/UEFI ISO correctly from Linux is easy to get subtly wrong and would need redoing per Windows ISO version) — simpler and safer.

If this loop ever needs lengthening/shortening (e.g. slower host hardware never clearing the prompt in 15s), it's the `for _ in $(seq 1 15); do ... sleep 1; done` line right after `qm start` — keep the sleep interval and iteration count as one clearly-named pair, don't split the total duration across multiple magic numbers.

## Quieted noisy tool stdout — `run_quiet()` helper

`qm set --scsi0`/`--efidisk0`/`--tpmstate0`, `qm start`, and `genisoimage` all print chatter that isn't useful to a user (LVM messages, `swtpm_setup` TPM-manufacturing output, OVMF varstore-copy `INFO:` lines, ISO9660 build stats). A `run_quiet()` helper (next to the `info`/`success`/... color helpers) captures **both** stdout and stderr via `output=$("$@" 2>&1)`, stays silent on exit 0, and on nonzero exit echoes the full captured output before `return`ing the real exit code — so `set -e`/`trap cleanup ERR` still fire and no diagnostic detail is lost on an actual failure. All five calls go through `run_quiet sudo <cmd> ...` instead of a bare `> /dev/null`.

**Non-obvious lesson from getting here**: don't assume which stream a tool's noise is on, or that it appears at the call site that superficially seems responsible. `swtpm_setup`'s output isn't produced by `--tpmstate0` (which only registers a `size=0` placeholder) — Proxmox actually manufactures the TPM state at `qm start`, so that's the call that needed quieting, and its chatter is on stderr, not stdout. Took two wrong guesses to land on `run_quiet()` as a mechanism-agnostic fix. If you add a new noisy privileged command, use `run_quiet` from the start rather than reaching for `> /dev/null` and assuming.

## VS2022 workload + toolchain retargeted for pgr2-recomp

This VM is currently built for [teamzuzu/pgr2-recomp](https://github.com/teamzuzu/pgr2-recomp) (private repo, readable via `gh api repos/teamzuzu/pgr2-recomp/...`) — a pure C/CMake/MSVC static recompilation project (no .NET/C#), per its own docs and its toolkit dependency [sp00nznet/xboxrecomp](https://github.com/sp00nznet/xboxrecomp)'s `docs/GETTING_STARTED.md`: "Visual Studio 2022 (MSVC) with C/C++ desktop workload", "CMake 3.20+", "Python 3.10+ with capstone".

- VS2022 install is split into two `choco install` steps: base `visualstudio2022professional`, then separately `visualstudio2022-workload-nativedesktop` (the "Desktop development with C++" workload, includes MSVC + Windows SDK) — the documented way to add a workload to an existing VS install, and splitting it keeps each step's success/failure independently visible.
- `pip install capstone` can't use the "hardcode the full path" trick the other choco-installed tools use (bare `choco`/`git`/etc. fail mid-batch due to stale `PATH` — see the Chocolatey PATH-timing bug below) because Chocolatey's `python` package is a meta-package tracking the latest 3.x release, so its install dir is version-specific. Instead it re-reads `PATH` fresh from the registry before calling `pip` — the general-purpose fix when a full-path workaround isn't available.
- **Did NOT auto-install Ghidra** (xboxrecomp's docs mention it as optional) — large, Java-based, not on pgr2-recomp's critical path. Mentioned to the user as available (`choco install ghidra -y`) rather than silently added.
- **Did NOT do a sweeping AppX bloatware removal** (Xbox app, Solitaire, Weather, etc.) — meaningfully bigger blast radius than the `reg add`-based debloat entries here, with a real history of breaking Store/update components elsewhere. Mentioned as a further option, not done silently.

If the user's active project changes, re-derive the actual toolchain requirements from that project's own docs rather than reusing this list by default — it's specific to pgr2-recomp/xboxrecomp, not generic "good defaults."

## download-isos.sh extraction

`validate_iso_filename()`, `download_windows_iso()`, `download_virtio_iso()`, and `VIRTIO_STABLE_URL` live in `download-isos.sh`, extracted from `win11.sh` at the user's request:

- **Sourced, not exec'd** — the download functions set `WIN_ISO`/`VIRTIO_ISO` as side effects `win11.sh` reads afterward; a subprocess model would need a fragile stdout-only return-value protocol instead.
- **Standalone mode** via the classic `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then ... fi` guard, with its own `$ISO_PATH_ROOT` resolution (only if not already set by a sourcing parent).
- **Colors**: `download-isos.sh` defines plain fallbacks guarded by `declare -F name > /dev/null || name() { ... }` so it stays colored when sourced from `win11.sh` (which defines them first) and plain when run standalone. Don't duplicate the ANSI/`[ -t 1 ]` logic directly into `download-isos.sh` — that's how the two could drift apart.
- **What stayed in `win11.sh`**: colors, sudo preflight, `ISO_PATH_ROOT` resolution, cleanup trap — used well beyond just ISO downloading.

## QEMU Guest Agent installed inside the guest

`qm set --agent enabled=1` only tells **Proxmox** to expect an agent — it doesn't install `qemu-ga` inside Windows. `FirstLogonCommands` runs a PowerShell one-liner that enumerates CD-ROM drives via `Get-WmiObject Win32_CDROMDrive`, looks for `guest-agent\qemu-ga-x64.msi` on each (the VirtIO ISO's drive letter isn't guaranteed, same reasoning as the WinPE `DriverPaths` fix below), and runs `msiexec /i ... /quiet /norestart` on the first match. Uses `Start-Process -ArgumentList @(...)` (an array) rather than a single string, to avoid a second layer of quote-escaping inside the already-quoted `-Command "..."` value — prefer the array form for any future `msiexec`/external-process calls here.

**XML comment pitfall**: a comment referencing `--agent` as prose broke well-formedness — XML comments cannot contain a literal `--` *anywhere* inside them. If a comment needs to reference a CLI double-dash flag, rephrase around it (e.g. "Proxmox's `qm agent` option") rather than writing it verbatim.

## WSL + latest Ubuntu — added then removed

Added 2026-09-13 (`wsl --install -d Ubuntu`, plain `Ubuntu` to always track Canonical's current default release), **removed 2026-09-14 at explicit user request** along with VS Code. Kept as a note in case it's revisited: it can't be made fully unattended — enabling WSL/Virtual Machine Platform only takes effect after a restart (with no way for `FirstLogonCommands` to resume queued commands across a mid-batch reboot, so this deliberately never forced one), and Ubuntu's first launch prompts interactively for a UNIX username/password with no unattended equivalent. It also needs **nested virtualization enabled on the Proxmox host** (`nested=1` for `kvm_intel`/`kvm_amd`) since WSL2 runs Linux in a Hyper-V-based VM and this Windows install is already a VM itself — `win11.sh`'s `--cpu host` passes the flags through, but only if the host itself has nested virt on (a host-level `modprobe` setting outside this script's control). If re-adding, re-read this note first — the constraints haven't changed.

## "New Outlook for Windows" — investigated, three fixes attempted, all abandoned

Windows 11 (23H2+) ships "new Outlook for Windows" (`Microsoft.OutlookForWindows`) preinstalled, fetched via a **dedicated OOBE-time Windows Update Orchestrator task** (`HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate`) that pulls it from the Store *during OOBE itself* — the confirmed cause of an unexpected region/market prompt seen during a live install, per Microsoft's own ["Control Installing and Using New Outlook"](https://learn.microsoft.com/en-us/microsoft-365-apps/outlook/get-started/control-install) doc.

Three different removal attempts were tried and **all three failed**, across two passes and two mechanisms:
1. `Get-AppxProvisionedPackage`/`Remove-AppxProvisionedPackage` (+ registry key removal) in the `specialize` pass, to beat the OOBE-time task → **crashed Windows Setup** ("the computer restarted unexpectedly" — `RunSynchronousCommand` treats a nonzero exit as fatal in that pass; DISM/Appx cmdlets collided with Setup's own concurrent image servicing).
2. A **registry-only** replacement in `specialize` (`BlockedOobeUpdaters` blocklist value + the same key removal, no DISM/Appx at all, built via `[char]34` concatenation to avoid any command-line quote-escaping) → **also crashed Setup** the same way. Root cause unconfirmed (candidates: `New-Item -Force` may not create multiple missing intermediate registry levels the way the filesystem provider does; or a genuine collision with Update Orchestrator's own concurrent access to that key) but the *pattern* — two different mechanisms, two crashes — mattered more than pinning the exact cause.
3. The original DISM/Appx command, moved to **`FirstLogonCommands`** (post-OOBE, where failures are normally non-fatal, so no crash) → **hung instead**: a PowerShell window sat unresponsive until manually closed, blocking the rest of the synchronous batch (everything after it ran fine once unblocked).

**Unified conclusion**: all three failures trace to the same resource (`UScheduler_Oobe`/`Microsoft.OutlookForWindows`), because Windows' own Update Orchestrator is actively working it around OOBE and immediately after first logon — anything this script runs that touches it collides, as a fatal error pre-OOBE or a lock-wait hang post-OOBE, regardless of how carefully the touching command is written. **Outlook removal is now fully abandoned** — no code touches this anywhere in `autounattend.xml`. The region/market prompt, if it appears, is cosmetic and doesn't block the install. A user who wants Outlook gone can run this manually, well after first-logon churn has settled (a minute or two after the desktop is up and idle, by which point Update Orchestrator's own activity should be done):
```powershell
Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like 'Microsoft.OutlookForWindows*' } | Remove-AppxProvisionedPackage -Online
```
**Don't re-attempt this as a `RunSynchronousCommand`/`SynchronousCommand` in `autounattend.xml`** without a structurally different approach (e.g. a scheduled task that fires a few minutes after logon, well clear of the OOBE-adjacent window) — the evidence points at *timing relative to OOBE*, not command correctness, as the actual constraint, and a fourth timing variant isn't worth another 30-60 minute install cycle to disprove.

## Pagefile disabled at first logon

`FirstLogonCommands` turns off `AutomaticManagedPagefile` via `Get-CimInstance`/`Set-CimInstance` (Win32_ComputerSystem), then removes any existing `Win32_PageFileSetting` — the standard two-step, since clearing the setting alone while automatic management is still on lets Windows recreate one on next boot. Used the CIM cmdlets rather than `wmic` (deprecated/removed on newer Windows 11 builds, would silently no-op). **Trade-off**: no pagefile means Windows can't write a crash dump on a BSOD — reasonable for a disposable dev VM per explicit user request, but worth knowing if a future debugging session needs a dump and comes up empty. Doesn't touch `VM_MEMORY`/`DISK_SIZE` or Proxmox's own host-level swap — guest-only virtual memory.

## Code comments vs. CLAUDE.md

This repo has a standing split between the two, and it applies to `win11.sh`, `autounattend.xml`, and any file added later:

**Goes in a code comment (short, factual, at the point of use):**
- What a non-obvious line does, in present tense, in one line. Two lines only if the thing genuinely needs a second clause (e.g. a regex's edge case).
- A pointer to more detail: `# ... (see CLAUDE.md)`.
- Never a paragraph. If you're about to write a second sentence justifying *why* something is the way it is, stop — that belongs below instead.

**Goes in CLAUDE.md (as much detail as the topic needs):**
- The *why*: root cause of a bug, the investigation that found it, what was tried and ruled out, what the fix actually changed and what it didn't.
- Anything that took more than a couple of minutes to figure out — if it was non-obvious to work out once, it'll be non-obvious to re-derive later.
- Decisions deliberately NOT made (e.g. "Windows 11 ISO auto-download was deliberately NOT added" below) and the reasoning, so they aren't re-attempted or re-litigated from scratch.
- Constraints on future edits to that area ("if you change X, Y must also change" / "don't do Z, it'll break because...").

**In practice:** when you fix something, write the one-line factual comment in the code, then add or extend a `##` section here with the full story. When you're about to touch code that has a `(see CLAUDE.md)` pointer, actually read the referenced section first rather than re-deriving the reasoning from the code alone - it may cover a constraint or a rejected alternative that isn't visible from the diff. **When something is fixed/superseded/abandoned, condense its section down to the current state + the one non-obvious lesson rather than leaving the full blow-by-blow investigation in place** — the *why* matters, the play-by-play of getting there usually doesn't once it's resolved (see the "new Outlook" section above for the condensed version of what was originally five separate dated subsections).

## Boot loop investigation — missing `xmlns:wcm`, fragile driver-path assumptions

Symptom: VM boots the Windows 11 ISO fine, reaches the initial Setup screen, then resets - before language selection - whenever the OEMDRV answer-file ISO (`sata0`) is attached. Three real bugs found and fixed, in order of suspected impact:

1. **`autounattend.xml`'s root `<unattend>` element never declared `xmlns:wcm`.** Every `wcm:action`/`wcm:keyValue` attribute (29 of them) referenced an undefined namespace prefix — `python3 -c "import xml.dom.minidom as m; m.parse(...)"` failed with `unbound prefix` even before this session's edits, so this predates tracked history. A real WSIM-generated unattend.xml always declares `xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"`. Fixed regardless of whether it was the actual crash cause (untestable outside a real install) since it's cheap, safe, and structurally correct either way.
2. **`PnpCustomizationsWinPE`'s `DriverPaths` only checked `E:\` and `F:\`.** WinPE's CD-ROM drive letter assignment shifts with how many optical devices are attached (3 here: Windows ISO, VirtIO ISO, OEMDRV) — the VirtIO ISO could land on `D:`, `G:`, or `H:` too. Without a driver match, Setup can't see the `scsi0` disk and the automated `DiskConfiguration` step has nothing to act on. Widened to `D:`-`H:` for both driver dirs (10 `PathAndCredentials` entries) — extra non-existent paths are silently skipped, so purely additive/safe.
3. **Wrong VirtIO driver family: `viostor` vs `vioscsi`.** `win11.sh` attaches the disk via `--scsihw virtio-scsi-pci` (VirtIO-**SCSI**); `viostor` is for the older VirtIO-**BLOCK** device, a different PCI hardware ID, so Setup's "Load Driver" dialog hid it as a non-match even though the file was right there on the disc. Confirmed by downloading the real virtio-win ISO and inspecting it with `isoinfo -R` — `/vioscsi/w11/amd64/vioscsi.inf` is the correct match. Changed all storage `DriverPaths` from `\viostor\w11\amd64` to `\vioscsi\w11\amd64`; `NetKVM` (network) was already correct. **If the disk's bus type is ever changed to virtio-blk (e.g. `--virtio0`), switch these paths back to `viostor`** — they must always match whichever bus `win11.sh` actually uses.

**General lesson**: don't trust unattend.xml driver/path assumptions from memory or convention — inspect the real ISO (`isoinfo -R -i <file> -l`) when in doubt, and cross-check the driver family against the exact Proxmox bus/controller in use. If a boot loop or missing-driver problem recurs after all three fixes, the next step (not yet needed) is Shift+F10 at the failure screen for a WinPE prompt, then checking `X:\Windows\Panther\setupact.log`.

## Language/region defaults to en-GB

`Microsoft-Windows-International-Core-WinPE` (in the `windowsPE` pass) only controls Setup's own UI language, not the installed OS's locale — that's the separate `Microsoft-Windows-International-Core` component (no `-WinPE` suffix), added to the `specialize` pass with `en-GB` (WinPE-pass fields also changed from `en-US` to `en-GB` for consistency). Without it, OOBE still asks the region question on first boot even though Setup itself was fully unattended. If a user in another region hits this, all `en-GB` occurrences in *both* components need changing together.

## Network/firewall/remote-access defaults

`FirstLogonCommands`, right after the debloat block:
1. `Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private` — the `<NetworkLocation>Home</NetworkLocation>` OOBE setting is flaky in virtualized environments and isn't reliable alone; this command is the actual fix.
2. `Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False` — full firewall disable per explicit user request, **dev/lab-only default**, flagged in README's security note — don't soften/remove that note if this area is touched again.
3. `reg add ...Terminal Server /v fDenyTSConnections /d 0` — enables RDP (no separate "add to Remote Desktop Users" needed, `Admin` is already an Administrator).
4. `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'`.

The OpenSSH-specific firewall rule is kept even though redundant with the firewall being fully disabled — if a user re-enables the firewall later without re-adding it, SSH would silently break again. Same reasoning for the RDP rule-group-enable step.

## Bug found by live-testing: bare `choco` fails inside FirstLogonCommands

Chocolatey's installer appends its bin dir to machine `PATH` via the registry, but `FirstLogonCommands` runs within one long-lived first-logon session whose environment block was captured before the install ran — so a bare `choco install ...` later in the *same batch* resolves against stale `PATH` and silently fails (exit `9009`, zero trace in `chocolatey.log`, since `choco.exe` never actually launched). Fixed by calling Chocolatey via its full path, `C:\ProgramData\chocolatey\bin\choco.exe`, everywhere in `FirstLogonCommands`. Don't use `%ChocolateyInstall%` as an alternative — same staleness problem. Use the full path for any future `choco install` addition too.

**Same root cause resurfaces for the interactive user afterward, one layer further out**: Git's own installer *does* correctly add itself to system `PATH`, but a shell opened in that same first-logon session (before rebooting/re-logging) still has the stale copy and can show `git` as "not recognized" even though the install genuinely succeeded. Not fixable from `autounattend.xml` (no "full path" equivalent for a user just typing `git`) — the fix is logging off/on or rebooting once. If this comes up again, verify `git.exe` actually exists on disk first before suspecting the install itself.

## Fixed — `ISO_PATH_ROOT` undefined, no error handling, CRLF line endings

An earlier refactor (`457da5c`) had deleted the `ISO_PATH_ROOT` resolution block and the `ERR` cleanup trap while `win11.sh` still referenced the variable — with it always empty, downloads landed at `/` (host filesystem root, running as root) instead of Proxmox ISO storage. Restored `get_iso_path`/`DUMMY_PATH`/`ISO_PATH_ROOT` resolution + `trap cleanup ERR`, plus `set -e` right after the shebang (the `DUMMY_PATH=... || true` line is deliberately guarded so a storage-resolution failure still prints a friendly message instead of dying silently under `set -e`). Also converted the file from CRLF to LF — CRLF made `bash win11.sh` fail with a syntax error on `case ... in`. **If CRLF creeps back in (e.g. edited/saved on Windows), reflow it (`sed -i 's/\r$//' win11.sh`) — the script does not run at all as CRLF.**

If you touch ISO-handling or error-handling again:
- Avoid combining `set -e` with `set -o pipefail` without auditing every pipeline first — `download_windows_iso`'s `curl | grep | sed | tr` relies on `tr` (always exit 0) being last so a header-not-found `grep` miss doesn't kill the script; `pipefail` would break that.
- `pvesm path ...`-style lookups feeding an `if [ -z ... ]` check need `|| true` so `set -e` doesn't short-circuit past the friendly error message.

## VirtIO ISO auto-download

`win11.sh` searches ISO storage for any `virtio-win*.iso` (newest by `sort -V`) and, if none found, downloads the current stable release via `download_virtio_iso()` from `$VIRTIO_STABLE_URL` (Fedora's `stable-virtio` redirect, resolved with `curl -sIL -w '%{url_effective}'` to save under its real filename). No auth/anti-bot layer on this source, safe to script against.

## Bug found by live-testing: broken filename from Content-Disposition parsing

`download_windows_iso()`'s header-parsing regex assumed `filename=` would be quoted or last-on-line. Microsoft's CDN sends an **unquoted** `filename=...` followed by a second RFC-5987 `filename*=UTF-8''...` parameter on the same line — with no quote to bound the capture, the ISO got saved as literally `Win11_...iso; filename*=UTF-8''Win11_...iso`, which then broke `qm set --ide2` downstream with a confusing schema error that gave no hint the real problem was upstream. Fixed by also excluding `;` from the capture. A pre-existing corrupted filename on disk needs a manual `mv` — the script can't detect/repair one already there.

Added `validate_iso_filename()` (called after both `WIN_ISO`/`VIRTIO_ISO` resolve, before anything reaches `qm set`) rejecting any filename not ending in `.iso` or containing `, ; = " '`, so a similar problem from any source fails fast with an actionable message. Keep this guard if you touch ISO-resolution logic — and be careful editing its bracket-expression pattern, since backslash isn't special inside `[[ ]]` the way it is elsewhere (a stray `\x`-style escape becomes a literal `x` in the character class); test against both a clean and a broken filename before trusting an edit.

**Windows 11 ISO auto-download was deliberately NOT added.** Microsoft's download flow sits behind a purpose-built bot-detection handshake (`vlscppe.microsoft.com` session whitelisting, then an `ov-df.microsoft.com` timing/fingerprint challenge) — confirmed via Fido (`pbatard/Fido`, the tool Rufus uses), whose source comments call it Microsoft's "protection," with explicit anti-automation language on the download page itself threatening bans. Reproducing that handshake means baking a bypass of a stated anti-bot control into this repo, and it's fragile besides. Don't add this without the user explicitly re-confirming the trade-off; point here rather than re-researching from scratch. The interactive "paste the direct link" flow remains the supported path.

## Bugs found by live-testing on a real Proxmox host

None of these were catchable from a sandbox without `qm`/`pvesm` — get any `pvesm`/`qm` argument-syntax change tested on a real host before trusting it:

- **`pvesm path` probe filename needs a real extension** — Proxmox's volid parser for content type `iso` requires `.iso`/`.img`; fixed by probing `iso/dummy.iso` instead of `iso/dummy`.
- **Disk allocation size must be a bare number, no unit suffix** — `DISK_SIZE="130G"` made `qm set --scsi0` try to parse `130G` as an *existing* volume name rather than a size to allocate (`unable to parse lvm volume name`). Fixed with a bare integer GiB value. `--efidisk0`/`--tpmstate0` use size `0` (auto-sized), unaffected.
- **`qm set`'s `storage:...` argument needs quoting** — an unquoted `$WIN_ISO`/`$VIRTIO_ISO` containing a space (plausible for a browser-downloaded ISO) gets word-split into multiple `qm` arguments, failing with `400 too many arguments`. Quote every `qm set`/`qm create`/`qm status` call that takes a variable.
- **Cleanup trap now also destroys a partially created VM** — `VM_CREATED=1` after `qm create` succeeds; `cleanup()` runs `qm destroy "$VMID" --purge 1` if set, so a later failure doesn't block retries with the same `-i` VMID. Only protects runs *after* this fix — an older leftover VM needs a manual `qm destroy`.

## Runs as a non-root user via sudo

Every privileged external command (`qm`, `pvesm`, `genisoimage`, ISO-storage file operations) is prefixed with `sudo`; a preflight block checks `command -v sudo` and `sudo -v` up front.

**Deliberately NOT sudo'd:**
- `command -v curl/wget/genisoimage/sudo` — `command` is a bash builtin, `sudo command -v x` fails with "command not found".
- Bash builtins/keywords (`read`, `echo`, `[[ ]]`/`[ ]`, `local`, `trap`, `if`/`while`/`case`, etc.).
- This script's own functions — sudo execs real binaries by name, can't invoke a shell function.
- `[ ! -f "$ANSWER_FILE" ]` — checks a file in the user's own working directory, no privilege needed.

If you add a new external command: sudo it if it touches `qm`/`pvesm`/ISO storage; don't if it's a plain read on something the invoking user already owns. Existence checks on `$ISO_PATH_ROOT` paths use `sudo test -f ...` (`test` is both a builtin and a real binary, so this form works correctly under `sudo`) — do the same for any new privileged-path checks.

## Other things to keep in mind when touching `win11.sh`

- The admin password is a plaintext CLI arg (`-p`), written in plaintext into the generated `autounattend.xml` (`PlainText>true`) — lands in shell history, `ps` output, and unencrypted ISO storage. Dev/lab-only tool, not fixed, flagged for awareness only.
- `autounattend.xml` sets `LogonCount>999` under `AutoLogon` — the VM auto-logs-in as `Admin` indefinitely across reboots. Convenient for a throwaway dev VM, worth calling out if ever adapted for something longer-lived.
- Firewall fully disabled, RDP+SSH both open, combined with a plaintext/default password — materially more exposed than a stock Windows install. Fine for an isolated home-lab by explicit user request; don't quietly make this "more secure by default," but also don't let new features widen exposure further without flagging it.

## Conventions

- Bash, `#!/bin/bash`, matches the existing style in `win11.sh` (plain functions, `getopts` for flags, human-readable `echo` progress banners).
- Colored output: `info`/`success`/`warn`/`error`/`banner` helper functions wrap `printf` with ANSI codes (cyan/green/yellow/red/bold-cyan); `error` writes to stderr, the rest to stdout. Colors are looked up once into `C_*` variables guarded by `[ -t 1 ]` — don't bypass these helpers with raw `echo`/ANSI codes, and don't remove the `-t 1` guard.
- Keep the flags table in `README.md` (`-i -n -m -c -p`) in sync with the `getopts` string in `win11.sh` if either changes.
- Git remote is `teamzuzu/win11-dev-proxmox-script` on GitHub, default branch `main`. Commits so far are a mix of the original author (`Nicholas Fusaro`) and this user — commit as the actual person working, never attribute commits to Claude/an AI author.
- Code comments vs. CLAUDE.md: see the dedicated section above.
