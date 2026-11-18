#!/usr/bin/env bash
# Build MuPAD Light 2.5 for the browser on Boxedwine's multi-threaded web build.
#
# The MuPAD installer (source/mupad_light_250.exe) is a "Wise for Windows Installer"
# package: a Wise stub around a Windows Installer database (.msi). The build cuts the
# .msi out of it, unpacks the files with msitools and lays them out the way the
# installer does (C:\Program Files\SciFace\MuPAD Light 2.5). The installer's custom
# actions (each program run with /regserver) are done on first start in the browser
# by start.bat, so they go through Wine's own registry code. Two fixes make MuPAD's
# plots (VCam Light) and help work under Wine, see "Assembling MuPAD" and "Registry".
#
#   ./build.sh            -> dist/ (serve it over http(s))
#
# Options (environment variables):
#   BOXEDWINE_BUILD=release   release: boxedwine.js/.wasm from the official Boxedwine web release
#                             source:  compile them with emscripten, as elona-boxedwine-web does
#                                      (heap growth + patches/<tag>/*.patch)
#   BOXEDWINE_VERSION=26R1    Boxedwine release: source tag <version>.0 and its Wine 11 file system
#   EMSDK_VERSION=5.0.6       (source build) emscripten used to compile
#   EMSDK_DIR=cache/emsdk     (source build) reuse an existing emsdk checkout
#   MAX_MEMORY_MB=2048        (source build) heap growth limit (512..4096)
#   PTHREAD_POOL_SIZE=64      web workers started up front, one per emulated thread. MuPAD
#                             with its helpers (plots, help) and Wine's services runs ~45
#                             threads; emscripten warns that threads past the pool can deadlock.
#   JOBS=<cpu count>          (source build) parallel compile jobs
#   MUPAD_EXE=source/mupad_light_250.exe   the MuPAD Light 2.5.0 installer; if the file is
#                             missing it is downloaded from the Internet Archive
#
# Needs: bash, curl, unzip, zip, python3, msitools (msiextract, msiinfo); for
# BOXEDWINE_BUILD=source also git and make. First source build downloads emsdk
# (~1 GB on disk) and compiles Boxedwine (10-30 minutes); later runs reuse cache/.
set -euo pipefail

BOXEDWINE_BUILD="${BOXEDWINE_BUILD:-release}"
BOXEDWINE_VERSION="${BOXEDWINE_VERSION:-26R1}"
BOXEDWINE_TAG="${BOXEDWINE_TAG:-$BOXEDWINE_VERSION.0}"
EMSDK_VERSION="${EMSDK_VERSION:-5.0.6}"
MAX_MEMORY_MB="${MAX_MEMORY_MB:-2048}"
PTHREAD_POOL_SIZE="${PTHREAD_POOL_SIZE:-64}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/cache"   # downloads, emsdk, Boxedwine source and objects; reused between runs
WORK="$HERE/work"     # scratch, rebuilt every run
OUT="$HERE/dist"      # the website
WEB="$HERE/web"       # index.html, shell.js, coi-serviceworker.js; start.bat (goes into mupad.zip)
EMSDK_DIR="${EMSDK_DIR:-$CACHE/emsdk}"
MUPAD_EXE="${MUPAD_EXE:-$HERE/source/mupad_light_250.exe}"

BW_GIT="https://github.com/danoon2/Boxedwine.git"
EMSDK_GIT="https://github.com/emscripten-core/emsdk.git"
BW_RELEASE_URL="https://github.com/danoon2/Boxedwine/releases/download/$BOXEDWINE_TAG/Boxedwine${BOXEDWINE_VERSION}Web.zip"
BW_LICENSE_URL="https://raw.githubusercontent.com/danoon2/Boxedwine/$BOXEDWINE_TAG/license.txt"
# The web release ships a stripped Wine 11. Boxedwine's full Wine 11 file system
# (same build, what the desktop app downloads) supplies the DLLs MuPAD needs that it lacks.
WINE_FULL_URL="https://boxedwine.org/v2/6/TinyCore15Wine11.0.zip"
WINE_EXTRA_FILES=(
    opt/wine/lib/wine/i386-unix/oledlg.dll.so      # imported by every MuPAD program
)
MUPAD_URL="https://web.archive.org/web/20100719125745id_/http://archives.math.utk.edu/software/multi-platform/MuPAD/distrib/windows/mupad_light_250.exe"
MUPAD_SHA256="29be67d139c5fcd80fd2c85272bed59223cc894f474994e74bef53d563f89940"
MUPAD_DIR="home/username/.wine/drive_c/Program Files/SciFace/MuPAD Light 2.5"   # INSTALLDIR

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in curl unzip zip python3 msiextract msiinfo; do
    command -v "$tool" >/dev/null || die "missing '$tool' (msiextract/msiinfo come with msitools: apt install msitools / brew install msitools)"
done
case "$BOXEDWINE_BUILD" in
    release) ;;
    source)
        for tool in git make; do command -v "$tool" >/dev/null || die "missing '$tool'"; done
        [[ "$MAX_MEMORY_MB" =~ ^[0-9]+$ ]] && [ "$MAX_MEMORY_MB" -ge 512 ] && [ "$MAX_MEMORY_MB" -le 4096 ] \
            || die "MAX_MEMORY_MB must be between 512 and 4096" ;;
    *) die "BOXEDWINE_BUILD must be 'release' or 'source'" ;;
esac
[[ "$PTHREAD_POOL_SIZE" =~ ^[0-9]+$ ]] && [ "$PTHREAD_POOL_SIZE" -ge 8 ] && [ "$PTHREAD_POOL_SIZE" -le 256 ] \
    || die "PTHREAD_POOL_SIZE must be between 8 and 256"
for f in index.html shell.js coi-serviceworker.js start.bat; do
    [ -f "$WEB/$f" ] || die "web/$f is missing"
done

mkdir -p "$CACHE"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# fetch URL FILE: download once into the cache.
fetch() {
    if [ -s "$CACHE/$2" ]; then
        echo "cached: $2"
    else
        echo "downloading: $1"
        curl -fL --retry 5 --retry-all-errors -C - -o "$CACHE/$2.part" "$1"
        mv "$CACHE/$2.part" "$CACHE/$2"
    fi
}

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch "$BW_RELEASE_URL" "Boxedwine${BOXEDWINE_VERSION}Web.zip"
BW_ZIP="$CACHE/Boxedwine${BOXEDWINE_VERSION}Web.zip"

if [ "$BOXEDWINE_BUILD" = release ]; then
    log "Boxedwine $BOXEDWINE_VERSION multi-threaded web build (prebuilt, fixed 512 MB heap)"
    unzip -p "$BW_ZIP" MultiThreaded/boxedwine.js > "$OUT/boxedwine.js"
    unzip -p "$BW_ZIP" MultiThreaded/boxedwine.wasm > "$OUT/boxedwine.wasm"
    [ -s "$OUT/boxedwine.js" ] && [ -s "$OUT/boxedwine.wasm" ] || die "MultiThreaded/boxedwine.{js,wasm} not found in the release zip"
    # The release is linked with -sPTHREAD_POOL_SIZE=32, which lives only in the JS glue.
    grep -q 'var pthreadPoolSize = 32;' "$OUT/boxedwine.js" || die "boxedwine.js: thread pool size not found"
    sed -i.orig "s/var pthreadPoolSize = 32;/var pthreadPoolSize = $PTHREAD_POOL_SIZE;/" "$OUT/boxedwine.js"
    rm -f "$OUT/boxedwine.js.orig"
    echo "thread pool: $PTHREAD_POOL_SIZE workers"
    fetch "$BW_LICENSE_URL" "boxedwine-license-$BOXEDWINE_TAG.txt"
    cp "$CACHE/boxedwine-license-$BOXEDWINE_TAG.txt" "$OUT/license.txt"
else
    log "emscripten $EMSDK_VERSION"
    [ -d "$EMSDK_DIR/.git" ] || git clone --depth 1 "$EMSDK_GIT" "$EMSDK_DIR"
    "$EMSDK_DIR/emsdk" install "$EMSDK_VERSION"
    "$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION" >/dev/null
    set +u
    # shellcheck disable=SC1091
    source "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
    set -u
    emcc --version | head -n1 | grep -qF "$EMSDK_VERSION" || die "emcc is not version $EMSDK_VERSION"

    log "Boxedwine $BOXEDWINE_TAG from source (multi-threaded, heap 512 MB growing to $MAX_MEMORY_MB MB)"
    SRC="$CACHE/boxedwine-$BOXEDWINE_TAG"
    [ -d "$SRC/.git" ] || git clone --depth 1 --branch "$BOXEDWINE_TAG" "$BW_GIT" "$SRC"
    # Source fixes for this tag (patches/<tag>/*.patch), each applied once.
    for patch in "$HERE/patches/$BOXEDWINE_TAG"/*.patch; do
        [ -e "$patch" ] || continue
        if git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null; then
            echo "patch already applied: ${patch#"$HERE"/}"
        else
            git -C "$SRC" apply "$patch" || die "could not apply ${patch#"$HERE"/}"
            echo "patch applied: ${patch#"$HERE"/}"
        fi
    done
    # Same compile and link settings as upstream's multiThreaded target, plus memory growth.
    BUILD_DIR="Build/MultiThreaded-grow-em$EMSDK_VERSION"
    rm -f "$SRC/project/emscripten/$BUILD_DIR"/boxedwine.{html,js,wasm,worker.js}   # always relink
    make -C "$SRC/project/emscripten" -j"$JOBS" \
        BUILD_DIR="$BUILD_DIR" \
        SHELL_FILE=shell.html \
        EXTRA_CPP_FLAGS="-DBOXEDWINE_MULTI_THREADED -pthread" \
        EXTRA_LD_FLAGS="-pthread -sPTHREAD_POOL_SIZE=$PTHREAD_POOL_SIZE -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=$((MAX_MEMORY_MB * 1024 * 1024)) -Wno-pthreads-mem-growth"
    BUILT="$SRC/project/emscripten/$BUILD_DIR"
    [ -f "$BUILT/boxedwine.js" ] && [ -f "$BUILT/boxedwine.wasm" ] || die "build finished without boxedwine.js/boxedwine.wasm"
    cp "$BUILT/boxedwine.js" "$BUILT/boxedwine.wasm" "$OUT/"
    [ ! -f "$BUILT/boxedwine.worker.js" ] || cp "$BUILT/boxedwine.worker.js" "$OUT/"   # older emscripten only
    cp "$SRC/license.txt" "$OUT/license.txt"
fi

log "Wine 11 file system from the Boxedwine $BOXEDWINE_VERSION release"
unzip -p "$BW_ZIP" Wine11/boxedwine.zip > "$OUT/boxedwine.zip"
[ -s "$OUT/boxedwine.zip" ] || die "Wine11/boxedwine.zip not found in the release zip"

log "Extra Wine 11 DLLs from Boxedwine's full file system"
fetch "$WINE_FULL_URL" "TinyCore15Wine11.0.zip"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
unzip -q -o "$CACHE/TinyCore15Wine11.0.zip" "${WINE_EXTRA_FILES[@]}" -d "$STAGE"

log "MuPAD Light 2.5 installer"
if [ ! -s "$MUPAD_EXE" ]; then
    echo "$MUPAD_EXE not found"
    fetch "$MUPAD_URL" "mupad_light_250.exe"
    MUPAD_EXE="$CACHE/mupad_light_250.exe"
fi
[ "$(sha256 "$MUPAD_EXE")" = "$MUPAD_SHA256" ] || die "$MUPAD_EXE is not the MuPAD Light 2.5.0 installer (sha256 mismatch)"

# Cut the Windows Installer database out of the Wise stub's .WISE section. Its size is
# taken from the compound file's own allocation table (FAT, reached through the DIFAT).
python3 - "$MUPAD_EXE" "$WORK/mupad.msi" <<'PY'
import struct, sys
exe = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", exe, 0x3C)[0]
nsec, = struct.unpack_from("<H", exe, pe + 6)
opt, = struct.unpack_from("<H", exe, pe + 20)
for i in range(nsec):
    s = pe + 24 + opt + 40 * i
    if exe[s:s + 8].rstrip(b"\0") == b".WISE":
        _, _, size, ptr = struct.unpack_from("<IIII", exe, s + 8)
        break
else:
    sys.exit("no .WISE section: not a Wise for Windows Installer package")
sec = exe[ptr:ptr + size]
start = sec.find(bytes.fromhex("d0cf11e0a1b11ae1"))
if start < 0:
    sys.exit("no .msi inside the Wise package")
msi = sec[start:]
ss = 1 << struct.unpack_from("<H", msi, 0x1E)[0]
nfat, = struct.unpack_from("<I", msi, 0x2C)
difat = list(struct.unpack_from("<109I", msi, 0x4C))
nxt, = struct.unpack_from("<I", msi, 0x44)
while nxt < 0xFFFFFFFA:
    ents = struct.unpack_from("<%dI" % (ss // 4), msi, (nxt + 1) * ss)
    difat += ents[:-1]
    nxt = ents[-1]
last = 0
for k, fs in enumerate(difat[:nfat]):
    for j, e in enumerate(struct.unpack_from("<%dI" % (ss // 4), msi, (fs + 1) * ss)):
        if e != 0xFFFFFFFF:
            last = k * (ss // 4) + j
end = (last + 2) * ss
open(sys.argv[2], "wb").write(msi[:end])
print("mupad.msi: %d bytes at offset 0x%x" % (end, ptr + start))
PY
msiinfo suminfo "$WORK/mupad.msi" | grep -E '^(Subject|Author)' || die "the extracted mupad.msi is not readable"

log "Unpacking mupad.msi"
mkdir -p "$WORK/msi"
msiextract -C "$WORK/msi" "$WORK/mupad.msi" >/dev/null
SRC_DIR="$WORK/msi/SOURCEDIR/Program Files/SciFace/MuPAD Light 2.5"
[ -f "$SRC_DIR/bin/MupLight.exe" ] || die "MupLight.exe not found in mupad.msi"
# msiextract lays files out by the source directory names. The installer's one directory
# whose target differs from its source is "Application" (DefaultDir ".:APPLIC~1|Application",
# i.e. installed into its parent): the documentation merged in from SciFace's merge module.
cp -a "$SRC_DIR/Application/." "$SRC_DIR/"
rm -rf "$SRC_DIR/Application"
want="$(msiinfo export "$WORK/mupad.msi" File | tail -n +4 | wc -l | tr -d ' ')"
got="$(find "$SRC_DIR" -type f | wc -l | tr -d ' ')"
[ "$want" = "$got" ] || die "mupad.msi lists $want files, unpacked $got"
echo "$got files"

log "Assembling MuPAD"
mkdir -p "$STAGE/$MUPAD_DIR"
cp -a "$SRC_DIR/." "$STAGE/$MUPAD_DIR/"
# MuPAD drives its helpers through OLE automation (IDispatch, objects created with
# CLSCTX_ALL): VCam Light draws the plots, lhlpbrowse.exe and muplhelp.exe are the help.
# When the programs register themselves (/regserver, and again on every normal start)
# MFC also registers ole32's default handler as each class's InprocHandler32. Windows'
# default handler passes IDispatch through to the running server; Wine's does not (and
# can't start servers that aren't OLE documents), so plot windows stayed empty and the
# help "can not start". Renaming the key in MFC's registration template (one string per
# program, same length) leaves the classes without a handler, and COM goes straight to
# the local server.
python3 - "$STAGE/$MUPAD_DIR/bin" <<'PY'
import os, sys
old, new = b"CLSID\\%1\\InprocHandler32\0", b"CLSID\\%1\\NoInprocHandler\0"
assert len(old) == len(new)
for name in ("MupLight.exe", "VCamLght.exe", "muplhelp.exe", "lhlpbrowse.exe"):
    path = os.path.join(sys.argv[1], name)
    data = open(path, "rb").read()
    if data.count(old) != 1:
        sys.exit("%s: expected one InprocHandler32 registration entry" % name)
    open(path, "wb").write(data.replace(old, new))
    print("%s: InprocHandler32 -> NoInprocHandler" % name)
PY
# The launcher: first-start registration (the installer's /regserver custom actions),
# then MuPAD. Windows line endings for cmd.exe.
sed 's/\r*$/\r/' "$WEB/start.bat" > "$STAGE/$MUPAD_DIR/bin/start.bat"

log "Registry for out-of-process COM (MuPAD -> plots and help)"
# Boxedwine's file system never runs wineboot, which is what normally starts the service
# manager and creates the volatile ActiveComputerName key. start.bat starts services.exe
# so that COM can start rpcss; without the computer name, rpcss's local RPC handoff fails
# ("Failed to retrieve the computer name"). The services that would start automatically
# (Eventlog, PlugPlay, MountMgr) are set to start on demand: plain Boxedwine runs none
# of them, and each costs emulated threads. This system.reg replaces the one in
# boxedwine.zip because shell.js mounts mupad.zip first (the first zip with a file wins).
unzip -p "$OUT/boxedwine.zip" home/username/.wine/system.reg > "$WORK/system.reg"
python3 - "$WORK/system.reg" "$STAGE/home/username/.wine/system.reg" <<'PY'
import re, sys
reg = open(sys.argv[1], encoding="utf-8", errors="surrogateescape").read()
cn = re.search(r'^\[System\\\\ControlSet001\\\\Control\\\\ComputerName\\\\ComputerName\] (\d+)\n'
               r'(?:#.*\n)*"ComputerName"="([^"]*)"\n', reg, re.M)
if not cn:
    sys.exit("system.reg has no ComputerName")
if "ComputerName\\\\ActiveComputerName]" not in reg:
    reg = reg[:cn.end()] + ('\n[System\\\\ControlSet001\\\\Control\\\\ComputerName\\\\ActiveComputerName] %s\n'
                            '"ComputerName"="%s"\n' % (cn.group(1), cn.group(2))) + reg[cn.end():]
def demand(m):
    return re.sub(r'^"Start"=dword:0000000[0-2]$', '"Start"=dword:00000003', m.group(0), flags=re.M)
reg = re.sub(r'^\[System\\\\ControlSet001\\\\Services\\\\[^\\\]]+\][^\n]*\n(?:(?!\[).*\n)*', demand, reg, flags=re.M)
open(sys.argv[2], "w", encoding="utf-8", errors="surrogateescape", newline="\n").write(reg)
print("computer name %s; auto-start services set to demand start" % cn.group(2))
PY

log "Packing mupad.zip"
# lib.tar (MuPAD's library, read at random offsets) is stored, not deflated.
(cd "$STAGE" && zip -q -r -X -n .tar:.png:.gif "$OUT/mupad.zip" home opt)

log "Web assets"
cp "$WEB"/index.html "$WEB"/shell.js "$WEB"/coi-serviceworker.js "$OUT/"
cp "$SRC_DIR/License/License.txt" "$OUT/mupad-license.txt"

rm -rf "$WORK"
log "Done: $OUT"
ls -lh "$OUT"
cat <<EOF

Test locally:  cd dist && python3 -m http.server 8000   then open http://localhost:8000/
Publish:       upload the contents of dist/ to any static host (GitHub Pages works,
               coi-serviceworker.js supplies the headers the multi-threaded build needs).
EOF
