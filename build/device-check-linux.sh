#!/usr/bin/env bash
# Runs on the arm64 Linux machine itself, from the folder build/test-linux-arm64.sh bundles (scskiller-arm64-device-check):
#   1. the machine: CPU, distribution, glibc, kernel
#   2. the Vulkan recorder layer and the Vulkan warm (selftest_linux vkrec) on each arm64 Vulkan driver installed: the
#      GPU's own and lavapipe, as the games' loader would load them
#   3. arm64-checks: the arm64 update feeds, and the arm64 Oodle build downloaded and loaded with this machine's glibc
#   4. the AppImage: extracted (no FUSE needed) and run as the CLI: --version, then a game scan in a throwaway data folder
#   5. every ARM64 Proton installed, read as a compile reads it (its ARM64 branch, its default prefix, prefix_info)
#   6. Turnip's cache, measured: a Steam game's recorded pipelines (fozpipelinesv6) replayed twice on the game's own Turnip
#      build (Armada's per-game pick) into a scratch cache in /tmp, cold then warm; nothing is launched
#   7. what the next steps depend on (report only): FUSE for a normal AppImage start, Steam, Proton, FEX, Box64
# Nothing outside a temp folder is written; your own SCSKiller data folder isn't read. The report is saved beside this
# script (device-report-<time>.txt): send it back.
# Usage: ./device-check.sh [--no-scan] [--no-network] [--no-replay]
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scan=1 network=1 replay=1
for a in "$@"; do
    case $a in
        --no-scan) scan= ;;
        --no-network) network= ;;
        --no-replay) replay= ;;
        *) echo "usage: $0 [--no-scan] [--no-network] [--no-replay]" >&2; exit 2 ;;
    esac
done
report=$here/device-report-$(date +%Y%m%d-%H%M%S).txt
exec > >(tee "$report") 2>&1
work=$(mktemp -d /tmp/scsk-device-XXXXXX)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0 failed=()
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); failed+=("$1"); }
info() { echo "INFO  $1"; }
section() { echo; echo "== $1"; }
elf_machine() { [[ -f $1 ]] && [[ $(head -c 4 "$1" | od -An -c | tr -d ' ') == '177ELF' ]] && od -An -t u2 -j 18 -N 2 "$1" | tr -d ' '; }

echo "SCSKiller arm64 device check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "bundle: $(cat "$here/BUILD" 2>/dev/null || echo unknown)"

section "1. machine"
arch=$(uname -m)
[[ $arch == aarch64 ]] && ok "CPU is aarch64" || bad "CPU is $arch, not aarch64"
info "kernel $(uname -r)"
if [[ -r /etc/os-release ]]; then . /etc/os-release; info "distribution: ${PRETTY_NAME:-$NAME} (id ${ID:-?}, like ${ID_LIKE:-?})"; fi
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
info "glibc ${glibc:-unknown}"
if [[ -n $glibc ]]; then
    [[ $(printf '%s\n2.31\n' "$glibc" | sort -V | head -1) == 2.31 ]] && ok "glibc $glibc runs the layer and the warm (2.30 needed)" || bad "glibc $glibc is older than the layer's 2.30"
    [[ $(printf '%s\n2.38\n' "$glibc" | sort -V | head -1) == 2.38 ]] && ok "glibc $glibc loads native Oodle (2.38 needed)" ||
        info "glibc $glibc is older than 2.38: Oodle decodes in managed code (slower, still works)"
fi
info "memory: $(awk '/MemTotal/ {printf "%.1f GB", $2 / 1048576}' /proc/meminfo), CPUs: $(nproc)"
if [[ -r /proc/device-tree/model ]]; then info "board: $(tr -d '\0' </proc/device-tree/model)"; fi
if [[ -x /usr/libexec/armada/device-env ]]; then
    ( eval "$(/usr/libexec/armada/device-env 2>/dev/null)"
      info "Armada device: ${ARMADA_DEVICE_NAME:-?} (${ARMADA_DEVICE_ID:-?}), SoC ${ARMADA_SOC_CLASS:-?}, Proton defaults ${ARMADA_PROTON_DEFAULTS:-?}" )
    [[ -r /usr/lib/armada/version ]] && info "Armada version: $(head -1 /usr/lib/armada/version)"
fi

section "2. Vulkan layer and warm (selftest_linux vkrec)"
st=$here/selftest/selftest_linux
if [[ ! -x $st ]]; then
    bad "no selftest/selftest_linux in the bundle"
else
    command -v vulkaninfo >/dev/null && vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|driverInfo|apiVersion' | sed 's/^/INFO  vulkaninfo: /' | head -12
    icds=()
    for d in /usr/share/vulkan/icd.d /etc/vulkan/icd.d /usr/local/share/vulkan/icd.d "${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/icd.d"; do
        for j in "$d"/*.json; do [[ -f $j ]] && icds+=("$j"); done
    done
    ((${#icds[@]})) || bad "no Vulkan driver (ICD) installed: install your GPU's Mesa Vulkan driver"
    ran=0 gpu_pass=0 lvp_pass=0
    for j in "${icds[@]}"; do
        lib=$(grep -o '"library_path"[^,}]*' "$j" | sed 's/.*: *"//; s/"$//')
        path=$lib
        if [[ $lib != /* ]]; then
            if [[ $lib == */* ]]; then path=$(dirname "$j")/$lib
            else for p in /usr/lib/aarch64-linux-gnu /usr/lib64 /usr/lib /usr/local/lib /lib/aarch64-linux-gnu; do [[ -f $p/$lib ]] && path=$p/$lib && break; done; fi
        fi
        m=$(elf_machine "$path")
        if [[ -n $m && $m != 183 ]]; then info "skip $(basename "$j"): $lib is not aarch64 (e_machine $m)"; continue; fi
        log=$work/vkrec-$(basename "$j" .json).log
        echo "-- $(basename "$j") ($lib)"
        if VK_ICD_FILENAMES=$j VK_DRIVER_FILES=$j timeout 600 "$st" vkrec >"$log" 2>&1; then
            ok "vkrec on $(basename "$j")"
            if [[ $(basename "$j") == lvp_icd* ]]; then lvp_pass=1; else gpu_pass=$((gpu_pass + 1)); fi
        elif ! grep '^FAILED selftest' "$log" | grep -qvE 'create_instance|vkEnumeratePhysicalDevices'; then
            # Mesa installs every driver's ICD file: one whose hardware isn't here makes no instance or finds no GPU
            # (a GPU driver failing so is caught below: no GPU driver passed)
            info "skip $(basename "$j"): finds no GPU on this machine"
            continue
        else
            bad "vkrec on $(basename "$j")"
        fi
        grep -E '^(X|R|P|W|B|I1):|vkrec:|FAILED' "$log" | sort -u | sed 's/^/      /' | head -20
        ran=$((ran + 1))
    done
    ((ran)) || bad "no arm64 Vulkan driver to run vkrec on"
    if ((gpu_pass)); then ok "the layer and the warm work on this GPU's own driver"
    elif ((lvp_pass)); then bad "only lavapipe (software) passed: no GPU driver ran the layer"
    fi
fi

section "3. arm64-checks (update feeds, codecs)"
if [[ -x $here/arm64-checks/arm64-checks ]]; then
    a=(); [[ -n $network ]] || a=(--no-network)
    feed=$(ls "$here"/release/releases.*-linux-arm64.json 2>/dev/null | head -1)
    [[ -n $feed ]] && a+=(--feed "$feed")
    if SCSKILLER_DATA_DIR=$work/checks "$here/arm64-checks/arm64-checks" "${a[@]}" | sed 's/^/      /'; then ok "arm64-checks"; else bad "arm64-checks"; fi
else
    bad "no arm64-checks in the bundle"
fi

section "4. AppImage"
img=$(ls "$here"/release/SCSKiller-aarch64.AppImage 2>/dev/null)
if [[ -z $img ]]; then
    bad "no release/SCSKiller-aarch64.AppImage in the bundle"
else
    chmod +x "$img"
    [[ $(elf_machine "$img") == 183 ]] && ok "AppImage is an aarch64 ELF" || bad "AppImage isn't aarch64"
    (cd "$work" && "$img" --appimage-extract >/dev/null 2>&1) && ok "AppImage extracts" || bad "AppImage doesn't extract"
    run=$work/squashfs-root/AppRun
    if [[ -x $run ]]; then
        v=$(SCSKILLER_DATA_DIR=$work/data "$run" --cli --version 2>&1)
        [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && ok "CLI runs: --version $v" || bad "CLI --version: $v"
        if [[ -n $scan ]]; then
            echo "-- scskiller scan (throwaway data folder)"
            if SCSKILLER_DATA_DIR=$work/data timeout 900 "$run" --cli scan >"$work/scan.log" 2>&1; then
                ok "CLI scan"
            else
                bad "CLI scan (exit $?)"
            fi
            tail -30 "$work/scan.log" | sed 's/^/      /'
            SCSKILLER_DATA_DIR=$work/data timeout 300 "$run" --cli status >"$work/status.log" 2>&1 && ok "CLI status" || bad "CLI status"
            head -60 "$work/status.log" | sed 's/^/      /'
        fi
        # the native libraries the UI loads: anything this distribution lacks shows here
        while IFS= read -r so; do
            [[ $(basename "$so") == libcoreclrtraceptprovider.so ]] && continue   # .NET's optional LTTng tracing
            ldd "$so" 2>/dev/null | grep 'not found' | sed "s|^|      $(basename "$so") misses: |"
        done < <(find "$work/squashfs-root" -name 'lib*.so' -type f 2>/dev/null)
    fi
fi

steam_root=$(readlink -f "$HOME/.steam/root" 2>/dev/null || echo "$HOME/.local/share/Steam")
checks=$here/arm64-checks/arm64-checks

section "5. ARM64 Protons, read as a compile reads them"
protons=()
for p in "$steam_root"/steamapps/common/* "$steam_root"/compatibilitytools.d/* /usr/share/steam/compatibilitytools.d/*; do
    [[ -f $p/proton && -d $p/files/bin-arm64 ]] && protons+=("$p")
done
if ((${#protons[@]} == 0)); then info "no ARM64 Proton installed"
elif [[ ! -x $checks ]]; then bad "no arm64-checks in the bundle"
elif SCSKILLER_DATA_DIR=$work/checks "$checks" --proton "${protons[@]}" | sed 's/^/      /'; then ok "every ARM64 Proton (${#protons[@]}) reads as a compile needs"
else bad "an ARM64 Proton reads otherwise than a compile needs (above)"; fi

section "6. Turnip's cache, measured (a game's Steam recording, replayed cold then warm)"
if [[ -z $replay ]]; then info "skipped (--no-replay)"
elif [[ ! -x $here/selftest/fossilize-replay ]]; then bad "no selftest/fossilize-replay in the bundle"
else
    # Steam's recordings, smallest of at least 2 MB first; a delta (an app run's) only names shader modules of the archive
    # beside it and replays nothing alone, so the first that replays pipelines is measured
    mapfile -t picks < <(find "$steam_root"/steamapps/shadercache/*/fozpipelinesv6 -name '*.foz' -size +2M -printf '%s %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
    took() { grep -E 'Playing back [0-9]+ (graphics|compute) pipelines took' "$1" | awk '{s += $(NF-3)} END {printf "%.1f", s}'; }
    count() { grep -E '^Fossilize INFO: +(graphics|compute) pipelines:' "$1" | awk '{s += $NF} END {print s + 0}'; }
    replay() {   # replay <run> <recording> <driver files>: into $r/cache, its exit code in $r/<run>.code
        ( [[ -n $3 ]] && export VK_DRIVER_FILES=$3 VK_ICD_FILENAMES=$3
          MESA_SHADER_CACHE_DIR=$r/cache MESA_DISK_CACHE_SINGLE_FILE=1 timeout 900 "$here/selftest/fossilize-replay" --num-threads "$(nproc)" "$2" >"$r/$1.log" 2>&1 )
        echo "$?" >"$r/$1.code"
    }
    measured=
    for pick in "${picks[@]:0:6}"; do
        app=$(sed -E 's|.*/shadercache/([0-9]+)/.*|\1|' <<<"$pick")
        name=$(grep -h '"name"' "$steam_root"/steamapps/appmanifest_"$app".acf 2>/dev/null | head -1 | sed -E 's/.*"name"[[:space:]]+"([^"]*)".*/\1/')
        drv=$("$checks" --armada "$app" 2>/dev/null | grep -o 'VK_DRIVER_FILES=[^ ]*' | cut -d= -f2-)
        r=$work/replay && rm -rf "$r" && mkdir -p "$r/cache"
        cp "$pick" "$r/rec.foz"
        replay cold "$r/rec.foz" "$drv"
        n=$(count "$r/cold.log")
        if ((n == 0)); then info "skip $(basename "$pick") of ${name:-$app}: replays no pipeline alone (a delta of Steam's)"; continue; fi
        info "game: ${name:-?} ($app), $(basename "$pick") $(du -h "$pick" | cut -f1), Turnip: ${drv:-the system one}"
        replay warm "$r/rec.foz" "$drv"
        cold=$(took "$r/cold.log") warm=$(took "$r/warm.log")
        info "cold: $n pipelines, ${cold} s of compile time; warm: ${warm} s; cache $(du -sh "$r/cache" | cut -f1)"
        if [[ $(cat "$r/cold.code") != 0 ]]; then bad "the cold replay failed or ran out of time (exit $(cat "$r/cold.code"))"; tail -5 "$r/cold.log" | sed 's/^/      /'
        elif [[ -z $(find "$r/cache" -name foz_cache.foz -size +0) ]]; then bad "Turnip wrote no cache: its disk cache is off for this driver build"
        elif awk -v c="$cold" -v w="$warm" 'BEGIN { exit !(c > 0 && w * 5 < c) }'; then ok "Turnip's cache works here: warm is $(awk -v c="$cold" -v w="$warm" 'BEGIN { printf "%.0f", (w > 0 ? c / w : 0) }')x faster"
        else bad "the warm replay wasn't much faster (cold ${cold} s, warm ${warm} s): the cache isn't being read"; fi
        measured=1
        break
    done
    if [[ -z $measured ]]; then
        if ((${#picks[@]} == 0)); then info "no Steam pipeline recording (fozpipelinesv6) yet: play a Proton game once, then run this again"
        else bad "none of the first $(( ${#picks[@]} < 6 ? ${#picks[@]} : 6 )) Steam recordings replayed a pipeline"; fi
    fi
fi

section "7. for the next steps (report only)"
if command -v fusermount3 >/dev/null || command -v fusermount >/dev/null; then info "FUSE: present (the AppImage starts with a double-click)"
else info "FUSE: missing (start the AppImage with --appimage-extract-and-run, or install fuse3)"; fi
info "session: ${XDG_SESSION_TYPE:-?}, desktop: ${XDG_CURRENT_DESKTOP:-?}, display: ${WAYLAND_DISPLAY:-}${DISPLAY:-}"
for s in "$HOME/.steam/steam" "$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
    [[ -d $s ]] || continue
    info "Steam: $s"
    for f in "$s/ubuntu12_32/steam" "$s/linuxarm64/steam" "$s/linux64/steamclient.so"; do [[ -e $f ]] && info "  $(basename "$(dirname "$f")")/$(basename "$f"): $(file -b "$f" 2>/dev/null | cut -c1-60)"; done
    for p in "$s"/steamapps/common/Proton* "$s"/compatibilitytools.d/*; do
        [[ -d $p ]] || continue
        w=$(ls -d "$p"/files/lib/wine/* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
        info "  Proton: $(basename "$p") (wine: ${w:-?})"
    done
    n=$(ls "$s"/steamapps/appmanifest_*.acf 2>/dev/null | wc -l); info "  installed Steam apps: $n"
done
for t in FEXInterpreter FEXLoader FEXBash box64 box86 qemu-x86_64; do command -v $t >/dev/null && info "x86 emulation: $t ($(command -v $t))"; done
[[ -d /proc/sys/fs/binfmt_misc ]] && ls /proc/sys/fs/binfmt_misc 2>/dev/null | grep -iE 'fex|box|x86' | sed 's/^/INFO  binfmt: /'
for g in /dev/dri/renderD*; do [[ -e $g ]] && info "GPU node $g: $(cat /sys/class/drm/$(basename "$g")/device/uevent 2>/dev/null | grep -E 'DRIVER|OF_COMPATIBLE_0|PCI_ID' | tr '\n' ' ')"; done

echo
echo "== summary: $pass passed, $fail failed"
for f in "${failed[@]}"; do echo "   FAIL $f"; done
echo "report: $report"
((fail == 0))
