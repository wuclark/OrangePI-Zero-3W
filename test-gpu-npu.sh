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

pass() {
    echo -e "${GREEN}[PASS]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

fail() {
    echo -e "${RED}[FAIL]${RESET} $1"
}

section() {
    echo
    echo -e "${BLUE}========== $1 ==========${RESET}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

sudo_dmesg() {
    sudo dmesg 2>/dev/null || dmesg 2>/dev/null || true
}

find_x_display() {
    local display=""

    display="$(
        ps -eo args 2>/dev/null |
        grep -E '[X]org .*:[0-9]+' |
        sed -n 's/.* \(:[0-9][0-9]*\)\(\.[0-9][0-9]*\)\?.*/\1/p' |
        head -1
    )"

    if [ -z "$display" ]; then
        display="$(
            find /tmp/.X11-unix \
                -maxdepth 1 \
                -type s \
                -name 'X*' 2>/dev/null |
            sed 's#.*/X#:#' |
            sort -V |
            head -1
        )"
    fi

    printf '%s' "$display"
}

find_xauthority() {
    local display="$1"
    local display_number="${display#:}"
    local xauth=""
    local candidate=""

    xauth="$(
        ps -eo args 2>/dev/null |
        grep -E '[X]org ' |
        grep -F "$display" |
        sed -n 's/.*-auth \([^ ]*\).*/\1/p' |
        head -1
    )"

    if [ -n "$xauth" ] && [ -r "$xauth" ]; then
        printf '%s' "$xauth"
        return
    fi

    for candidate in \
        "$HOME/.Xauthority" \
        "/home/orangepi/.Xauthority" \
        "/run/user/$(id -u)/gdm/Xauthority" \
        "/var/run/lightdm/root/:${display_number}" \
        "/var/lib/lightdm/.Xauthority"; do

        if [ -r "$candidate" ]; then
            printf '%s' "$candidate"
            return
        fi
    done

    find "/run/user/$(id -u)" \
        -maxdepth 1 \
        -type f \
        -name '.mutter-Xwaylandauth*' \
        -readable 2>/dev/null |
    head -1
}

sum_npu_interrupts() {
    local line=""

    line="$(
        grep -Ei 'vipcore|[[:space:]]npu([[:space:]]|$)' \
            /proc/interrupts 2>/dev/null |
        head -1
    )"

    if [ -z "$line" ]; then
        echo 0
        return
    fi

    echo "$line" |
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
}

section "BOARD"

MODEL="$(
    tr -d '\0' </proc/device-tree/model 2>/dev/null ||
    echo "Unknown"
)"

COMPATIBLE="$(
    tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null ||
    true
)"

echo "Model:        $MODEL"
echo "Kernel:       $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Hostname:     $(hostname)"
echo "User:         $(id -un)"

if [ -n "${SSH_CONNECTION:-}" ]; then
    echo "SSH session:  yes"
    echo "SSH details:  $SSH_CONNECTION"
else
    echo "SSH session:  no"
fi

echo "Compatible:"
echo "$COMPATIBLE" | sed 's/^/  /'

section "GPU KERNEL DRIVER"

GPU_MODULES="$(
    lsmod |
    grep -Ei '^(pvrsrvkm|pvr|img)[[:space:]]' ||
    true
)"

if [ -n "$GPU_MODULES" ]; then
    pass "PowerVR GPU module is loaded"
    echo "$GPU_MODULES"
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
    fail "pvrsrvkm is not installed for kernel $(uname -r)"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

section "GPU DEVICE NODES"

if [ -d /dev/dri ]; then
    ls -la /dev/dri
else
    fail "/dev/dri does not exist"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

if compgen -G '/dev/dri/renderD*' >/dev/null; then
    pass "A DRM render node exists"
    ls -l /dev/dri/renderD*
    GPU_PASS=$((GPU_PASS + 1))
else
    fail "No DRM render node exists"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

if [ -e /dev/dri/card1 ]; then
    pass "Separate PowerVR DRM card exists at /dev/dri/card1"
    GPU_PASS=$((GPU_PASS + 1))
else
    warn "/dev/dri/card1 was not found"
    GPU_WARN=$((GPU_WARN + 1))
fi

section "GPU KERNEL INITIALIZATION"

GPU_LOG="$(
    sudo_dmesg |
    grep -Ei 'pvrsrvkm|PowerVR|PVR_K|RGX|img-bxm|1800000.gpu' |
    tail -120
)"

if [ -n "$GPU_LOG" ]; then
    echo "$GPU_LOG"
else
    warn "No PowerVR initialization messages were found"
    GPU_WARN=$((GPU_WARN + 1))
fi

if echo "$GPU_LOG" |
   grep -Eqi 'RGX Device registered|Read BVNC|Initialized pvr'; then

    pass "PowerVR hardware initialized successfully"
    GPU_PASS=$((GPU_PASS + 1))
else
    fail "PowerVR hardware initialization was not confirmed"
    GPU_FAIL=$((GPU_FAIL + 1))
fi

if echo "$GPU_LOG" |
   grep -Eqi 'unknown symbol|firmware.*failed|fatal'; then

    warn "Potential PowerVR driver errors were found"
    GPU_WARN=$((GPU_WARN + 1))
fi

section "VULKAN HEADLESS TEST"

if command_exists vulkaninfo; then
    RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"

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
    head -60 ||
    true

    if echo "$VULKAN_OUTPUT" |
       grep -Eqi 'PowerVR B-Series|PowerVR|Imagination|BXM'; then

        pass "Vulkan detects the PowerVR GPU"
        GPU_PASS=$((GPU_PASS + 1))
        GPU_VULKAN_PASS=1
    else
        fail "Vulkan did not detect the PowerVR GPU"
        GPU_FAIL=$((GPU_FAIL + 1))
    fi
else
    warn "vulkaninfo is not installed"
    echo "Install with: sudo apt install vulkan-tools"
    GPU_WARN=$((GPU_WARN + 1))
fi

section "OPENGL / EGL OVER SSH"

if command_exists glxinfo; then
    TEST_DISPLAY="${DISPLAY:-$(find_x_display)}"

    if [ -n "$TEST_DISPLAY" ]; then
        TEST_XAUTHORITY="${XAUTHORITY:-$(find_xauthority "$TEST_DISPLAY")}"

        echo "Detected display: $TEST_DISPLAY"

        if [ -n "$TEST_XAUTHORITY" ]; then
            echo "Xauthority:      $TEST_XAUTHORITY"
        else
            echo "Xauthority:      not found"
        fi

        if [ -n "$TEST_XAUTHORITY" ]; then
            GLX_OUTPUT="$(
                timeout 20s env \
                    DISPLAY="$TEST_DISPLAY" \
                    XAUTHORITY="$TEST_XAUTHORITY" \
                    glxinfo -B 2>&1 ||
                true
            )"
        else
            GLX_OUTPUT="$(
                timeout 20s env \
                    DISPLAY="$TEST_DISPLAY" \
                    glxinfo -B 2>&1 ||
                true
            )"
        fi

        echo "$GLX_OUTPUT"

        if echo "$GLX_OUTPUT" |
           grep -Eqi 'OpenGL renderer.*(PowerVR|Imagination|BXM)'; then

            pass "OpenGL is using the PowerVR GPU"
            GPU_PASS=$((GPU_PASS + 1))

        elif echo "$GLX_OUTPUT" |
             grep -Eqi 'llvmpipe|softpipe|software rasterizer'; then

            warn "Desktop OpenGL is using llvmpipe software rendering"
            echo "The PowerVR GPU is still verified through Vulkan."
            GPU_WARN=$((GPU_WARN + 1))

        elif echo "$GLX_OUTPUT" |
             grep -Eqi \
             'unable to open display|authorization required|No protocol specified'; then

            warn "HDMI display exists, but this SSH session lacks X authorization"
            echo "Vulkan still provides valid headless GPU verification."
            GPU_WARN=$((GPU_WARN + 1))

        else
            warn "OpenGL renderer could not be identified"
            GPU_WARN=$((GPU_WARN + 1))
        fi
    else
        warn "No active X11 display was detected"
        echo "This is normal for a server without an active desktop."
        echo "Vulkan still provides valid headless GPU verification."
        GPU_WARN=$((GPU_WARN + 1))
    fi
else
    warn "glxinfo is not installed"
    echo "Install with: sudo apt install mesa-utils"
    GPU_WARN=$((GPU_WARN + 1))
fi

echo
echo "--- Headless EGL summary ---"

if command_exists eglinfo; then
    RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"

    mkdir -p "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || true

    EGL_OUTPUT="$(
        timeout 20s env \
            XDG_RUNTIME_DIR="$RUNTIME_DIR" \
            eglinfo 2>&1 ||
        true
    )"

    echo "$EGL_OUTPUT" |
    grep -Ei \
        'EGL vendor string|EGL version string|Device vendor|Device name|driver name' |
    head -50 ||
    true
else
    warn "eglinfo is not installed"
    echo "Install with: sudo apt install mesa-utils-extra"
    GPU_WARN=$((GPU_WARN + 1))
fi

section "NPU KERNEL DRIVER"

NPU_MODULES="$(
    lsmod |
    grep -Ei '^(vipcore|galcore|vivante|npu|vsi)[[:space:]]' ||
    true
)"

if [ -n "$NPU_MODULES" ]; then
    pass "NPU kernel module is loaded"
    echo "$NPU_MODULES"
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "NPU kernel module is not loaded"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

if [ -c /dev/vipcore ]; then
    pass "/dev/vipcore exists"
    ls -l /dev/vipcore
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "/dev/vipcore does not exist"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

section "NPU KERNEL INITIALIZATION"

NPU_LOG="$(
    sudo_dmesg |
    grep -Ei 'vipcore|VIPLite|allwinner,npu|npu devfreq|NPU Use VF' |
    tail -140
)"

if [ -n "$NPU_LOG" ]; then
    echo "$NPU_LOG"
else
    fail "No NPU initialization messages were found"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

if echo "$NPU_LOG" |
   grep -Eqi 'device_cnt=1.*core_cnt=1'; then

    pass "One NPU device and one NPU core were detected"
    NPU_PASS=$((NPU_PASS + 1))
else
    fail "NPU core detection was not confirmed"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

if echo "$NPU_LOG" |
   grep -Eqi 'VIPLite driver version'; then

    pass "VIPLite kernel driver initialized"

    echo "$NPU_LOG" |
    grep -Ei 'VIPLite driver version' |
    tail -1

    NPU_PASS=$((NPU_PASS + 1))
else
    fail "VIPLite kernel driver initialization was not confirmed"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

section "NPU CLOCK"

NPU_DEVFREQ="$(
    find /sys/class/devfreq \
        -mindepth 1 \
        -maxdepth 1 \
        \( -type l -o -type d \) 2>/dev/null |
    grep -Ei 'npu|vip' |
    head -1 ||
    true
)"

if [ -n "$NPU_DEVFREQ" ] && [ -d "$NPU_DEVFREQ" ]; then
    echo "Device: $NPU_DEVFREQ"

    for FILE in \
        cur_freq \
        min_freq \
        max_freq \
        available_frequencies \
        governor; do

        if [ -r "$NPU_DEVFREQ/$FILE" ]; then
            echo "$FILE: $(cat "$NPU_DEVFREQ/$FILE")"
        fi
    done

    pass "NPU devfreq interface exists"
    NPU_PASS=$((NPU_PASS + 1))
else
    warn "No NPU devfreq interface was found"
    NPU_WARN=$((NPU_WARN + 1))
fi

section "NPU USERSPACE RUNTIME"

if [ -f /usr/lib/libVIPhal.so ] ||
   ldconfig -p 2>/dev/null | grep -qi 'libVIPhal'; then

    pass "VIPLite userspace HAL is installed"

    ls -l /usr/lib/libVIPhal.so 2>/dev/null ||
    ldconfig -p | grep -i 'libVIPhal' ||
    true

    NPU_PASS=$((NPU_PASS + 1))
else
    fail "VIPLite userspace HAL was not found"
    NPU_FAIL=$((NPU_FAIL + 1))
fi

section "REAL NPU YOLOV5 INFERENCE"

NPU_DIR="/opt/yolov5"
NPU_DEMO="$NPU_DIR/yolov5"
NPU_MODEL="$NPU_DIR/model/yolov5.nb"
NPU_IMAGE="$NPU_DIR/input_data/dog.jpg"

NPU_WORKDIR="${HOME}/.cache/gpu-npu-verification"
NPU_RESULT="$NPU_WORKDIR/result.png"
NPU_TEST_LOG="$NPU_WORKDIR/npu-yolov5-test.log"

mkdir -p "$NPU_WORKDIR"

if [ ! -x "$NPU_DEMO" ]; then
    warn "NPU executable not found: $NPU_DEMO"
    NPU_WARN=$((NPU_WARN + 1))

elif [ ! -f "$NPU_MODEL" ]; then
    warn "NPU model not found: $NPU_MODEL"
    NPU_WARN=$((NPU_WARN + 1))

elif [ ! -f "$NPU_IMAGE" ]; then
    warn "NPU input image not found: $NPU_IMAGE"
    NPU_WARN=$((NPU_WARN + 1))

else
    NPU_INFERENCE_RAN=1

    echo "Executable: $NPU_DEMO"
    echo "Model:      $NPU_MODEL"
    echo "Input:      $NPU_IMAGE"
    echo "Work dir:   $NPU_WORKDIR"
    echo "Result:     $NPU_RESULT"
    echo "Log:        $NPU_TEST_LOG"

    BEFORE_MTIME=0

    if [ -f "$NPU_RESULT" ]; then
        BEFORE_MTIME="$(
            stat -c %Y "$NPU_RESULT" 2>/dev/null ||
            echo 0
        )"
    fi

    IRQ_BEFORE="$(sum_npu_interrupts)"
    echo "NPU interrupt count before: $IRQ_BEFORE"

    rm -f "$NPU_TEST_LOG"

    pushd "$NPU_WORKDIR" >/dev/null || exit 1

    set +e

    timeout 120s \
        env \
        LD_LIBRARY_PATH="$NPU_DIR:/usr/lib:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
        "$NPU_DEMO" \
        "$NPU_MODEL" \
        "$NPU_IMAGE" 2>&1 |
    tee "$NPU_TEST_LOG"

    NPU_EXIT=${PIPESTATUS[0]}

    set -e

    popd >/dev/null || true

    IRQ_AFTER="$(sum_npu_interrupts)"

    AFTER_MTIME=0

    if [ -f "$NPU_RESULT" ]; then
        AFTER_MTIME="$(
            stat -c %Y "$NPU_RESULT" 2>/dev/null ||
            echo 0
        )"
    fi

    echo
    echo "Exit status:               $NPU_EXIT"
    echo "NPU interrupt count before: $IRQ_BEFORE"
    echo "NPU interrupt count after:  $IRQ_AFTER"

    if [ -f "$NPU_RESULT" ]; then
        echo
        echo "Result file:"
        ls -lh "$NPU_RESULT"
        file "$NPU_RESULT"
    fi

    if [ "$NPU_EXIT" -eq 0 ]; then
        pass "YOLOv5 program exited successfully"
        NPU_PASS=$((NPU_PASS + 1))

    elif [ "$NPU_EXIT" -eq 124 ]; then
        fail "YOLOv5 inference timed out after 120 seconds"
        NPU_FAIL=$((NPU_FAIL + 1))

    else
        fail "YOLOv5 program failed with exit status $NPU_EXIT"
        NPU_FAIL=$((NPU_FAIL + 1))
    fi

    if grep -Eqi \
       'VIPLite driver software version' \
       "$NPU_TEST_LOG"; then

        pass "YOLOv5 loaded the VIPLite userspace runtime"
        NPU_PASS=$((NPU_PASS + 1))
    else
        fail "VIPLite userspace runtime activity was not detected"
        NPU_FAIL=$((NPU_FAIL + 1))
    fi

    if grep -Eqi \
       'detection num:|dog|car|bicycle' \
       "$NPU_TEST_LOG"; then

        pass "YOLOv5 produced detection results"
        NPU_PASS=$((NPU_PASS + 1))
    else
        warn "No expected YOLOv5 detection text was found"
        NPU_WARN=$((NPU_WARN + 1))
    fi

    if grep -Eqi \
       'fail to open NBG|network object is NULL|fail to ioctl|cv::Exception|Aborted|Segmentation fault' \
       "$NPU_TEST_LOG"; then

        fail "NPU inference reported a model, driver, or application error"
        NPU_FAIL=$((NPU_FAIL + 1))
    fi

    if [ "$IRQ_AFTER" -gt "$IRQ_BEFORE" ]; then
        pass "NPU interrupt count increased during inference"
        NPU_PASS=$((NPU_PASS + 1))
    else
        warn "NPU interrupt count did not visibly increase"
        NPU_WARN=$((NPU_WARN + 1))
    fi

    if [ -f "$NPU_RESULT" ] &&
       [ "$AFTER_MTIME" -gt "$BEFORE_MTIME" ]; then

        pass "result.png was created or updated"
        NPU_PASS=$((NPU_PASS + 1))

    elif [ -f "$NPU_RESULT" ]; then
        warn "result.png exists but was not updated"
        NPU_WARN=$((NPU_WARN + 1))

    else
        warn "No result.png was produced"
        NPU_WARN=$((NPU_WARN + 1))
    fi

    if [ "$NPU_EXIT" -eq 0 ] &&
       grep -Eqi 'VIPLite driver software version' "$NPU_TEST_LOG" &&
       grep -Eqi 'detection num:' "$NPU_TEST_LOG" &&
       ! grep -Eqi \
       'fail to open NBG|network object is NULL|fail to ioctl|cv::Exception|Aborted|Segmentation fault' \
       "$NPU_TEST_LOG"; then

        NPU_INFERENCE_PASS=1
    fi
fi

section "FINAL RESULT"

echo "GPU checks: $GPU_PASS passed, $GPU_WARN warnings, $GPU_FAIL failed"
echo "NPU checks: $NPU_PASS passed, $NPU_WARN warnings, $NPU_FAIL failed"
echo

if [ "$GPU_VULKAN_PASS" -eq 1 ] &&
   [ "$GPU_FAIL" -eq 0 ]; then

    echo -e \
        "${GREEN}GPU STATUS: WORKING — VULKAN HARDWARE ACCELERATION PASSED${RESET}"

elif [ "$GPU_VULKAN_PASS" -eq 1 ]; then

    echo -e \
        "${YELLOW}GPU STATUS: WORKING — VULKAN PASSED WITH OTHER WARNINGS${RESET}"

elif [ "$GPU_PASS" -gt 0 ]; then

    echo -e \
        "${YELLOW}GPU STATUS: PARTIALLY WORKING${RESET}"

else
    echo -e \
        "${RED}GPU STATUS: NOT WORKING${RESET}"
fi

if [ "$NPU_INFERENCE_RAN" -eq 1 ]; then
    if [ "$NPU_INFERENCE_PASS" -eq 1 ] &&
       [ "$NPU_FAIL" -eq 0 ]; then

        echo -e \
            "${GREEN}NPU STATUS: WORKING — REAL INFERENCE PASSED${RESET}"
    else
        echo -e \
            "${RED}NPU STATUS: DRIVER LOADED, BUT INFERENCE FAILED${RESET}"
    fi
else
    if [ "$NPU_FAIL" -eq 0 ] &&
       [ "$NPU_PASS" -ge 5 ]; then

        echo -e \
            "${YELLOW}NPU STATUS: DRIVER WORKING — INFERENCE TEST UNAVAILABLE${RESET}"
    else
        echo -e \
            "${RED}NPU STATUS: NOT FULLY WORKING${RESET}"
    fi
fi

echo
echo "Notes:"
echo "- Vulkan is the primary headless GPU verification."
echo "- llvmpipe in X11 is reported as a warning, not a GPU hardware failure."
echo "- OpenGL is tested against the active HDMI desktop when available."
echo "- The NPU test performs real YOLOv5 inference."
echo "- NPU output: $NPU_RESULT"
echo "- NPU log:    $NPU_TEST_LOG"
