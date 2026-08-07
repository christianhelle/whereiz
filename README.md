# whereiz

A Windows specific implementation of the `whereis` command in Unix.
This tool that tells you **where** an executable, command, or
file actually **is** on disk — and in what order Windows would find it.

`whereiz` answers questions like:

- Where does `cmd.exe` resolve from, given my `PATH`?
- Is this `.dll` picked up from the executable directory, `System32`, or somewhere else?
- What would Windows find _first_ if I run this command right now?

It replicates the Windows dynamic-link library (DLL) and executable search
order — including the `SafeDllSearchMode` registry setting and the
[KnownDLLs(https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order)
list — so the answer matches what Windows itself would load, not just "the
first match in `PATH`".

## Features

- **Mirrors the real Windows search order** — executable directory, system
  directories, working directory, and every `PATH` entry, in the exact order
  Windows probes them.
- **Respects `SafeDllSearchMode`** — reads the
  `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\SafeDllSearchMode`
  registry value and reorders the working directory accordingly.
- **Knows about KnownDLLs** — reads the KnownDLLs registry key (and
  `ExcludeFromKnownDlls`) and checks the KnownDLLs `DllDirectory` first for
  known system DLLs.
- **Command-aware search** — a bare name like `npm` is expanded to `npm.exe`,
  `npm.cmd`, and `npm.bat` and searched in that order.
- **Architecture-aware DLL lookup** — pass `x86` or `x64` to look up the
  matching KnownDLLs directory (`DllDirectory32` vs `DllDirectory`).
- **Reports every match, not just the first** — you see the full resolution
  chain, in search order.
- **Duplicate-safe** — the same file found through several directories
  (including case-insensitive duplicates) is reported exactly once.
- **Follows symlinks** — a candidate that is a symlink (even a broken one) is
  reported, matching how Windows treats it as present.
- **No runtime dependencies** — a single self-contained executable.

---

## Installation

### Option 1: One-liner (recommended)

Install the latest release and add it to your user `PATH`:

```powershell
irm https://christianhelle.com/whereiz/install | iex
```

The installer downloads the official release binary into
`%USERPROFILE%\.local\bin` by default, adds that directory to your user `PATH`,
and verifies the install. Restart your terminal afterwards.

The installer supports these parameters:

```powershell
# Install to a custom directory and do not touch PATH
irm https://christianhelle.com/whereiz/install | iex -InstallDir C:\tools -AddToPath $false

# Pin a specific GitHub release tag
irm https://christianhelle.com/whereiz/install | iex -Version v1.2.3
```

### Option 2: Download a release

Grab `whereiz-windows-x86_64.zip` from the
[latest release](https://github.com/christianhelle/whereiz/releases), unzip it,
and put `whereiz.exe` anywhere on your `PATH`.

### Option 3: Build from source

See [Building](#building) below.

---

## Requirements

- **Windows** (the build and the tool itself are Windows-only)
- **Zig 0.16.0 or newer** to build from source
- No third-party dependencies — just the standard library and the Windows API

---

## Building

From a checkout of this repository:

```bat
zig build
```

This produces a debug binary at `zig-out\bin\whereiz.exe`.

### Building a release binary

```bat
zig build install-release
```

This builds with `ReleaseSmall` and installs the binary as `whereiz.exe` to:

1. The install prefix, if you pass `--prefix <dir>` (e.g. `zig build install-release --prefix C:\tools`)
2. The directory in the `INSTALL_DIR` environment variable, if set
3. Otherwise `%USERPROFILE%\.local\bin` (mirroring the `~/.local/bin` convention)

If none of those can be determined, the build fails with a message telling you
to set one of them.

### Running tests

```bat
zig build test
```

Runs the full test suite:

- **`whereiz` module tests** — search order construction, command candidate
  expansion, file/command finding against a temporary directory tree.
- **`registry` module tests** — the registry key abstraction, exercised against
  a scratch key under `HKCU\Software\whereiz_registry_test` (created and
  cleaned up automatically).

---

## Usage

```bat
whereiz <query> [x86|x64] [working-directory] [executable-directory]
```

| Argument               | Meaning                                                                                                        | Default                                   |
| ---------------------- | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `<query>`              | File name, command name, or absolute path to resolve. **Required.**                                            | —                                         |
| `x86` / `x64`          | Architecture used to pick the KnownDLLs directory (`DllDirectory32` vs `DllDirectory`).                        | Architecture of the running `whereiz.exe` |
| `working-directory`    | Override the current working directory used in the search. Only honored if it is an absolute path that exists. | The actual current directory              |
| `executable-directory` | Override the directory of the calling executable. Only honored if it is an absolute path that exists.          | The directory containing `whereiz.exe`    |

Running `whereiz` with no arguments prints usage.

### Query resolution rules

- If the query contains a `.`, it is treated as a **file name** and looked up
  verbatim (e.g. `whereiz kernel32.dll`).
- If the query has no `.`, it is treated as a **command** and expanded into
  candidates, tried in order: `query.exe`, `query.cmd`, `query.bat`
  (e.g. `whereiz npm` → `npm.exe`, `npm.cmd`, `npm.bat`).
- If the query is an absolute path, it is reported as-is (once) if it exists.

### Output

One matching path per line, in search order. If nothing is found, no output is
printed.

---

## Examples

Find where `cmd.exe` resolves, everywhere:

```bat
> whereiz cmd
C:\Windows\System32\cmd.exe
```

Find the PowerShell command, including `.cmd` and `.bat` variants:

```bat
> whereiz powershell
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

Find a system DLL, honoring KnownDLLs first (x64):

```bat
> whereiz kernel32.dll x64
C:\Windows\System32\kernel32.dll
```

Resolve against a different working directory:

```bat
> whereiz node.exe x64 C:\projects\my-app
```

Resolve as if the executable lived elsewhere (useful for debugging deployed
apps):

```bat
> whereiz myapp.dll x64 C:\work C:\deployed\bin
```

---

## How the search works

`whereiz` builds a search order and probes each directory in turn, collecting
every existing match. The order depends on the machine's
`SafeDllSearchMode` setting.

### With SafeDllSearchMode **enabled** (the modern Windows default)

1. KnownDLLs directory (only for names in the KnownDLLs registry key) — the
   architecture-specific `DllDirectory`
2. The directory containing the executable (`whereiz.exe`, unless overridden)
3. The system directory (e.g. `C:\Windows\System32`)
4. `C:\Windows\System` (the legacy system directory)
5. The Windows directory (e.g. `C:\Windows`)
6. The current working directory (unless overridden)
7. Every directory in the `PATH` environment variable

### With SafeDllSearchMode **disabled** (legacy behavior)

The working directory moves up, right after the executable directory:

1. KnownDLLs directory (only for known DLLs)
2. The directory containing the executable
3. The current working directory
4. The system directory
5. `C:\Windows\System`
6. The Windows directory
7. Every directory in `PATH`

### Sources of truth

The search mirrors what Windows itself consults, read live from your machine:

- **`SafeDllSearchMode`** — `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\SafeDllSearchMode` (missing or zero → disabled)
- **KnownDLLs** — `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs` (honoring `ExcludeFromKnownDlls` and the `DllDirectory` / `DllDirectory32` values)
- **System / Windows directories** — `GetSystemDirectoryW` / `GetWindowsDirectoryW`
- **Executable directory** — the directory of the running `whereiz.exe`
- **`PATH`** — the process environment
