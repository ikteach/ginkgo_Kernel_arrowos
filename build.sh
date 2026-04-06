#!/bin/bash
set -euo pipefail

# ================= COMMAND HANDLER (ADDED) =================
COMMAND="${1:-build}"

if [[ "$COMMAND" == "clean" ]]; then
    echo "Cleaning output directory..."
    rm -rf "$HOME/ginkgo/kernel-out"
    rm -rf out
    echo "Clean complete."
    exit 0
fi

KERNEL_DIR=$(pwd)
CLANG="neutron"
TC_DIR="$HOME/toolchains/$CLANG-clang"

# =================== 🔥 FORCE NEUTRON TOOLCHAIN (FIX) 🔥 ===================
if [ -d "$TC_DIR/bin" ]; then
    export PATH="$TC_DIR/bin:$PATH"
    hash -r
    echo "Using clang from:"
    which clang
    clang --version
else
    echo "Toolchain not found at $TC_DIR"
    exit 1
fi
# ============================================================================

if [[ "$COMMAND" == "menu" ]]; then
    echo "Opening menuconfig..."
    OUT="$HOME/ginkgo/kernel-out"
    mkdir -p "$OUT"
    make O="$OUT" ARCH=arm64 LLVM=1 nethunter_defconfig
    make O="$OUT" ARCH=arm64 LLVM=1 nconfig
    exit 0
fi
# ============================================================

AK3_URL="https://github.com/loukious/AnyKernel3.git"
AK3_BRANCH="master"
AK3_DIR="$HOME/ginkgo/anykernel"

patch_anykernel_script() {
    local anykernel_script="$AK3_DIR/anykernel.sh"
    if [ ! -f "$anykernel_script" ]; then
        echo "Warning: $anykernel_script not found, skipping patch step."
        return 0
    fi

    sed -i -E 's/\bvayu\b/ginkgo/g; s/\bbhima\b//g' "$anykernel_script"
    echo "Patched $anykernel_script (string replacements only)."
}

# Check if AK3 exist
if ! [ -d "$AK3_DIR" ]; then
    echo "$AK3_DIR not found! Cloning to $AK3_DIR..."
    if ! git clone -q --single-branch --depth 1 -b $AK3_BRANCH $AK3_URL $AK3_DIR; then
        echo "Cloning failed! Aborting..."
        exit 1
    fi
else
    echo "$AK3_DIR found! Update $AK3_DIR"
    cd $AK3_DIR
    git pull
    cd $KERNEL_DIR
fi

patch_anykernel_script

# =================== REMOVED SUBMODULES SECTION ===================
# All WiFi driver submodule handling has been removed
# ===================================================================

if ! [ -d "$TC_DIR" ]; then
    echo "$TC_DIR not found! Setting it up..."
    mkdir -p $TC_DIR
    cd $TC_DIR
    bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S=10032024
    bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") --patch=glibc
    cd $KERNEL_DIR
else
    echo "$TC_DIR found!"
fi

DEFCONFIG="nethunter_defconfig"
ZIP_PREFIX="NetHunter"
VERSION="${2:-latest}"

SECONDS=0
ZIPNAME="$ZIP_PREFIX-Ikteach-$VERSION-$(date '+%Y%m%d-%H%M').zip"
MZIPNAME="$ZIP_PREFIX-Modules-$VERSION-Ikteach-$(date '+%Y%m%d-%H%M').zip"
export PROC="-j$(nproc)"

echo "Building kernel with DEFCONFIG: $DEFCONFIG"

# STABILITY FIX: Disable ccache to prevent kernel build corruption
export USE_CCACHE=0
export CCACHE_EXEC=/usr/local/bin/ccache

KERNEL_VER="$(date '+%Y%m%d-%H%M')"
OUT="$HOME/ginkgo/kernel-out"

MAKE_PARAMS=(
    O="$OUT"
    ARCH=arm64
    LLVM=1
    CLANG_PATH="$TC_DIR/bin"
    CC="clang"
    CXX="clang++"
    HOSTCC="clang"
    HOSTCXX="clang++"
    LD=ld.lld
    AR=llvm-ar
    AS=llvm-as
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    CROSS_COMPILE="aarch64-linux-gnu-"
    CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"
    CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    KBUILD_BUILD_USER="Ikteach"
    KBUILD_BUILD_HOST="linux"
)

function clean_all {
    cd $KERNEL_DIR
    rm -rf prebuilt
    rm -rf out && rm -rf $OUT
}

clean_all
echo "All Cleaned now."

function create_modules_zip {
    if [ ! -d "${KERNEL_DIR}/modules/system/lib/modules" ]; then
        mkdir -p "${KERNEL_DIR}/modules/system/lib/modules"
    fi
    find "${KERNEL_DIR}/out/modules" -type f -iname '*.ko' -exec cp {} "${KERNEL_DIR}/modules/system/lib/modules/" \;
    cd "${KERNEL_DIR}/modules" || exit 1
    zip -r9 "../$MZIPNAME" . -x ".git*" "README.md" "LICENSE" "*.zip"
    echo -e "\n[✓] Built Modules and packaged into $MZIPNAME!"
}

mkdir -p $OUT

# Hiding the specific ld.lld warning using grep
make $PROC "${MAKE_PARAMS[@]}" $DEFCONFIG
echo -e "\nStarting compilation...\n"
make $PROC "${MAKE_PARAMS[@]}" 2> >(grep -v "no version information available" >&2)

echo -e "\nBuilding Image.gz-dtb and dtbo.img...\n"
make $PROC "${MAKE_PARAMS[@]}" Image.gz-dtb 2> >(grep -v "no version information available" >&2) || true
make $PROC "${MAKE_PARAMS[@]}" dtbo.img 2> >(grep -v "no version information available" >&2) || true

make $PROC "${MAKE_PARAMS[@]}" modules_install INSTALL_MOD_PATH="${KERNEL_DIR}/out/modules" 2> >(grep -v "no version information available" >&2)

if [ ! -d "${KERNEL_DIR}/modules" ]; then
    git clone --depth=1 https://github.com/neternels/neternels-modules "${KERNEL_DIR}/modules"
fi

create_modules_zip

function create_zip {
    cd $KERNEL_DIR
    cp -r $AK3_DIR AnyKernel3
    cp $OUT/arch/arm64/boot/Image AnyKernel3

    if [ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ]; then
        cp $OUT/arch/arm64/boot/Image.gz-dtb AnyKernel3
    fi
    if [ -f "$OUT/arch/arm64/boot/dtbo.img" ]; then
        cp $OUT/arch/arm64/boot/dtbo.img AnyKernel3
    fi

    cd AnyKernel3
    zip -r9 "../$ZIPNAME" * -x '*.git*' README.md *placeholder
    cd ..
    rm -rf AnyKernel3
    rm -rf $OUT/arch/arm64/boot
    echo -e "\nCompleted in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)"
    echo "Zip: $ZIPNAME"
}

if [ -f "$OUT/arch/arm64/boot/Image" ]; then
    echo -e "\nKernel compiled successfully!"
    # INTEGRITY CHECK
    if file "$OUT/arch/arm64/boot/Image" | grep -q "ARM aarch64"; then
        echo "Kernel Image integrity verified [OK]"
    else
        echo "Warning: Image file check failed!"
    fi
    create_zip
    echo -e "\nDone!"
else
    echo -e "\nFailed!"
fi
