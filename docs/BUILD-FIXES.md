# Building DesktopEditors on a current Windows toolchain: 14 findings

A local Windows build of **DesktopEditors 9.3.1** failed at fourteen separate points between
third-party dependency setup and the finished installer. Each failure was traced to a root cause,
fixed, and the fix verified in isolation before continuing.

This document is written to be actionable: every entry names the file, the observed error, why it
happens, what was changed, and how the change was verified.

## Scope

**Sections [A](#section-a-toolchain-drift) and [C](#section-c-version-pins-in-the-build-scripts)
are independent of any local modification.** They are latent bugs that surface on any current MSVC,
Cygwin, Python or Inno Setup, and they reproduce with Boost still pinned at 1.78.

**Section [B](#section-b-fallout-from-unpinning-boost) is the cost of one deliberate local change:**
`boost/nc-build.py` was modified to clone Boost without `-b boost-1.78.0`, so it picks up the latest
release (1.92) instead. If you keep Boost pinned, section B does not apply to you — but it is a
preview of what a future Boost bump will cost.

Line numbers refer to the state of the tree before the changes described here.

## Build environment

| Component | Version |
|---|---|
| Host | Windows 11 Pro 26200 |
| Compiler | Visual Studio 18 Community, MSVC **14.51.36231**, `_MSC_VER 1951`, library tag `vc145` |
| Windows SDK | 10.0.19041.0 |
| Generator | Ninja + sccache, `-std:c++17` |
| Cygwin | 64-bit, **without** the `python3` package |
| Python | 3.14.7 (native, Microsoft Store build) |
| Inno Setup | 6.2.2, upgraded to 6.7.1 (see [C2](#c2-the-inno-setup-version-pin-contradicts-the-scripts)) |
| Boost | tracking `main` (**1.92**) instead of the pinned `boost-1.78.0` tag |

## Findings index

| ID | Failure | Category |
|---|---|---|
| [A1](#a1-vcvars-is-invoked-twice-and-overflows-the-command-line) | cmd.exe 8191-char limit, *line too long* | Toolchain |
| [A2](#a2-cygwin-link-shadows-the-msvc-linker) | `link.exe is not a valid linker` | Toolchain |
| [A3](#a3-python-is-hard-coded-to-a-path-that-need-not-exist) | `/usr/bin/python3: No such file or directory` | Toolchain |
| [A4](#a4-git-needs-long-path-support-for-the-v8-dependency-tree) | `Filename too long`, then *uncommitted changes* | Toolchain |
| [A5](#a5-the-gclient-paths-patch-no-longer-applies) | `gclient_paths.py: patch does not apply` | Toolchain |
| [A6](#a6-stdext-iterator-extensions-were-removed-from-the-msvc-stl) | `C2653: 'stdext': is not a class or namespace` | Toolchain |
| [A7](#a7-the-generated-jam-file-gets-an-unescaped-windows-path) | `Unescaped special character` in project-config.jam | Toolchain |
| [A8](#a8-the-msvc-toolset-version-is-hard-coded) | `(vc140, detected vc145)`, no suitable variant | Toolchain |
| [A9](#a9-the-inno-source-path-overflows-max_path) | MAX_PATH, *cannot find the path specified* | Toolchain |
| [B1](#b1-four-boost-submodules-are-no-longer-pulled-in-transitively) | `C1083: Cannot open include file: 'boost/variant.hpp'` | Boost 1.92 |
| [B2](#b2-boost-filesystem-wpath-no-longer-exists) | `C2039: 'wpath' is not a member of 'boost::filesystem'` | Boost 1.92 |
| [B3](#b3-header-only-boost-regex-still-triggers-auto-linking) | `LNK1104: cannot open libboost_regex-vc145-mt-x64-1_92.lib` | Boost 1.92 |
| [C1](#c1-architecturesallowed-uses-the-wrong-version-threshold) | `ArchitecturesAllowed` is invalid | Version pin |
| [C2](#c2-the-inno-setup-version-pin-contradicts-the-scripts) | `WizardStyle` is invalid | Version pin |

## Files changed

Twelve files. Paths are relative to the repository root.

| File | Findings |
|---|---|
| `core/Common/3dParty/icu/nc-build.bat` | A1 |
| `core/Common/3dParty/icu-desktop/nc-build.bat` | A1 |
| `core/Common/3dParty/icu/nc-build-cygwin.sh` | A2, A3 |
| `core/Common/3dParty/icu-desktop/nc-build-cygwin.sh` | A2, A3 |
| `core/Common/3dParty/v8/nc-build.py` | A4, A5 |
| `core/Common/3dParty/cryptopp/integer.cpp` | A6 |
| `core/Common/3dParty/cryptopp/zdeflate.cpp` | A6 |
| `core/Common/3dParty/boost/nc-build.py` | A7, A8, B1 |
| `desktop-sdk/ChromiumBasedEditors/lib/src/cefwrapper/client_renderer_wrapper.cpp` | B2 |
| `core/common.cmake` | B3 |
| `desktop-apps/package/inno/common.iss` | A9, C1 |
| `build/windows/build.ps1` | C2 |

The two `icu` / `icu-desktop` pairs received identical changes; `icu-desktop` is not reached by the
current desktop build but carries the same defects.

---

# Section A. Toolchain drift

Independent of the Boost version. These break on any current MSVC, Cygwin or Inno Setup.

## A1. vcvars is invoked twice and overflows the command line

**Files:** `core/Common/3dParty/icu/nc-build.bat`, `core/Common/3dParty/icu-desktop/nc-build.bat`

### Symptom

```text
-- Python script error: Aborting ICU: Cygwin build failed: Die eingegebene Zeile ist zu lang.
Syntaxfehler.
```

(*"The input line is too long. Syntax error."*)

### Cause

`build/windows/build.ps1` already loads the complete MSVC environment into the process
(`Import-VcVars`), so `VCINSTALLDIR`, `PATH`, `INCLUDE` and `LIB` are inherited all the way down to
`nc-build.bat`. The batch then calls `vcvars` **again**, which prepends every MSVC and SDK directory
onto the already long `PATH`. The result exceeds cmd.exe's 8191-character command-line limit and the
batch dies before doing any work.

The file already reads `VSCMD_ARG_TGT_ARCH`, so it is aware the caller may have set up MSVC. It just
did not act on it.

### Fix

Reuse the inherited environment when it is present:

```bat
if defined VCINSTALLDIR (
  echo MSVC environment already active ^(VCINSTALLDIR set^) - reusing it, skipping vcvars.
  REM Cygwin is already on the inherited PATH; append (not prepend) so MSVC's
  REM link.exe still precedes Cygwin's /usr/bin/link.
  set "PATH=%PATH%;%CYGWIN_BIN%"
) else (
  REM Fresh shell: Cygwin first, then let vcvars prepend MSVC on top -> MSVC first.
  set "PATH=%CYGWIN_BIN%;%PATH%"
  call "%VCVARS%" || exit /b 1
)
```

Standalone use from a plain shell is unaffected: that branch still calls `vcvars`. Note the
deliberate asymmetry in `PATH` order, which matters for [A2](#a2-cygwin-link-shadows-the-msvc-linker).

---

## A2. Cygwin link shadows the MSVC linker

**Files:** `core/Common/3dParty/icu/nc-build-cygwin.sh`,
`core/Common/3dParty/icu-desktop/nc-build-cygwin.sh`

### Symptom

```text
configure: error: link.exe is not a valid linker. Your PATH is incorrect.
                  Please follow the directions in ICU's readme.
```

### Cause

ICU's `configure` runs `link --version` and aborts if the output contains `GNU coreutils`. Cygwin
ships such a `link` in `/usr/bin`, and depending on the inherited `PATH` order it wins over MSVC's
`link.exe` — even though `cl` resolves correctly.

Measured on the failing machine:

```text
> where link
C:\cygwin64\bin\link.exe
C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\link.exe

> link --version
link (GNU coreutils) 9.0
```

### Fix

Front-load the directory `cl` lives in, which also contains `link.exe`, right before
`runConfigureICU`:

```sh
msvc_bin=""
cl_path="$( command -v cl 2>/dev/null || true )"
if [ -n "$cl_path" ]; then
    msvc_bin="$( dirname "$cl_path" )"
elif [ -n "$VCToolsInstallDir" ]; then
    msvc_bin="$( cygpath -u "$VCToolsInstallDir" )/bin/Hostx64/x64"
fi
if [ -n "$msvc_bin" ] && [ -x "$msvc_bin/link.exe" ]; then
    export PATH="$msvc_bin:$PATH"
fi
```

### Verified

With Cygwin deliberately placed first in `PATH`, ICU's exact test
(`link --version | grep 'GNU coreutils'`) matched before the change and no longer matches after it.

---

## A3. PYTHON is hard coded to a path that need not exist

**Files:** `core/Common/3dParty/icu/nc-build-cygwin.sh`,
`core/Common/3dParty/icu-desktop/nc-build-cygwin.sh`

### Symptom

```text
checking for python3... /usr/bin/python3
...
Spawning Python to generate data/rules.mk...
./configure: line 9297: /usr/bin/python3: No such file or directory
configure: error: Python failed to run; see above error.
```

### Cause

The script exported `PYTHON=/usr/bin/python3` unconditionally. autoconf accepts a preset value
**without testing it**, which is why `configure` reported that it "found" python3 and only failed
when the interpreter was actually executed. On this machine Cygwin's `python3` package was not
installed at all.

### Fix

Detect instead of assume:

```sh
if [ -x /usr/bin/python3 ]; then
    export PYTHON=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then
    export PYTHON="$( command -v python3 )"
elif command -v python >/dev/null 2>&1; then
    export PYTHON="$( command -v python )"
else
    echo "ERROR: no Python 3 found. Install Cygwin's python3, or ensure a native python3 is on PATH." >&2
    exit 1
fi
```

### Verified

Falling back to a *native* Windows Python is safe, because ICU's `icutools.databuilder` normalizes
path separators to `/` regardless of platform (`python/icutools/databuilder/__main__.py`, `IO.glob`).
Running the databuilder with native Python 3.14 produced exit code 0, a valid 28,840-line
`rules.mk`, and zero backslashes in the output.

---

## A4. git needs long path support for the v8 dependency tree

**File:** `core/Common/3dParty/v8/nc-build.py`

### Symptom

```text
v8/buildtools/third_party/libc++/trunk (ERROR)
----------------------------------------
Error: 24>
24> ____ v8\buildtools\third_party\libc++\trunk at d9040c75cfea5928c804ab7c235fed06a63f743a
24>     You have uncommitted changes.
24>     cd into v8\buildtools\third_party\libc++\trunk, run git status to see changes,
24>     and commit, stash, or reset.
```

### Cause

Some v8 dependency paths exceed `MAX_PATH` — for example
`buildtools/third_party/libc++/trunk/test/std/thread/...` at 264 characters. git cannot write those
files, reports `Filename too long`, and the unwritten file then shows up as a local deletion, which
is what produces the misleading "uncommitted changes" abort.

The Windows-wide `LongPathsEnabled` registry flag does **not** cover this. git needs its own opt-in.

### Fix

Set it for every git process, including the ones gclient spawns internally, which cannot be reached
with `-c`:

```python
if nc.is_windows():
    os.environ[ "GIT_CONFIG_COUNT" ] = "1"
    os.environ[ "GIT_CONFIG_KEY_0" ] = "core.longpaths"
    os.environ[ "GIT_CONFIG_VALUE_0" ] = "true"
```

`GIT_CONFIG_COUNT` / `KEY` / `VALUE` (git >= 2.31) outranks system and global config, so this needs
no change to the user's `~/.gitconfig` — which on this machine did not exist, producing the harmless
`Failed to read your global Git config` warning from depot_tools.

> ### Do not also set core.autocrlf=false
>
> depot_tools recommends it and it looks harmless. It is not.
>
> The v8 trees are checked out with CRLF, while the patches under `tools/8.9/` are LF. `git apply`
> only matches their context when git normalizes line endings, that is, with `autocrlf=true` (the
> Git-for-Windows default). Forcing it to `false` makes **every** patch fail with
> `patch does not apply`.
>
> Measured on the same tree: `git apply --check jinja2.patch` succeeds with `autocrlf=true` and
> fails with `autocrlf=false`. Only `core.longpaths` is needed here.

---

## A5. The gclient paths patch no longer applies

**File:** `core/Common/3dParty/v8/nc-build.py`
(patch: `core/Common/3dParty/v8/tools/8.9/x64-linux-dynamic/gclient_paths.patch`)

### Symptom

```text
-- Python script error: Aborting V8: Applying patch: gclient_paths.patch failed:
error: patch failed: gclient_paths.py:20
error: gclient_paths.py: patch does not apply
```

### Cause

depot_tools is cloned from `main` and then pulled, so it always tracks HEAD. The patch context no
longer matches:

| | Patch expects | Current depot_tools |
|---|---|---|
| Quoting | `filename='.gclient'` | `filename=".gclient"` |
| Cached helpers | 4 | 5, `_GetGClientConfigInner` was added |

`git apply` is context-sensitive, so any upstream reformatting breaks it.

### Fix

The patch's only effect was neutralizing `@functools.lru_cache` decorators. Expressing that intent
textually is formatting-independent, idempotent, and also covers helpers added later:

```python
def disable_gclient_paths_cache():
    target = depot_tools_path / "gclient_paths.py"
    if not target.is_file():
        print( "[WARNING] gclient_paths.py not found, skipping lru_cache removal!" )
        return

    lines = target.read_text( encoding = "utf-8" ).splitlines( keepends = True )
    kept = [ l for l in lines
             if not re.match( r"^\s*@functools\.lru_cache(\s*\(.*\))?\s*$", l ) ]

    removed = len( lines ) - len( kept )
    if removed:
        target.write_text( "".join( kept ), encoding = "utf-8" )
    print( f"Disabled { removed } @functools.lru_cache decorator(s) in gclient_paths.py" )
```

`gclient_paths.patch` was removed from the `patches` list and this function is called from
`apply_patches()` instead. Dropping a memoization decorator cannot change results, only speed.

### Verified

Five decorators removed; a second run removes zero (idempotent); the file still compiles. The other
four patches (`jinja2`, `buildgn`, `win_toolchain`, `vs_toolchain`) were confirmed to still apply
with `git apply --check` and were left untouched.

> **Worth considering upstream:** pin depot_tools to a known commit instead. That makes the build
> reproducible, at the cost of possibly needing an older Python — note that `create_fake_pipes_shim()`
> in the same file already works around `pipes` having been removed in Python 3.13.

---

## A6. stdext iterator extensions were removed from the MSVC STL

**Files:** `core/Common/3dParty/cryptopp/integer.cpp`, `core/Common/3dParty/cryptopp/zdeflate.cpp`

### Symptom

```text
core\Common\3dParty\cryptopp\integer.cpp(3061): error C2653: 'stdext': is not a class or namespace
core\Common\3dParty\cryptopp\integer.cpp(3061): error C3861: 'make_checked_array_iterator': identifier not found
```

### Cause

`stdext::make_checked_array_iterator`, `stdext::unchecked_mismatch` and
`stdext::make_unchecked_array_iterator` are Microsoft extensions that have been **removed** from the
MSVC STL. Not a single occurrence remains in the 14.51 headers.

cryptopp selects them through raw version comparisons, which can never be correct for a *removal*:

| Guard | Value on this toolchain | Result |
|---|---|---|
| `_MSC_VER` | 1951 | |
| `_STDEXT_BEGIN` | **undefined** | the namespace is gone |
| `_MSC_VER >= 1500` (`integer.cpp`) | true | selects `stdext`, error |
| `_MSC_VER >= 1600` (`zdeflate.cpp`) | true | selects `stdext`, error |

### Fix

Use the feature test the file **already** uses for its function-name selection — `zdeflate.cpp:416`
tests `defined(_STDEXT_BEGIN)`:

```cpp
// integer.cpp
#if (_MSC_VER >= 1500) && defined(_STDEXT_BEGIN)

// zdeflate.cpp
#if _MSC_VER >= 1600 && defined(_STDEXT_BEGIN)
```

`_STDEXT_BEGIN` is the macro the MSVC headers use to open that namespace, so this is correct in both
directions: older MSVC keeps the existing path, newer MSVC takes the portable one. The wrappers only
added debug-time bounds checking and warning suppression, so the fallback branches are semantically
equivalent.

### Verified

Both files compile clean with the exact flags ninja used for `CryptoPPLib`. `zdeflate.cpp` would
have failed immediately after `integer.cpp`, so both were fixed together rather than one build cycle
apart.

---

## A7. The generated jam file gets an unescaped Windows path

**File:** `core/Common/3dParty/boost/nc-build.py`

### Symptom

```text
project-config.jam:7: Unescaped special character in argument
  C:Program FilesMicrosoft Visual Studio18CommunityVCToolsMSVC14.51.36231\binHostx64x64cl.exe

warning: Did not find command for MSVC toolset. If you have Visual Studio 2017 installed
you will need to specify the full path to the command...
```

### Cause

The generated `project-config.jam` contained single backslashes inside a quoted string. Jam treats
`\` as an escape character, so the path collapses and b2 silently falls back to whatever `cl.exe`
happens to be on `PATH`. The build only worked by accident.

The file already contains a `jam_path()` helper that doubles separators for exactly this purpose. It
was never called.

### Fix

```python
cl_path = jam_path(
    Path( os.environ[ "VCToolsInstallDir" ] ) / "bin" / host_subdir / "cl.exe"
)
```

…used as `using msvc : { msvc_version } : "{ cl_path }";`. The path is built outside the f-string
because backslashes inside f-string expressions require Python >= 3.12.

### Verified

Simulating jam's escape handling, the old form resolves to `C:Program FilesMicrosoft...` — exactly
matching the warning above — and the new form to the correct path.

---

## A8. The MSVC toolset version is hard coded

**File:** `core/Common/3dParty/boost/nc-build.py`

### Symptom

```text
CMake Error: Found package configuration file:
    .../boost/lib/cmake/boost_filesystem-1.92.0/boost_filesystem-config.cmake
  but it set boost_filesystem_FOUND to FALSE so package "boost_filesystem" is
  considered to be NOT FOUND. Reason given by package:

  No suitable build variant has been found.
  * libboost_filesystem-vc140-mt-x64-1_92.lib (vc140, detected vc145, set Boost_COMPILER to override)
```

### Cause

`project-config.jam` declared `using msvc : 14.0` while pointing at `cl.exe` from MSVC 14.51. Boost
derives the library **name tag** from that declaration — `common.jam`'s `toolset-tag` joins major
and minor, so `14.0` becomes `vc140` and `14.5` becomes `vc145`.

The libraries were therefore compiled by the correct compiler but *named* `vc140`, while CMake's
`BoostConfig` computes `vc145` from the compiler it detects and rejects them.

This is independent of the Boost version: it breaks on any MSVC that is not 14.0.

### Fix

Derive it from the toolchain actually in use. MSVC's tag keeps only the **first digit** of the minor
version:

```python
def boost_msvc_toolset_version() -> str:
    ver = os.environ.get( "VCToolsVersion", "" )     # e.g. 14.51.36231
    parts = ver.split( "." )
    if len( parts ) < 2 or not parts[ 0 ].isdigit() or not parts[ 1 ][ :1 ].isdigit():
        nc.abort_op(
            f"Cannot derive the MSVC toolset version from VCToolsVersion={ ver!r }. "
            "Is the MSVC environment loaded (vcvars)?"
        )
    return f"{ parts[ 0 ] }.{ parts[ 1 ][ 0 ] }"
```

### Verified

Across every MSVC generation:

| `VCToolsVersion` | Derived | Tag | Toolset |
|---|---|---|---|
| 14.51.36231 | 14.5 | `vc145` | VS 18 |
| 14.44.35207 | 14.4 | `vc144` | VS2022 17.10+ |
| 14.39.33519 | 14.3 | `vc143` | VS2022 |
| 14.29.30133 | 14.2 | `vc142` | VS2019 |
| 14.16.27023 | 14.1 | `vc141` | VS2017 |
| 14.00.24210 | 14.0 | `vc140` | VS2015 |
| *(empty)* | — | aborts with a clear message | vcvars not loaded |

---

## A9. The Inno source path overflows MAX_PATH

**File:** `desktop-apps/package/inno/common.iss`

### Symptom

After successfully compressing roughly 3,600 files:

```text
Compressing: C:\...\desktop-apps\package\inno\..\build\x64\desktop\converter\templates\RU\Forms\[32]2CP5...===.pdf
Error in C:\...\desktop-apps\package\inno\common.iss: Das System kann den angegebenen Pfad nicht finden.
```

(*"The system cannot find the path specified."*)

### Cause

`iscc` runs with `inno\` as its working directory — `make_inno.ps1` does `Push-Location "inno"` —
and `BUILD_DIR` was relative:

```text
#define BUILD_DIR '..\build\' + ARCH
```

The resolved path therefore contains the detour `package\inno\..\build\...`, which is eight extra
characters. The longest staged file, a base32-named template, is 256 characters canonically; with the
detour it is **264**, past `MAX_PATH` (260).

Confirmed at the Win32 layer: `GetFileAttributes` returns `err=0` on the canonical path and `err=3`
(`ERROR_PATH_NOT_FOUND`) on the detour path, which is exactly the message above.

### Fix

Build it absolute and already normalized:

```text
#define BUILD_DIR ExtractFileDir(ExtractFileDir(SourcePath)) + '\build\' + ARCH
```

`ExtractFileDir` is applied twice because ISPP's `SourcePath` carries a trailing backslash, so one
call only strips that (verified with a probe script). The `#ifndef BUILD_DIR` guard is kept, so an
external `/DBUILD_DIR=...` still wins.

### Verified

Measured over the whole staging tree: 3,636 files, longest canonical path 256 characters. With the
detour exactly **one** file exceeds the limit; without it, **none**.

> **Only four characters of headroom remain.** A deeper checkout path will break this again. If you
> want this robust rather than merely working, either shorten the staging layout or move to
> long-path-aware packaging.

---

# Section B. Fallout from unpinning Boost

These appear only because Boost is no longer pinned to `boost-1.78.0`. Boost 1.92 is fourteen
releases newer and has removed a lot of v2-era API in between.

## B1. Four Boost submodules are no longer pulled in transitively

**File:** `core/Common/3dParty/boost/nc-build.py`

### Symptom

```text
third_party\install\apple\libetonyek\src\lib\IWORKTypes.h(20): fatal error C1083:
  Cannot open include file: 'boost/variant.hpp': No such file or directory
```

### Cause

The script checks out only a subset of Boost submodules; everything else has to arrive as a
`boostdep`-resolved dependency of one of them. Boost has been migrating away from Boost.Variant
towards `std::variant`, so on 1.92 these four are no longer dragged in:

| Module | Needed by |
|---|---|
| `variant` | libetonyek (`IWORKTypes.h`) |
| `spirit` | librevenge (`RVNGPropertyList.cpp`), OFDFile |
| `ptr_container` | libetonyek |
| `serialization` | librevenge, the base64 iterators under `boost/archive/` |

> **Easy to get wrong:** `boost/archive/**` ships in the **serialization** module. There is no Boost
> module called `archive` (confirmed against `.gitmodules`). Those base64 iterators are pure
> templates, so headers alone are enough and serialization does not have to be built.

### Fix

```python
header_only_modules_needed = [ "any", "asio", "beast", "foreach", "format", "functional",
                               "multi_index", "ptr_container", "serialization", "spirit",
                               "uuid", "variant" ]
```

### Verified

Rather than discovering one missing header per build cycle, all **75** distinct
`#include <boost/...>` paths in the compiled sources were cross-checked against the install tree.
Exactly 16 headers were missing, and all 16 map to those four modules.

---

## B2. boost filesystem wpath no longer exists

**File:** `desktop-sdk/ChromiumBasedEditors/lib/src/cefwrapper/client_renderer_wrapper.cpp`

### Symptom

```text
client_renderer_wrapper.cpp(2001): error C2039: 'wpath' is not a member of 'boost::filesystem'
client_renderer_wrapper.cpp(2001): error C2065: 'wpath': undeclared identifier
client_renderer_wrapper.cpp(2001): error C2146: syntax error: missing ';' before identifier 'current_path'
```

### Cause

`wpath` is Boost.Filesystem **v2** and has been removed. In v3, `boost::filesystem::path` is already
wide on Windows: its `value_type` is `wchar_t`.

### Fix

`wpath` becomes `path` at all six occurrences, lines 2001-2004 and 4430-4433:

```cpp
boost::filesystem::path current_path = m_sLocalFileSrc;
boost::filesystem::path request_path = sRequestPath;

boost::filesystem::path relativePath = boost::filesystem::relative(request_path, current_path.parent_path());
```

The surrounding code passes `std::wstring` in and calls `.wstring()` on the result; both remain
valid, so this is a drop-in replacement. A project-wide search found no other uses of `wpath`.

### Verified

The file compiles clean with the exact flags ninja used for `ascdocumentscore`.

---

## B3. Header only Boost regex still triggers auto linking

**File:** `core/common.cmake`

### Symptom

While linking `x2tlib`:

```text
LINK : fatal error LNK1104: Datei "libboost_regex-vc145-mt-x64-1_92.lib" kann nicht geöffnet werden.
```

…although that file **exists** in `third_party/install/boost/lib`.

### Cause

Boost.Regex is header-only since Boost 1.77, so `Boost::regex` is now an `INTERFACE` imported
target. The compiled artifact survives only as the legacy `Boost::regex_old`.

For **compiled** components, Boost's own CMake config sets `BOOST_<LIB>_NO_LIB` as an interface
compile definition. That is where `-DBOOST_FILESYSTEM_NO_LIB` and friends on the compiler command
line come from, and it switches off the auto-link `#pragma` in the headers because CMake passes the
`.lib` path itself.

A header-only target gets **neither** that define **nor** a library directory, yet
`boost/regex/v5/cregex.hpp:29` still emits the pragma. On Boost 1.78, regex was a compiled
component, so the define came for free and this never surfaced.

### Fix

Restore what Boost's own CMake used to do, right after `find_package`:

```cmake
find_package( Boost REQUIRED COMPONENTS system filesystem regex date_time )
add_definitions(-DBOOST_REGEX_NO_LIB)
```

### Verified

Reproduced in isolation, with no library directory on the link line:

| Translation unit | Result |
|---|---|
| `#include <boost/regex.hpp>`, no define | links fine, does **not** trigger auto-link |
| `#include <boost/cregex.hpp>`, no define | `Linking to lib file: libboost_regex-vc145-mt-x64-1_92.lib` then **LNK1104** |
| `#include <boost/cregex.hpp>`, `-DBOOST_REGEX_NO_LIB` | links clean |

A runtime check confirmed regex works fully header-only (`regex_search` matched as expected), so no
library is needed at all.

---

# Section C. Version pins in the build scripts

## C1. ArchitecturesAllowed uses the wrong version threshold

**File:** `desktop-apps/package/inno/common.iss`

### Symptom

```text
Error on line 83 in ...\common.iss: Value of [Setup] section directive "ArchitecturesAllowed" is invalid.
Compile aborted.
```

### Cause

The gate assumed the `x64compatible` identifier exists from Inno Setup **6.0**. It was introduced in
**6.3**. Every compiler from 6.0 to 6.2.x therefore takes the second branch and emits a value it does
not know.

### Fix

```text
#if Ver < EncodeVer(6,3,0) & ARCH == "x64"
ArchitecturesAllowed              = x64
ArchitecturesInstallIn64BitMode   = x64
#elif Ver >= EncodeVer(6,3,0) & ARCH == "x64"
ArchitecturesAllowed              = x64compatible
ArchitecturesInstallIn64BitMode   = x64compatible
#elif ARCH == "arm64"
...
```

| Inno version | Value | |
|---|---|---|
| < 6.0 | `x64` | unchanged |
| 6.0 - 6.2.x | `x64` | **was broken, now correct** |
| >= 6.3 | `x64compatible` | unchanged |

### Verified

On Inno 6.2.2 the corrected gate takes the pre-6.3 branch and compiles successfully.

This fix is moot if you require Inno >= 6.3 (see
[C2](#c2-the-inno-setup-version-pin-contradicts-the-scripts)), but it costs nothing and makes the
script correct on its own terms.

---

## C2. The Inno Setup version pin contradicts the scripts

**File:** `build/windows/build.ps1`

### Symptom

```text
Error on line 104 in ...\common.iss: Value of [Setup] section directive "WizardStyle" is invalid.
Compile aborted.
```

### Cause

`common.iss` uses three directives that require Inno Setup **6.3 or newer**, and the matching assets
are already in the repository — seven sizes each of `WizImage-Dark-*.png` and
`WizSmallImage-Dark-*.png`:

| Line | Directive | Since |
|---|---|---|
| 104 | `WizardStyle=classic dynamic` | 6.3 |
| 107 | `WizardImageFileDynamicDark` | 6.3 |
| 109 | `WizardSmallImageFileDynamicDark` | 6.3 |

`build.ps1` installed **6.2.2**. The same file pins the unofficial language files to `is-6_7_1`, with
the comment *"Pin `$issTag` to the tag matching your Inno version"*. The two pins contradict each
other:

```powershell
$issTag  = 'is-6_7_1'                                    # line 190
choco install innosetup --version=6.2.2 -y --no-progress # line 280
```

### Fix

```powershell
choco install innosetup --version=6.7.1 -y --no-progress
```

Verified available on Chocolatey; the resulting compiler reports `Inno Setup 6.7.1` and accepts all
three directives. `Sync-InnoLanguages` re-stages the language files on every packaging build, so
compiler and translations end up consistent automatically.

The alternative — gating the three directives behind `#if Ver >= EncodeVer(6,3,0)` — was rejected
because it would silently drop dark-mode wizard artwork that is already shipped in the repository.

---

# Recommendations

1. **Sections A and C are worth taking upstream as-is.** They are latent bugs that surface on any
   current MSVC, Cygwin, Python or Inno Setup, independent of the Boost question.

2. **Two build scripts hard-code a value where they should detect one:**
   [A3](#a3-python-is-hard-coded-to-a-path-that-need-not-exist) (`PYTHON`) and
   [A8](#a8-the-msvc-toolset-version-is-hard-coded) (the MSVC toolset). Both now derive it from the
   environment. That pattern is worth applying to similar spots.

3. **Two guards use a version comparison where a feature test is correct:**
   [A6](#a6-stdext-iterator-extensions-were-removed-from-the-msvc-stl) (`stdext`) and, in a different
   form, [C1](#c1-architecturesallowed-uses-the-wrong-version-threshold). A version comparison cannot
   express "this API was removed" — only a feature test can.

4. **Decide explicitly whether Boost stays pinned.** Section B is the full cost of unpinning it at
   1.92. If you do unpin, note that the module list in `boost/nc-build.py` becomes load-bearing:
   every Boost header the project includes must be reachable from it, and Boost keeps shrinking the
   transitive closure with each release.

5. **The Inno path budget is nearly exhausted**
   ([A9](#a9-the-inno-source-path-overflows-max_path), four characters spare). Worth addressing
   before the staging layout grows.

# How these fixes were verified

Each fix was checked on its own rather than by re-running the full build and hoping, using whichever
of these applied:

- compiling the affected translation unit with the exact flags ninja used for its target
  ([A6](#a6-stdext-iterator-extensions-were-removed-from-the-msvc-stl),
  [B2](#b2-boost-filesystem-wpath-no-longer-exists));
- reproducing the failure with and without the change in a minimal test case
  ([B3](#b3-header-only-boost-regex-still-triggers-auto-linking),
  [C1](#c1-architecturesallowed-uses-the-wrong-version-threshold));
- measuring the underlying condition directly — `GetFileAttributes` error codes
  ([A9](#a9-the-inno-source-path-overflows-max_path)), `link --version` output
  ([A2](#a2-cygwin-link-shadows-the-msvc-linker)), path-length statistics over the whole staging tree
  ([A9](#a9-the-inno-source-path-overflows-max_path));
- checking the derived value against every input it must handle
  ([A8](#a8-the-msvc-toolset-version-is-hard-coded), six MSVC generations plus the empty case);
- enumerating the full problem space instead of one instance
  ([B1](#b1-four-boost-submodules-are-no-longer-pulled-in-transitively), all 75 Boost includes
  cross-checked against the install tree; `git apply --check` run against all remaining v8 patches).
