#!/usr/bin/env bash
# The arm64 Linux build, end to end, in containers: runs on an arm64 Linux machine, or a Mac with Apple silicon (Docker
# Desktop, colima, OrbStack or podman), natively; an x86-64 machine needs qemu-user's binfmt for arm64 (slow).
#   1. layer   build/linux-layer.sh with SCSK_ARCH=aarch64: libVkLayer_scskiller.so, scskiller_warm, fossilize-replay,
#              selftest_linux, in sniper's arm64 SDK (glibc 2.31 at most)
#   2. vkrec   selftest_linux vkrec on Mesa's lavapipe (Ubuntu 24.04 arm64): recording, replay, overlay, admission
#   3. package build/publish-linux.sh, build/check-linux-package.sh and build/pack-linux.sh for linux-arm64 (.NET 10 SDK,
#              arm64), on the Windows build's native files (a release's SCSKiller.zip and SHA256SUMS-unsigned.txt)
#   4. smoke   the AppImage extracted and run: --cli --version is the package's version
#   5. checks  tools/arm64-checks: the arm64 update feeds (vpk's feed among them) and the arm64 Oodle downloaded and loaded
#   6. bundle  <out>/scskiller-arm64-device-check.tar.gz: the release files, the selftest, arm64-checks (self-contained)
#              and build/device-check-linux.sh, to run on the arm64 machine itself
# Usage: build/test-linux-arm64.sh [--version X.Y.Z] [--windows <SCSKiller.zip> --sums <SHA256SUMS-unsigned.txt>] [--out <dir>]
#   --version  the version to stamp: it must be the Windows files' (default: the v* tag at HEAD, else the newest v* tag)
#   --windows / --sums   the Windows build to take native/ from (default: that version's GitHub release, downloaded)
#   --out      default dist/test-arm64 (emptied first)
# SCSK_UPSTREAM: the GitHub repository whose release is downloaded (default BlueHeisenberg/SCSKiller).
set -euo pipefail
die() { echo "test-linux-arm64: $*" >&2; exit 1; }
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version= windows= sums= out=$repo/dist/test-arm64
while (($#)); do
    case $1 in
        --version) version=${2?}; shift 2 ;;
        --windows) windows=$(cd "$(dirname "${2?}")" && pwd)/$(basename "$2"); shift 2 ;;
        --sums) sums=$(cd "$(dirname "${2?}")" && pwd)/$(basename "$2"); shift 2 ;;
        --out) out=${2?}; shift 2 ;;
        -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
if [[ -n $windows || -n $sums ]] && [[ -z $windows || -z $sums ]]; then die "pass --windows and --sums together"; fi
engine=$(command -v podman || command -v docker) || die "needs podman or docker"
upstream=${SCSK_UPSTREAM:-BlueHeisenberg/SCSKiller}
if [[ -z $version ]]; then
    version=$(git -C "$repo" tag --points-at HEAD -l 'v*' | head -1)
    [[ -n $version ]] || version=$(git -C "$repo" tag -l 'v*' --sort=-v:refname | grep -v -- - | head -1)
    [[ -n $version ]] || die "no v* tag: pass --version"
fi
version=${version#v}
sdk=mcr.microsoft.com/dotnet/sdk:10.0
ubuntu=ubuntu:24.04
mkdir -p "$out" && out=$(cd "$out" && pwd)
case $out in "$repo"/*) ;; *) die "--out must be inside the checkout (the containers mount it): $out" ;; esac
rm -rf "${out:?}"/*
logs=$out/logs && mkdir -p "$logs"
started=$(date +%s)
results=()
step() {   # step <name> <log> <command...>: runs it, keeps its log, records PASS or FAIL
    local name=$1 log=$logs/$2.log t=$(date +%s)
    shift 2
    echo "== $name (log: ${log#$repo/})"
    if "$@" >"$log" 2>&1; then
        results+=("PASS  $name ($(($(date +%s) - t)) s)")
        echo "   passed"
    else
        results+=("FAIL  $name ($(($(date +%s) - t)) s, ${log#$repo/})")
        echo "   FAILED, last lines:"
        tail -20 "$log" | sed 's/^/   | /'
        return 1
    fi
}
summary() {
    echo
    echo "== summary: version $version, $(($(date +%s) - started)) s"
    printf '   %s\n' "${results[@]}"
}
trap summary EXIT
uid=$(id -u) gid=$(id -g)

echo "version $version, engine $engine, upstream $upstream, out ${out#$repo/}"

# 0. the Windows build's native files
if [[ -z $windows ]]; then
    mkdir -p "$out/windows"
    windows=$out/windows/SCSKiller.zip sums=$out/windows/SHA256SUMS-unsigned.txt
    fetch() {
        for f in SCSKiller.zip SHA256SUMS-unsigned.txt; do
            curl -fsSL --retry 3 -o "$out/windows/$f" "https://github.com/$upstream/releases/download/v$version/$f"
        done
    }
    step "Windows build v$version from $upstream" windows fetch
fi

# 1. layer
step "layer (sniper arm64 SDK)" layer env SCSK_ARCH=aarch64 SCSK_VERSION="$version" sh "$repo/build/linux-layer.sh" "$out/layer"

# 2. vkrec on lavapipe
step "vkrec on lavapipe" vkrec "$engine" run --rm --platform linux/arm64 -v "$out/layer:/b" -w /b "$ubuntu" sh -c \
    'apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends libvulkan1 mesa-vulkan-drivers >/dev/null && ./selftest_linux vkrec'

# 3-5. package, smoke, checks: in a copy of the checkout's files (tracked and new, not ignored) on the container's own
#      filesystem, where the package keeps its file modes
list=$out/files.txt
git -C "$repo" ls-files -co --exclude-standard -z >"$list"
rel=${out#$repo/}
case $windows in "$repo"/*) windows_in=/repo/${windows#$repo/} ;; *) windows_in=/win/$(basename "$windows") ;; esac
case $sums in "$repo"/*) sums_in=/repo/${sums#$repo/} ;; *) sums_in=/win/$(basename "$sums") ;; esac
inner=$(cat <<EOF
set -euo pipefail
trap 'chown -R $uid:$gid /repo/$rel' EXIT
apt-get update -q >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends python3 binutils desktop-file-utils squashfs-tools >/dev/null
echo "dotnet \$(dotnet --version), \$(uname -m)"
mkdir /w && cd /repo && tar --null -T /repo/$rel/files.txt -cf - | tar -xf - -C /w
cd /w && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m test
export MSBUILDDISABLENODEREUSE=1 DOTNET_CLI_USE_MSBUILD_SERVER=0 SCSK_ARCH=aarch64
bash -n build/device-check-linux.sh   # the device's bash, not the build machine's (macOS has bash 3.2)
echo "== package"
bash build/publish-linux.sh --windows "$windows_in" --sums "$sums_in" --linux-native /repo/$rel/layer --version $version 2>&1 |
    grep -vE ': warning |^\s+(Determining|Restored|All projects)' || exit 1
bash build/check-linux-package.sh dist/SCSKiller-linux
dotnet tool install vpk --version 1.2.158 --tool-path /vpk >/dev/null
bash build/pack-linux.sh --dir dist/SCSKiller-linux --vpk /vpk/vpk --version $version --out /w/release
mkdir -p /repo/$rel/bundle && cp -a /w/release /repo/$rel/bundle/release
echo "== smoke"
d=\$(mktemp -d) && (cd \$d && /w/release/SCSKiller-aarch64.AppImage --appimage-extract >/dev/null)
got=\$(SCSKILLER_DATA_DIR=\$d/data \$d/squashfs-root/AppRun --cli --version)
echo "AppImage --cli --version: \$got"
[ "\$got" = "$version" ]
echo "== checks"
dotnet publish tools/arm64-checks -c Release -r linux-arm64 --self-contained -p:DebugType=None -o /repo/$rel/bundle/arm64-checks 2>&1 | grep -E 'error|->' || true
SCSKILLER_DATA_DIR=\$(mktemp -d) /repo/$rel/bundle/arm64-checks/arm64-checks --feed \$(ls /w/release/releases.*-linux-arm64.json)
EOF
)
mounts=(-v "$repo:/repo")
[[ $windows == "$repo"/* ]] || mounts+=(-v "$(dirname "$windows"):/win:ro")
[[ $sums == "$repo"/* || $(dirname "$sums") == "$(dirname "$windows")" ]] || die "--sums must be beside --windows, or inside the checkout"
step "package, AppImage smoke test, arm64-checks (.NET 10, arm64)" package \
    "$engine" run --rm --platform linux/arm64 "${mounts[@]}" "$sdk" bash -c "$inner"
for s in "== smoke" "== checks"; do sed -n "/^$s/,/^== /p" "$logs/package.log" | grep -vE '^== ' | sed 's/^/   /'; done

# 6. bundle for the device
b=$out/bundle
mkdir -p "$b/selftest"
for f in selftest_linux libVkLayer_scskiller.so VkLayer_scskiller.json scskiller_warm fossilize-replay; do cp "$out/layer/$f" "$b/selftest/"; done
install -m 755 "$repo/build/device-check-linux.sh" "$b/device-check.sh"
echo "SCSKiller $version linux-arm64, $(git -C "$repo" rev-parse --short HEAD)$(git -C "$repo" diff --quiet HEAD || echo '+changes'), built $(date -u +%Y-%m-%dT%H:%MZ)" >"$b/BUILD"
cat >"$b/README.txt" <<'EOF'
SCSKiller arm64 device check. On the arm64 Linux machine:
  tar -xzf scskiller-arm64-device-check.tar.gz && cd scskiller-arm64-device-check && ./device-check.sh
It writes nothing outside /tmp and never reads your SCSKiller data folder; --no-scan skips the game scan.
Send back the device-report-*.txt it saves here. To try the app itself: release/SCSKiller-aarch64.AppImage.
EOF
rm -rf "$out/scskiller-arm64-device-check"
mv "$b" "$out/scskiller-arm64-device-check"
tar -C "$out" -czf "$out/scskiller-arm64-device-check.tar.gz" scskiller-arm64-device-check
results+=("PASS  device bundle: ${out#$repo/}/scskiller-arm64-device-check.tar.gz ($(du -m "$out/scskiller-arm64-device-check.tar.gz" | cut -f1) MB)")
