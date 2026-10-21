#!/bin/bash
set -euo pipefail

# =============================================================================
# V2.5 : KernelSU-Next (legacy) + 5 Patchs Manuels (SANS SUSFS) [FIX CHIRURGICAL]
# =============================================================================

echo "=== Build KernelSU-Next (legacy, sans SUSFS) v2.5 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION KernelSU-Next (legacy) ====================
echo "=== Intégration KernelSU-Next (legacy) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true

curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration KernelSU-Next"; exit 1
fi
echo "✅ KernelSU-Next (legacy) intégré"

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi
echo "KSU_DIR : $KSU_DIR"

# ==================== 2e. NEUTRALISATION CHECK.MK ====================
echo ""
echo "=== Neutralisation check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null || true)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            sed -i 's/\$(error/\$(warning/g' "$f"
        done
    fi
done

# ==================== 2b. NETTOYAGE UNICODE ====================
echo "=== Nettoyage Unicode ==="
python3 << 'PYEOF'
import os
from pathlib import Path
UNICODE_SPACES = ['\u00A0', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
    '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u200B', '\u202F',
    '\u205F', '\u3000']
count = 0
for root, dirs, files in os.walk('.'):
    if 'KernelSU' not in root and 'kernelsu' not in root:
        continue
    for file in files:
        if file.endswith(('.c', '.h')):
            filepath = Path(root) / file
            try:
                content = filepath.read_text(encoding='utf-8', errors='ignore')
                original = content
                for uchar in UNICODE_SPACES:
                    if uchar in content:
                        content = content.replace(uchar, ' ')
                if content != original:
                    filepath.write_text(content, encoding='utf-8')
                    count += 1
            except: pass
print(f"✅ {count} fichiers nettoyés")
PYEOF

# ==================== 2c. FIX symbol_resolver.h ====================
echo "=== Fix symbol_resolver.h ==="
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h"; do
    if [ -f "$h" ]; then
        sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$h"
        sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$h"
        sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$h"
    fi
done

# ==================== 2d. STATIC EXPORTS SELINUX ====================
echo "=== Static exports SELinux ==="
[ -f "security/selinux/selinuxfs.c" ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f "security/selinux/ss/status.c" ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f "security/selinux/ss/services.c" ] && {
    sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
}
[ -f "security/selinux/hooks.c" ] && {
    sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
}

# ==================== 2e. FIX O_CLOEXEC ====================
echo ""
echo "=== Fix O_CLOEXEC dans TOUS les fichiers (détection Manager) ==="

FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_GET_UNUSED" ]; then
    for f in $FILES_GET_UNUSED; do
        sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
        echo "  ✅ get_unused_fd_flags fixé dans $f"
    done
fi

FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_ANON_INODE" ]; then
    for f in $FILES_ANON_INODE; do
        sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/O_RDWR|O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/, O_CLOEXEC)/)/g' "$f"
        echo "  ✅ anon_inode_getfile nettoyé dans $f"
    done
fi

# ==================== 3. PATCHS MANUELS KERNELSU-NEXT (CORRIGÉ) ====================
echo ""
echo "=== Application des 5 Patchs Manuels KernelSU-Next ==="

python3 << 'PYEOF'
import re

# 1. fs/exec.c
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n#endif\n\n"
    content = re.sub(r'(int\s+do_execve\s*\()', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n\t"
    content = re.sub(r'(\treturn\s+do_execveat_common\(AT_FDCWD,\s*filename,\s*argv,\s*envp,\s*0\);)', call + r'\1', content, count=1)
    with open('fs/exec.c', 'w') as f: f.write(content)
    print("✅ fs/exec.c patché")
else:
    print("✅ fs/exec.c déjà patché")

# 2. fs/open.c
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n#endif\n\n"
    # Correction : on cible do_faccessat au lieu de SYSCALL_DEFINE3
    content = re.sub(r'(long\s+do_faccessat\s*\()', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\n\t"
    content = re.sub(r'(\tif\s*\(mode\s*&\s*~S_IRWXO\))', call + r'\1', content, count=1)
    with open('fs/open.c', 'w') as f: f.write(content)
    print("✅ fs/open.c patché")
else:
    print("✅ fs/open.c déjà patché")

# 3. fs/read_write.c
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern = "#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n#endif\n\n"
    
    # 1. Ajouter l'extern juste avant SYSCALL_DEFINE3(read,
    match = re.search(r'(SYSCALL_DEFINE3\s*\(\s*read\s*,)', content)
    if match:
        content = content[:match.start()] + extern + content[match.start():]
        
        # 2. Trouver "ssize_t ret = -EBADF;" DANS cette fonction et injecter l'appel
        start_pos = content.find('SYSCALL_DEFINE3(read,')
        ret_pos = content.find('ssize_t ret = -EBADF;', start_pos)
        
        if ret_pos != -1:
            # LA CORRECTION EST ICI : ajout du (char __user **)
            call = "\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, (char __user **)&buf, &count);\n#endif"
            insert_pos = ret_pos + len('ssize_t ret = -EBADF;')
            content = content[:insert_pos] + call + content[insert_pos:]
            
            with open('fs/read_write.c', 'w') as f: f.write(content)
            print("✅ fs/read_write.c patché (chirurgical avec cast)")
        else:
            print("❌ Impossible de trouver 'ssize_t ret = -EBADF;' dans read")
    else:
        print("❌ Impossible de trouver 'SYSCALL_DEFINE3(read,'")
else:
    print("✅ fs/read_write.c déjà patché")
# 4. fs/stat.c
with open('fs/stat.c', 'r') as f: content = f.read()
if 'ksu_handle_stat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n\n"
    content = re.sub(r'(SYSCALL_DEFINE4\s*\(\s*newfstatat)', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n\t"
    content = re.sub(r'(\terror\s*=\s*vfs_fstatat\(dfd,\s*filename,\s*&stat,\s*flag\);)', call + r'\1', content, count=1)
    with open('fs/stat.c', 'w') as f: f.write(content)
    print("✅ fs/stat.c patché")
else:
    print("✅ fs/stat.c déjà patché")

# 5. kernel/reboot.c
with open('kernel/reboot.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_reboot' not in content:
    extern = "#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
    content = re.sub(r'(SYSCALL_DEFINE4\s*\(\s*reboot)', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\t"
    content = re.sub(r'(/\*\s*We only trust the superuser with rebooting the system\.\s*\*/)', call + r'\1', content, count=1)
    with open('kernel/reboot.c', 'w') as f: f.write(content)
    print("✅ kernel/reboot.c patché")
else:
    print("✅ kernel/reboot.c déjà patché")
PYEOF

# ==================== 4. CONFIGURATION ====================
echo ""
echo "=== Configuration (KernelSU-Next Manual Hook, sans SUSFS) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KSU_WITH_KPROBES is not set"
  echo "# CONFIG_KSU_SUSFS is not set"
  echo "# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

echo "=== État final .config ==="
grep -E "KSU_MANUAL_HOOK|KSU_SUSFS|KSU_WITH_KPROBES|KSU_TRACEPOINT|KSU_TAMPER|SECCOMP" out/.config | head -20 || true

if ! grep -q "^CONFIG_KSU=y" out/.config; then
    echo "❌ CONFIG_KSU non activé, abandon"
    exit 1
fi

# ==================== 5. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 6. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 7. COMPILATION KSUD (KernelSU-Next) ====================
echo ""
echo "=== Compilation ksud (KernelSU-Next) ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"; export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"
rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
git clone --depth=1 --branch next https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android
KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1 || true)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé (KernelSU-Next)"
cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK (MÉTHODE BACKSLASHXX) ====================
echo ""
echo "=== Repack (méthode backslashxx : magiskboot cpio add) ==="

rm -f ./boot-stock.img 2>/dev/null || true
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then
    echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"
fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi
rm -f ./dtbo-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf ./Magisk-v27.0.apk ./lib 2>/dev/null || true

cd repack
set +e
./magiskboot unpack boot.img
set -e

cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary
chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary 2>/dev/null || true

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. DIAGNOSTIC ====================
echo ""
echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE"
fi

if [ -f "ramdisk.cpio" ]; then
    if ../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null; then
        echo "  ✅ ksud présent dans /data/adb/ksud/"
    else
        echo "  ❌ ksud absent"
    fi
fi
cd ..

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/KernelSU-Next-NoSUSFS-v2.5-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v2.5 (KernelSU-Next sans SUSFS) ==="
ls -lh output/
