# MuPAD Light 2.5 in the browser (Boxedwine)

MuPAD Light 2.5 (SciFace, 2002), the Windows computer algebra system, running in the
browser on [Boxedwine](https://github.com/danoon2/Boxedwine)'s multi-threaded web build
with Wine 11.

```
./build.sh                       # -> dist/
cd dist && python3 -m http.server 8000   # open http://localhost:8000/
```

Upload `dist/` to any static host; `coi-serviceworker.js` supplies the cross-origin
isolation the multi-threaded build needs (GitHub Pages works).

Needs bash, curl, unzip, zip, python3 and msitools (`apt install msitools` /
`brew install msitools`). Options are documented at the top of `build.sh`; by default
it uses the prebuilt Boxedwine 26R1 web binaries, `BOXEDWINE_BUILD=source` compiles
them with emscripten (with `patches/`).

## Files

| | |
|---|---|
| `source/mupad_light_250.exe` | the MuPAD Light 2.5.0 installer (sha256 `29be67d1…f89940`); downloaded from the Internet Archive if missing |
| `build.sh` | builds `dist/` |
| `web/index.html`, `web/shell.js` | the page and the Boxedwine launcher |
| `web/start.bat` | runs inside Wine: first-start registration, then `MupLight.exe` |
| `web/coi-serviceworker.js` | COOP/COEP headers from a service worker |
| `patches/26R1.0/` | Boxedwine source fixes, used by `BOXEDWINE_BUILD=source` |

`dist/`: `boxedwine.js`/`.wasm`, `boxedwine.zip` (Wine 11 file system), `mupad.zip`
(MuPAD plus the few files that differ from Boxedwine's), the page.

## How it works

- The installer is a Wise for Windows Installer package. `build.sh` cuts the `.msi` out
  of its `.WISE` section, unpacks it with `msiextract` and lays the 642 files out as the
  installer does, in `C:\Program Files\SciFace\MuPAD Light 2.5`.
- The installer's custom actions (`/regserver` for MupLight, VCam Light and the two help
  programs) run on the first start in the browser, from `start.bat`.
- `oledlg.dll`, which every MuPAD program imports, comes from Boxedwine's full Wine 11
  file system; the web release's stripped one lacks it.
- MuPAD reaches VCam Light (plots) and its help programs through out-of-process COM.
  Boxedwine never runs wineboot, so `start.bat` starts `services.exe` (COM starts
  `rpcss` through it) and `mupad.zip` carries a `system.reg` with the
  `ActiveComputerName` key wineboot would create and the auto-start services set to
  demand start.
- MFC registers ole32's default handler for each automation class. Wine's default
  handler does not pass `IDispatch` through to a running local server, so plot windows
  stayed empty and the help would not start. The build renames that one registration
  key in each program (`InprocHandler32` -> `NoInprocHandler`, same length).
- The release's web worker pool is raised from 32 to 64 (`PTHREAD_POOL_SIZE`).

## Known issues

- Sending a new input while MuPAD is still computing crashes the emulator (also with
  Boxedwine's single-threaded build). Wait for "Ready, kernel online".
- Minimizing a window freezes the screen (there is no taskbar). Close windows instead.
- MuPAD Light runs unregistered (memory-limited), as it does without a license key.
