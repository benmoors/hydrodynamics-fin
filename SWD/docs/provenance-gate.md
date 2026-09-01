# Provenance gate — `BinaryFormatter` deserialisation in `swd_extract.ps1`

**Status: APPLIED and verified, 2026-08-27.** Layer A only. Layer B (a `SerializationBinder`
type allowlist) was considered and deliberately **not** applied — see §6.

This replaces `pending-security-fix.md`, which described a proposed patch that itself carried two
defects. Both are fixed here, by construction rather than by adding another check.

---

## 1. What the problem was

`swd_extract.ps1` deserialises `.fyn*` files with `BinaryFormatter`, and finds them by recursive
glob rather than being handed one file at a time. `BinaryFormatter.Deserialize` on an
attacker-controlled stream is arbitrary code execution in the calling process at the caller's
privilege. This is not a contested reading: Microsoft's position is that the type cannot be made
secure. It is obsolete-as-error from .NET 5 and removed outright in .NET 9 — which is precisely why
this script is pinned to Windows PowerShell 5.1.

The usual mitigation, *"these are the user's own files"*, does not hold here. Two measured facts:

| Evidence | Value |
|---|---|
| Distinct `shaper_name` values in the library (measured before the column was dropped) | `AWaterSurfClub`, `Helicier`, `Jef`, `jef`, `jf iglesias`, `SWD_shared`, `WaterMan` |
| Where the library lives | a cloud-synced OneDrive path |

So the tree holds board files authored by other people and is cloud-synced. A file that merely
*arrives* — by sync, or traded between shapers, which is normal practice — was deserialised on the
next run without anyone opening it.

**The gap was specific and self-inflicted.** SWD itself deserialises only what you explicitly open
through its GUI. This script auto-opened everything in the tree. That is a strictly wider trust
boundary than the application's own, created by the extraction tool rather than inherited from SWD.

## 2. What was applied

Nothing is deserialised unless its **content hash** is already approved.

A hash, not a path: a path allowlist would still trust a file whose bytes changed underneath it.
The check runs *first* in `Read-SwdFile`, so `BinaryFormatter` never sees an unapproved stream.

| Parameter | Purpose |
|---|---|
| `-TrustCurrentLibrary` | Record the library as it stands into the manifest, then exit without extracting |
| `-TrustManifest <path>` | Where the manifest lives. Defaults to `%LOCALAPPDATA%\swd-extract\trusted_files.json` |
| `-AllowUntrustedFiles` | Escape hatch. Off by default, and reported loudly when used |

### Normal use

```powershell
# once, when you believe the library is clean
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1" -TrustCurrentLibrary

# every run after that
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1"
```

A refused file is **never silent**. It is listed by relative path, and the summary states that the
tables are incomplete by exactly those files — because a short dataset reported as a success is the
failure mode this whole QA loop exists to prevent.

## 3. The two defects in the proposed patch, and how each was closed

**Defect 1 — the patch added a write target outside the containment guard.** `$TrustManifest` was a
caller-supplied parameter written with `[IO.File]::WriteAllText` and no containment check, so an
explicitly supplied value would write into the install directory or the library.

*Closed by* putting `$TrustManifest` through the same treatment as `-OutDir`: `$PWD` anchoring, a
`\\` refusal, canonicalisation, and `Test-PathUnderRoot` against every protected root. Verified —
all three protected targets refused, a legitimate path accepted, nothing created in either tree.

**Defect 2 — the patch reintroduced the privacy leak that round 3 had just removed.** The manifest
defaulted into `SWD/data` (publishable) and its body contained `biblio = $BiblioPath`, i.e. the full
user-and-tenant path.

*Closed twice over.* The manifest now defaults to `%LOCALAPPDATA%\swd-extract\`, outside the repo
entirely, so it cannot be committed. And it stores only **library-relative** paths plus SHA-256
hashes, never an absolute one. Verified: the 372-entry manifest contains no username, no tenant and
no `C:\`.

## 4. Verification

Every row was run, not reasoned.

| Check | Result |
|---|---|
| Cold run, no manifest | all **159** files refused; tables reported INCOMPLETE |
| `-TrustCurrentLibrary` then normal run | **27/27** boards, **132/132** reports, `polar blocks 1890/1890` |
| All four CSVs before vs after the gate | **byte-identical** — control flow changed, data did not |
| Manifest contents (372 entries, 80 KB) | no `moors`, no `Monash`, no `C:\` |
| Tampered file (1 byte, same path, same length) | refused **by name**, tables flagged incomplete |
| Valid but never-approved file arrives | refused by name; after `-TrustCurrentLibrary`, parses 3/3 |
| Byte-identical copy at a new path | admitted — correct for a content gate (§5) |
| `-TrustManifest` into install / library / library parent | all **refused**; nothing created |
| `-AllowUntrustedFiles` | works, and prints `PROVENANCE GATE BYPASSED` |
| Pester | **133 passed / 0 failed** |
| PSScriptAnalyzer | no new categories; the same 3 accepted findings |

## 5. What this does NOT do — read this before relying on it

- **It does not make `BinaryFormatter` safe.** A hostile file built only from approved hashes is
  still deserialised. Microsoft's position stands: the type cannot be secured. The real fix is to
  stop using it, which means reimplementing SWD's on-disk format — a large piece of work, out of
  scope for data acquisition.
- **It is trust-on-first-use.** `-TrustCurrentLibrary` blesses whatever is present at that moment,
  including anything hostile that already arrived. Its value is detecting *change* and *new
  arrivals* after that baseline, not validating the baseline itself. Run it when you believe the
  library is clean, not reflexively.
- **It trusts content, not location.** A byte-identical copy at a new path is admitted, because the
  same bytes are the same bytes. This is intended, and it is why a hash beats a path allowlist.
- **The baseline recorded on 2026-08-27 covers 372 files.** It was taken on a library that had
  already been in place for some time; it is not a proof that those files are benign.

## 6. Why Layer B was not applied

A `SerializationBinder` type allowlist is real defence in depth, but:

- Producing the allowlist requires first running a *logging* binder across the library — which runs
  with exactly the exposure this gate exists to remove, because enumerating types in a
  `BinaryFormatter` stream without deserialising it needs an NRBF reader, and `System.Formats.Nrbf`
  is .NET 9+, unavailable on the .NET Framework 4.8 host this script is pinned to.
- A missed type is caught by `Read-SwdFile` and returned as `$null`, so it becomes a counted parse
  failure and its rows vanish. The current run is 27/27 and 132/132; a silent reduction there is the
  exact class of defect this loop has already caught twice.

If it is ever added, verify against those two counts before trusting a run.

## 7. Operational note for Phase 2

Each hydroscan writes new `.fynrhydro` files, which the gate will refuse until approved. After a
scan session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1" -TrustCurrentLibrary
```

The friction is deliberate and it is the point: it converts "a file appeared and was executed" into
"a file appeared and someone decided". Do not reach for `-AllowUntrustedFiles` to avoid it — that
disables the gate for the whole run and says so in the output.

An alternative worth considering if Phase 2 starts pulling in board files from other shapers: run
the extraction in a throwaway VM. That is strictly stronger than any of this and needs no code
change at all.
