#!/bin/bash
set -euo pipefail

# ================= COMMAND HANDLER =================
COMMAND="${1:-build}"

if [[ "$COMMAND" == "clean" ]]; then
    echo "Cleaning output directory..."
    rm -rf "$HOME/arrowos-v2/kernel-out"
    rm -rf "$HOME/arrowos-v2/modules_out"
    echo "Clean complete."
    exit 0
elif [[ "$COMMAND" == "menu" ]]; then
    echo "Opening menuconfig..."
    mkdir -p "$HOME/arrowos-v2/kernel-out"
    make O="$HOME/arrowos-v2/kernel-out" ARCH=arm64 LLVM=1 nethunter_defconfig
    make O="$HOME/arrowos-v2/kernel-out" ARCH=arm64 LLVM=1 menuconfig
    exit 0
fi

KERNEL_DIR=$(pwd)
CLANG="neutron"
TC_DIR="$HOME/toolchains/$CLANG-clang"
OUT="$HOME/arrowos-v2/kernel-out"
MOD_STAGING="${KERNEL_DIR}/modules_out"
# This folder is where we will collect the .ko files for zipping
MODULE_ZIP_DIR="${KERNEL_DIR}/modules_to_zip"

# =================== FORCE NEUTRON TOOLCHAIN ===================
if [ -d "$TC_DIR/bin" ]; then
    export PATH="$TC_DIR/bin:$PATH"
    hash -r
    echo "Using clang from: $(which clang)"
else
    echo "Toolchain not found at $TC_DIR"
    exit 1
fi

# =================== SETUP AK3 ===================
AK3_URL="https://github.com/loukious/AnyKernel3.git"
AK3_BRANCH="master"
AK3_DIR="$HOME/arrowos-v2/anykernel"

if [ ! -d "$AK3_DIR" ]; then
    git clone -q --single-branch --depth 1 -b $AK3_BRANCH $AK3_URL $AK3_DIR
else
    cd $AK3_DIR && git pull && cd $KERNEL_DIR
fi

# =================== BUILD PARAMS ===================
DEFCONFIG="nethunter_defconfig"
ZIP_PREFIX="NetHunter"
VERSION="${2:-latest}"
SECONDS=0
ZIPNAME="$ZIP_PREFIX-Ikteach-$VERSION-$(date '+%Y%m%d-%H%M').zip"
MZIPNAME="$ZIP_PREFIX-Modules-$VERSION-Ikteach-$(date '+%Y%m%d-%H%M').zip"

export PROC="-j$(nproc)"
export USE_CCACHE=0

MAKE_PARAMS=(
    O="$OUT" ARCH=arm64 LLVM=1 CLANG_PATH="$TC_DIR/bin"
    CC="clang" CXX="clang++" HOSTCC="clang" HOSTCXX="clang++"
    LD=ld.lld AR=llvm-ar AS=llvm-as NM=llvm-nm OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump STRIP=llvm-strip CROSS_COMPILE="aarch64-linux-gnu-"
    KBUILD_BUILD_USER="Ikteach" KBUILD_BUILD_HOST="linux" KBUILD_BUILD_VERSION="4.0"
)

# =================== BUILD EXECUTION ===================
mkdir -p "$OUT"
rm -rf "$MOD_STAGING" && mkdir -p "$MOD_STAGING"
rm -f "$OUT/.config"

echo "Building kernel with DEFCONFIG: $DEFCONFIG"
make $PROC "${MAKE_PARAMS[@]}" $DEFCONFIG
make $PROC "${MAKE_PARAMS[@]}" 2> >(grep -v "no version information available" >&2)
make $PROC "${MAKE_PARAMS[@]}" Image.gz-dtb dtbo.img 2> >(grep -v "no version information available" >&2) || true

# Build and extract modules
echo -e "\nBuilding Modules..."
make $PROC "${MAKE_PARAMS[@]}" modules
make $PROC "${MAKE_PARAMS[@]}" modules_install INSTALL_MOD_PATH="$MOD_STAGING"

# =================== ZIP PACKAGING ===================
function create_zip {
    cd "$KERNEL_DIR"
    
    # Kernel Zip
    [ -d "AnyKernel3" ] && rm -rf AnyKernel3
    cp -r "$AK3_DIR" AnyKernel3
    cp "$OUT/arch/arm64/boot/Image" AnyKernel3/
    [ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] && cp "$OUT/arch/arm64/boot/Image.gz-dtb" AnyKernel3/
    [ -f "$OUT/arch/arm64/boot/dtbo.img" ] && cp "$OUT/arch/arm64/boot/dtbo.img" AnyKernel3/
    
    cd AnyKernel3
    zip -r1 "../$ZIPNAME" * -x '*.git*' README.md *placeholder
    cd ..
    
    # Modules Zip (The "Old Way" using find)
    echo "Packaging modules..."
    rm -rf "$MODULE_ZIP_DIR" && mkdir -p "$MODULE_ZIP_DIR/system/lib/modules"
    find "$MOD_STAGING" -type f -iname '*.ko' -exec cp {} "$MODULE_ZIP_DIR/system/lib/modules/" \;
    
    cd "$MODULE_ZIP_DIR"
    zip -r1 "../$MZIPNAME" .
    cd ..
    
    echo -e "\n[✓] Kernel Zip: $ZIPNAME"
    echo -e "[✓] Modules Zip: $MZIPNAME"
}

if [ -f "$OUT/arch/arm64/boot/Image" ]; then
    create_zip
else
    echo -e "\nERROR: Build failed."
    exit 1
fi
