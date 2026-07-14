#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Orange Pi 4 Pro / sun60iw2 GPU + NPU fresh-install repair
#
# Repairs:
#   - Missing matching kernel headers
#   - Missing sunxi-sid.h required by img-bxm DKMS
#   - Failed pvrsrvkm DKMS registration/build/install
#   - Missing module autoload
#   - Missing render/video group membership
#   - Missing Vulkan/OpenGL diagnostic tools
#   - Root-owned NPU test output/log files
#
# Usage:
#   sudo bash fix-gpu-npu-fresh-install.sh
#   sudo bash fix-gpu-npu-fresh-install.sh --reboot
###############################################################################

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
RESET='\033[0m'

REBOOT_AFTER=0

if [[ "${1:-}" == "--reboot" ]]; then
    REBOOT_AFTER=1
elif [[ -n "${1:-}" ]]; then
    echo "Usage: sudo bash $0 [--reboot]"
    exit 2
fi

pass() {
    echo -e "${GREEN}[PASS]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

fail() {
    echo -e "${RED}[FAIL]${RESET} $*" >&2
}

section() {
    echo
    echo -e "${BLUE}========== $* ==========${RESET}"
}

die() {
    fail "$*"
    exit 1
}

on_error() {
    local status=$?
    local line=${BASH_LINENO[0]:-unknown}

    echo
    fail "Installation stopped at line $line with exit status $status."

    if [[ -n "${MAKE_LOG:-}" && -f "${MAKE_LOG:-}" ]]; then
        echo
        echo "Last DKMS compiler errors:"
        grep -nEi \
            'fatal error:|error:|undefined|No such file|No rule|failed' \
            "$MAKE_LOG" 2>/dev/null |
            tail -40 || true
    fi

    exit "$status"
}

trap on_error ERR

if [[ ${EUID} -ne 0 ]]; then
    die "Run this script with sudo."
fi

KVER="$(uname -r)"
ARCH="$(uname -m)"
MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
COMPATIBLE="$(tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null || true)"

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER="$(logname 2>/dev/null || true)"
fi
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER="orangepi"
fi

REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
if [[ -z "$REAL_HOME" ]]; then
    REAL_HOME="/home/$REAL_USER"
fi

section "PLATFORM CHECK"

echo "Model:        ${MODEL:-unknown}"
echo "Kernel:       $KVER"
echo "Architecture: $ARCH"
echo "Target user:  $REAL_USER"
echo "Target home:  $REAL_HOME"
echo "Compatible:"
echo "$COMPATIBLE" | sed 's/^/  /'

[[ "$ARCH" == "aarch64" ]] ||
    die "This installer expects aarch64, but detected $ARCH."

if ! grep -Eqi 'sun60iw2|orangepi-4-pro' <<<"$MODEL $COMPATIBLE $KVER"; then
    die "This does not appear to be the expected sun60iw2 / Orange Pi 4 Pro image."
fi

section "LOCATE INSTALLATION ASSETS"

DKMS_SOURCE="$(
    find /usr/src \
        -maxdepth 1 \
        -type d \
        -name 'img-bxm-dkms-*' \
        2>/dev/null |
    sort -V |
    tail -1
)"

[[ -n "$DKMS_SOURCE" ]] ||
    die "PowerVR DKMS source was not found under /usr/src/img-bxm-dkms-*."

DKMS_CONF="$DKMS_SOURCE/dkms.conf"
[[ -f "$DKMS_CONF" ]] ||
    die "DKMS configuration was not found: $DKMS_CONF"

PKG_NAME="$(
    sed -n 's/^PACKAGE_NAME="\([^"]*\)".*/\1/p' "$DKMS_CONF" |
    head -1
)"

PKG_VER="$(
    sed -n 's/^PACKAGE_VERSION="\([^"]*\)".*/\1/p' "$DKMS_CONF" |
    head -1
)"

[[ -n "$PKG_NAME" ]] ||
    die "Could not read PACKAGE_NAME from $DKMS_CONF."

[[ -n "$PKG_VER" ]] ||
    die "Could not read PACKAGE_VERSION from $DKMS_CONF."

HEADER_DEB="$(
    find /opt \
        -maxdepth 2 \
        -type f \
        -name 'linux-headers-current-sun60iw2_*_arm64.deb' \
        2>/dev/null |
    sort -V |
    tail -1
)"

echo "DKMS source:  $DKMS_SOURCE"
echo "DKMS name:    $PKG_NAME"
echo "DKMS version: $PKG_VER"
echo "Headers deb:  ${HEADER_DEB:-not found}"

section "INSTALL BUILD AND TEST TOOLS"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    build-essential \
    dkms \
    gcc \
    make \
    wget \
    curl \
    ca-certificates \
    kmod \
    file \
    vulkan-tools \
    mesa-utils \
    mesa-utils-extra

pass "Required build and diagnostic packages are installed."

section "INSTALL MATCHING KERNEL HEADERS"

HEADER_ROOT="/usr/src/linux-headers-$KVER"

if [[ -f "$HEADER_ROOT/Makefile" ]]; then
    pass "Matching kernel headers are already installed."
elif [[ -n "$HEADER_DEB" && -f "$HEADER_DEB" ]]; then
    echo "Installing: $HEADER_DEB"

    dpkg -i "$HEADER_DEB" || apt-get install -f -y

    [[ -f "$HEADER_ROOT/Makefile" ]] ||
        die "Header package installed, but $HEADER_ROOT/Makefile is still missing."

    pass "Matching kernel headers were installed."
else
    die "No matching header tree or header package was found for $KVER."
fi

# Repair the module build link if it is absent or broken.
mkdir -p "/lib/modules/$KVER"

if [[ ! -e "/lib/modules/$KVER/build" ]]; then
    ln -s "$HEADER_ROOT" "/lib/modules/$KVER/build"
elif [[ ! -f "/lib/modules/$KVER/build/Makefile" ]]; then
    rm -f "/lib/modules/$KVER/build"
    ln -s "$HEADER_ROOT" "/lib/modules/$KVER/build"
fi

[[ -f "/lib/modules/$KVER/build/Makefile" ]] ||
    die "/lib/modules/$KVER/build is still invalid."

pass "Kernel build link is valid."

section "INSTALL MISSING SUNXI SID HEADER"

SID_HEADER="$HEADER_ROOT/include/linux/sunxi-sid.h"
SID_COMPAT="$HEADER_ROOT/include/sunxi-sid.h"

mkdir -p "$HEADER_ROOT/include/linux"

if [[ -s "$SID_HEADER" ]]; then
    pass "sunxi-sid.h is already installed."
else
    SID_URL='https://raw.githubusercontent.com/orangepi-xunlong/OrangePiH6_kernel/master/include/linux/sunxi-sid.h'
    SID_TMP="$(mktemp)"

    echo "Downloading Allwinner SID compatibility header..."

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry 3 \
            --output "$SID_TMP" \
            "$SID_URL"
    else
        wget --tries=3 \
            --output-document="$SID_TMP" \
            "$SID_URL"
    fi

    grep -Eq 'sunxi_get_soc|sunxi_get_serial|sunxi_chip_id' "$SID_TMP" ||
        die "Downloaded SID header does not contain expected declarations."

    install -m 0644 "$SID_TMP" "$SID_HEADER"
    rm -f "$SID_TMP"

    pass "Installed $SID_HEADER."
fi

# The PowerVR source includes <sunxi-sid.h>, not <linux/sunxi-sid.h>.
ln -sfn linux/sunxi-sid.h "$SID_COMPAT"

[[ -e "$SID_COMPAT" ]] ||
    die "Failed to create compatibility header: $SID_COMPAT"

echo "Primary header:       $SID_HEADER"
echo "Compatibility header: $SID_COMPAT"
pass "PowerVR SID header dependency is repaired."

section "BUILD POWERVR DKMS MODULE"

MAKE_LOG="/var/lib/dkms/$PKG_NAME/$PKG_VER/build/make.log"

# If the module is already correctly installed, do not rebuild unnecessarily.
if modinfo pvrsrvkm >/dev/null 2>&1 &&
   modinfo -F vermagic pvrsrvkm 2>/dev/null |
       grep -Fq "$KVER"; then

    pass "pvrsrvkm is already installed for the running kernel."
else
    # Ensure the DKMS source is registered.
    if ! dkms status |
         grep -Fq "$PKG_NAME/$PKG_VER"; then
        dkms add \
            -m "$PKG_NAME" \
            -v "$PKG_VER"
    else
        pass "DKMS source is already registered."
    fi

    # Remove stale failed state only for this kernel.
    dkms remove \
        -m "$PKG_NAME" \
        -v "$PKG_VER" \
        -k "$KVER" 2>/dev/null || true

    echo "Building $PKG_NAME/$PKG_VER for $KVER..."

    dkms build \
        -m "$PKG_NAME" \
        -v "$PKG_VER" \
        -k "$KVER"

    dkms install \
        -m "$PKG_NAME" \
        -v "$PKG_VER" \
        -k "$KVER"

    depmod -a "$KVER"
fi

MODULE_FILE="$(
    find "/lib/modules/$KVER" \
        -type f \
        \( -name 'pvrsrvkm.ko' -o -name 'pvrsrvkm.ko.*' \) \
        2>/dev/null |
    head -1
)"

[[ -n "$MODULE_FILE" ]] ||
    die "DKMS completed, but pvrsrvkm.ko was not found."

echo "Installed module: $MODULE_FILE"
modinfo pvrsrvkm |
    grep -E '^(filename|version|vermagic|description):' ||
    true

pass "PowerVR kernel module is installed."

section "ENABLE POWERVR AT BOOT"

cat > /etc/modules-load.d/pvrsrvkm.conf <<'EOF'
pvrsrvkm
EOF

depmod -a

if lsmod | grep -q '^pvrsrvkm[[:space:]]'; then
    pass "pvrsrvkm is already loaded."
else
    modprobe pvrsrvkm
    pass "pvrsrvkm loaded successfully."
fi

sleep 2

lsmod | grep '^pvrsrvkm' ||
    die "pvrsrvkm did not remain loaded."

section "DEVICE PERMISSIONS"

getent group video >/dev/null ||
    groupadd --system video

getent group render >/dev/null ||
    groupadd --system render

usermod -aG video,render "$REAL_USER"

cat > /etc/udev/rules.d/70-orange-pi-accelerators.rules <<'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"
KERNEL=="vipcore", GROUP="render", MODE="0660"
EOF

udevadm control --reload-rules
udevadm trigger --subsystem-match=drm || true
udevadm trigger --name-match=vipcore || true

pass "$REAL_USER was added to the video and render groups."

section "CHECK GPU USERSPACE STACK"

echo "DRM devices:"
ls -la /dev/dri 2>/dev/null || true

if [[ -e /dev/dri/renderD128 ]]; then
    pass "/dev/dri/renderD128 exists."
else
    warn "renderD128 is not present yet; a reboot may be required."
fi

if [[ -d /etc/vulkan/icd.d || -d /usr/share/vulkan/icd.d ]]; then
    echo
    echo "Vulkan ICD files:"

    find /etc/vulkan/icd.d /usr/share/vulkan/icd.d \
        -maxdepth 1 \
        -type f \
        -name '*.json' \
        -print 2>/dev/null || true
fi

RUNTIME_DIR="/tmp/runtime-$(id -u "$REAL_USER")"
install -d -m 0700 -o "$REAL_USER" -g "$REAL_USER" "$RUNTIME_DIR"

set +e
VULKAN_OUTPUT="$(
    runuser -u "$REAL_USER" -- \
        env XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        timeout 20s vulkaninfo --summary 2>&1
)"
VULKAN_STATUS=$?
set -e

echo "$VULKAN_OUTPUT" |
    grep -Ei \
        'deviceName|deviceType|driverName|driverInfo|apiVersion|ERROR' ||
    true

if grep -Eqi 'PowerVR|Imagination|BXM' <<<"$VULKAN_OUTPUT"; then
    pass "Vulkan hardware acceleration detects the PowerVR GPU."
elif [[ "$VULKAN_STATUS" -eq 124 ]]; then
    warn "vulkaninfo timed out. Test again after reboot."
else
    warn "PowerVR was not detected by Vulkan yet. Verify proprietary Vulkan userspace files and reboot."
fi

section "CHECK NPU DRIVER"

if ! lsmod | grep -q '^vipcore[[:space:]]'; then
    modprobe vipcore 2>/dev/null || true
fi

if lsmod | grep -q '^vipcore[[:space:]]'; then
    pass "vipcore NPU module is loaded."
else
    warn "vipcore is not loaded."
fi

if [[ -c /dev/vipcore ]]; then
    pass "/dev/vipcore exists."
    ls -l /dev/vipcore
else
    warn "/dev/vipcore is missing."
fi

if [[ -f /usr/lib/libVIPhal.so ]]; then
    pass "VIPLite userspace HAL is installed."
else
    warn "/usr/lib/libVIPhal.so is missing."
fi

NPU_DEVFREQ="$(
    find /sys/class/devfreq \
        -mindepth 1 \
        -maxdepth 1 \
        \( -type l -o -type d \) 2>/dev/null |
    grep -Ei 'npu|vip' |
    head -1 || true
)"

if [[ -n "$NPU_DEVFREQ" ]]; then
    echo "NPU devfreq: $NPU_DEVFREQ"

    for field in \
        cur_freq \
        min_freq \
        max_freq \
        available_frequencies \
        governor; do

        if [[ -r "$NPU_DEVFREQ/$field" ]]; then
            echo "  $field: $(cat "$NPU_DEVFREQ/$field")"
        fi
    done

    pass "NPU clock/devfreq interface exists."
else
    warn "NPU devfreq interface was not found."
fi

section "PREPARE NPU INFERENCE TEST"

NPU_DIR="/opt/yolov5"
NPU_EXEC="$NPU_DIR/yolov5"
NPU_MODEL="$NPU_DIR/model/yolov5.nb"
NPU_IMAGE="$NPU_DIR/input_data/dog.jpg"

NPU_ASSETS_OK=1

for required in \
    "$NPU_EXEC" \
    "$NPU_MODEL" \
    "$NPU_IMAGE"; do

    if [[ ! -e "$required" ]]; then
        warn "Missing NPU test asset: $required"
        NPU_ASSETS_OK=0
    else
        echo "Found: $required"
    fi
done

if [[ -e "$NPU_EXEC" ]]; then
    chmod a+rx "$NPU_EXEC"
fi

if [[ -d "$NPU_DIR" ]]; then
    chmod a+rx "$NPU_DIR"
    chmod -R a+rX "$NPU_DIR/model" "$NPU_DIR/input_data" 2>/dev/null || true
fi

NPU_WORKDIR="$REAL_HOME/.cache/gpu-npu-verification"

install -d \
    -m 0755 \
    -o "$REAL_USER" \
    -g "$REAL_USER" \
    "$NPU_WORKDIR"

# Remove stale root-owned output from prior sudo-based tests.
rm -f \
    /tmp/npu-yolov5-test.log \
    "$NPU_WORKDIR/npu-yolov5-test.log" \
    "$NPU_WORKDIR/result.png" 2>/dev/null || true

chown -R "$REAL_USER:$REAL_USER" "$NPU_WORKDIR"

if [[ "$NPU_ASSETS_OK" -eq 1 ]]; then
    pass "NPU inference assets are ready."
else
    warn "Kernel-side NPU tests can run, but YOLOv5 inference assets are incomplete."
fi

section "INSTALL VERIFICATION SCRIPT"

cat > /usr/local/bin/test-gpu-npu <<'VERIFY'
#!/usr/bin/env bash

set -uo pipefail

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
RESET='\033[0m'

GPU_PASS=0
GPU_WARN=0
GPU_FAIL=0
GPU_VULKAN_PASS=0

NPU_PASS=0
NPU_WARN=0
NPU_FAIL=0
NPU_INFERENCE_RAN=0
NPU_INFERENCE_PASS=0

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }

section() {
    echo
    echo -e "${BLUE}========== $* ==========${RESET}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

kernel_log() {
    sudo dmesg 2>/dev/null ||
        dmesg 2>/dev/null ||
        true
}

sum_npu_interrupts() {
    grep -Ei 'vipcore|[[:space:]]npu([[:space:]]|$)' \
        /proc/interrupts 2>/dev/null |
    head -1 |
    awk '{
        total=0
        for (i=2; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/) {
                total += $i
            } else {
                break
            }
        }
        print total
    }'

    return 0
}

section "BOARD"

echo "Model:        $(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)"
echo "Kernel:       $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Hostname:     $(hostname)"
echo "User:         $(id -un)"

if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "SSH session:  yes"
    echo "SSH details:  $SSH_CONNECTION"
else
    echo "SSH session:  no"
fi

section "GPU KERNEL DRIVER"

if lsmod | grep -q '^pvrsrvkm[[:space:]]'; then
    pass "PowerVR GPU module is loaded"
    lsmod | grep '^pvrsrvkm'
    GPU_PASS=$((GPU_PASS + 1))
else
    fail "PowerVR GPU module is not loaded"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

if modinfo pvrsrvkm >/dev/null 2>&1; then
    pass "pvrsrvkm is installed for kernel $(uname -r)"
    modinfo pvrsrvkm |
        grep -E '^(filename|version|vermagic|description):' ||
        true
    GPU_PASS=$((GPU_PASS + 1))
else
    fail "pvrsrvkm is not installed"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

section "GPU DEVICE NODES"

ls -la /dev/dri 2>/dev/null || true

if compgen -G '/dev/dri/renderD*' >/dev/null; then
    pass "DRM render node exists"
    ls -l /dev/dri/renderD*
    GPU_PASS=$((GPU_PASS + 1))
else
    fail "DRM render node is missing"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

section "GPU KERNEL INITIALIZATION"

GPU_LOG="$(
    kernel_log |
    grep -Ei 'pvrsrvkm|PowerVR|PVR_K|RGX|1800000.gpu' |
    tail -100
)"

echo "$GPU_LOG"

if grep -Eqi \
    'RGX Device registered|Read BVNC|Initialized pvr' \
    <<<"$GPU_LOG"; then

    pass "PowerVR hardware initialized successfully"
    GPU_PASS=$((GPU_PASS + 1))
else
    fail "PowerVR hardware initialization was not confirmed"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

section "VULKAN HEADLESS TEST"

if command_exists vulkaninfo; then
    RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache/vulkan-runtime}"
    mkdir -p "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || true

    VULKAN_OUTPUT="$(
        timeout 20s env \
            XDG_RUNTIME_DIR="$RUNTIME_DIR" \
            vulkaninfo --summary 2>&1 ||
        true
    )"

    echo "$VULKAN_OUTPUT" |
        grep -Ei \
            'deviceName|deviceType|driverName|driverInfo|apiVersion|ERROR' |
        head -60 || true

    if grep -Eqi \
        'PowerVR B-Series|PowerVR|Imagination|BXM' \
        <<<"$VULKAN_OUTPUT"; then

        pass "Vulkan detects the PowerVR GPU"
        GPU_PASS=$((GPU_PASS + 1))
        GPU_VULKAN_PASS=1
    else
        fail "Vulkan did not detect the PowerVR GPU"
        GPU_FAIL=$((GPU_FAIL + 1))
    fi
else
    warn "vulkaninfo is not installed"
    GPU_WARN=$((GPU_WARN + 1))
fi

section "OPENGL / EGL"

warn "Desktop GLX may use llvmpipe even when PowerVR Vulkan acceleration works."
echo "Vulkan is the primary headless hardware verification."

if command_exists eglinfo; then
    timeout 15s eglinfo 2>&1 |
        grep -Ei \
            'EGL vendor string|EGL version string|Device vendor|Device name' |
        head -30 || true
fi

section "NPU KERNEL DRIVER"

if lsmod | grep -q '^vipcore[[:space:]]'; then
    pass "NPU kernel module is loaded"
    lsmod | grep '^vipcore'
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "NPU kernel module is not loaded"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

if [[ -c /dev/vipcore ]]; then
    pass "/dev/vipcore exists"
    ls -l /dev/vipcore
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "/dev/vipcore is missing"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

section "NPU INITIALIZATION"

NPU_LOG="$(
    kernel_log |
    grep -Ei \
        'vipcore|VIPLite|allwinner,npu|npu devfreq|NPU Use VF' |
    tail -120
)"

echo "$NPU_LOG"

if grep -Eqi 'device_cnt=1.*core_cnt=1' <<<"$NPU_LOG"; then
    pass "One NPU device and one core were detected"
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "NPU core detection was not confirmed"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

if grep -Eqi 'VIPLite driver version' <<<"$NPU_LOG"; then
    pass "VIPLite kernel driver initialized"
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "VIPLite kernel driver was not confirmed"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

section "NPU CLOCK"

NPU_DEVFREQ="$(
    find /sys/class/devfreq \
        -mindepth 1 \
        -maxdepth 1 \
        \( -type l -o -type d \) 2>/dev/null |
    grep -Ei 'npu|vip' |
    head -1 || true
)"

if [[ -n "$NPU_DEVFREQ" ]]; then
    echo "Device: $NPU_DEVFREQ"

    for field in \
        cur_freq \
        min_freq \
        max_freq \
        available_frequencies \
        governor; do

        [[ -r "$NPU_DEVFREQ/$field" ]] &&
            echo "$field: $(cat "$NPU_DEVFREQ/$field")"
    done

    pass "NPU devfreq interface exists"
    NPU_PASS=$((NPU_PASS + 1))
else
    warn "NPU devfreq interface was not found"
    NPU_WARN=$((NPU_WARN + 1))
fi

section "NPU USERSPACE RUNTIME"

if [[ -f /usr/lib/libVIPhal.so ]]; then
    pass "VIPLite userspace HAL is installed"
    ls -l /usr/lib/libVIPhal.so
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "VIPLite userspace HAL is missing"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

section "REAL NPU YOLOV5 INFERENCE"

NPU_DIR="/opt/yolov5"
NPU_DEMO="$NPU_DIR/yolov5"
NPU_MODEL="$NPU_DIR/model/yolov5.nb"
NPU_IMAGE="$NPU_DIR/input_data/dog.jpg"

NPU_WORKDIR="$HOME/.cache/gpu-npu-verification"
NPU_RESULT="$NPU_WORKDIR/result.png"
NPU_TEST_LOG="$NPU_WORKDIR/npu-yolov5-test.log"

mkdir -p "$NPU_WORKDIR"
rm -f "$NPU_TEST_LOG" "$NPU_RESULT"

if [[ ! -x "$NPU_DEMO" ]]; then
    warn "NPU executable is unavailable: $NPU_DEMO"
    NPU_WARN=$((NPU_WARN + 1))
elif [[ ! -f "$NPU_MODEL" ]]; then
    warn "NPU model is unavailable: $NPU_MODEL"
    NPU_WARN=$((NPU_WARN + 1))
elif [[ ! -f "$NPU_IMAGE" ]]; then
    warn "NPU input image is unavailable: $NPU_IMAGE"
    NPU_WARN=$((NPU_WARN + 1))
else
    NPU_INFERENCE_RAN=1
    IRQ_BEFORE="$(sum_npu_interrupts)"
    IRQ_BEFORE="${IRQ_BEFORE:-0}"

    echo "Executable: $NPU_DEMO"
    echo "Model:      $NPU_MODEL"
    echo "Input:      $NPU_IMAGE"
    echo "Work dir:   $NPU_WORKDIR"
    echo "Interrupts before: $IRQ_BEFORE"

    pushd "$NPU_WORKDIR" >/dev/null || exit 1

    set +e
    timeout 120s env \
        LD_LIBRARY_PATH="$NPU_DIR:/usr/lib:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
        "$NPU_DEMO" \
        "$NPU_MODEL" \
        "$NPU_IMAGE" 2>&1 |
        tee "$NPU_TEST_LOG"

    NPU_EXIT=${PIPESTATUS[0]}
    set -e

    popd >/dev/null || true

    IRQ_AFTER="$(sum_npu_interrupts)"
    IRQ_AFTER="${IRQ_AFTER:-0}"

    echo "Exit status:      $NPU_EXIT"
    echo "Interrupts after: $IRQ_AFTER"

    if [[ "$NPU_EXIT" -eq 0 ]]; then
        pass "YOLOv5 exited successfully"
        NPU_PASS=$((NPU_PASS + 1))
    else
        fail "YOLOv5 failed with status $NPU_EXIT"
        NPU_FAIL=$((NPU_FAIL + 1))
    fi

    if grep -Eqi \
        'VIPLite driver software version' \
        "$NPU_TEST_LOG"; then

        pass "VIPLite userspace runtime was used"
        NPU_PASS=$((NPU_PASS + 1))
    else
        fail "VIPLite userspace activity was not detected"
        NPU_FAIL=$((NPU_FAIL + 1))
    fi

    if grep -Eqi 'detection num:' "$NPU_TEST_LOG"; then
        pass "YOLOv5 produced detection results"
        NPU_PASS=$((NPU_PASS + 1))
    else
        fail "YOLOv5 detection output was not found"
        NPU_FAIL=$((NPU_FAIL + 1))
    fi

    if (( IRQ_AFTER > IRQ_BEFORE )); then
        pass "NPU interrupt count increased"
        NPU_PASS=$((NPU_PASS + 1))
    else
        warn "NPU interrupt count did not increase visibly"
        NPU_WARN=$((NPU_WARN + 1))
    fi

    if [[ -f "$NPU_RESULT" ]]; then
        pass "NPU result image was created"
        ls -lh "$NPU_RESULT"
        NPU_PASS=$((NPU_PASS + 1))
    else
        warn "NPU result image was not created"
        NPU_WARN=$((NPU_WARN + 1))
    fi

    if [[ "$NPU_EXIT" -eq 0 ]] &&
       grep -Eqi 'VIPLite driver software version' "$NPU_TEST_LOG" &&
       grep -Eqi 'detection num:' "$NPU_TEST_LOG" &&
       ! grep -Eqi \
           'fail to open NBG|network object is NULL|cv::Exception|Aborted|Segmentation fault' \
           "$NPU_TEST_LOG"; then

        NPU_INFERENCE_PASS=1
    fi
fi

section "FINAL RESULT"

echo "GPU checks: $GPU_PASS passed, $GPU_WARN warnings, $GPU_FAIL failed"
echo "NPU checks: $NPU_PASS passed, $NPU_WARN warnings, $NPU_FAIL failed"
echo

if [[ "$GPU_VULKAN_PASS" -eq 1 && "$GPU_FAIL" -eq 0 ]]; then
    echo -e \
        "${GREEN}GPU STATUS: WORKING — VULKAN HARDWARE ACCELERATION PASSED${RESET}"
elif [[ "$GPU_VULKAN_PASS" -eq 1 ]]; then
    echo -e \
        "${YELLOW}GPU STATUS: VULKAN WORKING WITH OTHER ERRORS${RESET}"
else
    echo -e \
        "${RED}GPU STATUS: NOT FULLY WORKING${RESET}"
fi

if [[ "$NPU_INFERENCE_RAN" -eq 1 &&
      "$NPU_INFERENCE_PASS" -eq 1 &&
      "$NPU_FAIL" -eq 0 ]]; then

    echo -e \
        "${GREEN}NPU STATUS: WORKING — REAL INFERENCE PASSED${RESET}"
elif [[ "$NPU_INFERENCE_RAN" -eq 1 ]]; then
    echo -e \
        "${RED}NPU STATUS: DRIVER LOADED, BUT INFERENCE FAILED${RESET}"
else
    echo -e \
        "${YELLOW}NPU STATUS: INFERENCE TEST UNAVAILABLE${RESET}"
fi
VERIFY

chmod 0755 /usr/local/bin/test-gpu-npu

pass "Installed /usr/local/bin/test-gpu-npu."

section "FINAL INSTALLATION STATUS"

echo "DKMS:"
dkms status || true

echo
echo "GPU module:"
lsmod | grep '^pvrsrvkm' || true

echo
echo "NPU module:"
lsmod | grep '^vipcore' || true

echo
echo "DRM:"
ls -la /dev/dri 2>/dev/null || true

echo
pass "Repair and installation steps completed."

echo
echo "Run the verification test as the normal user:"
echo
echo "  test-gpu-npu"
echo
echo "or:"
echo
echo "  test-gpu-npu 2>&1 | tee ~/gpu-npu-verification.txt"
echo
echo "The user was added to video/render groups, so a logout or reboot"
echo "is required before those new group memberships apply."

if [[ "$REBOOT_AFTER" -eq 1 ]]; then
    echo
    echo "Rebooting now..."
    sync
    systemctl reboot
else
    echo
    warn "Reboot recommended before final verification."
    echo
    echo "Reboot with:"
    echo "  sudo reboot"
fi
