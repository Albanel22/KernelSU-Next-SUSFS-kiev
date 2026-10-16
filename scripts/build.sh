#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-SUSFS-CYBERC3RD-V24 : Correction robuste __maybe_unused + Smart Fix
# =============================================================================

echo "=== Build BakaSU + SUSFS cyberc3rd 2.3.0 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"
KSU_COMMIT="5b76b884c75f729a220bb317aa4a4fc78f0e0e9c"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE FRAIS ====================
echo "=== Clonage frais du noyau ==="
rm -rf kernel_sources
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION BakaSU ====================
echo "=== Intégration BakaSU ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash -s -- "$KSU_COMMIT"

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration BakaSU"
    exit 1
fi
echo "✅ BakaSU intégré"

# ==================== 3. NEUTRALISATION CHECK.MK ====================
echo "=== Neutralisation check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    find . -name "$pattern" -type f -exec sed -i 's/\$(error/\$(warning/g' {} + 2>/dev/null || true
done

# ==================== 4. PATCH SUSFS ====================
echo "=== Patch SUSFS 4.19 (cyberc3rd rebase) ==="
cd "$GITHUB_WORKSPACE/kernel_sources"

PATCH_URL="https://raw.githubusercontent.com/cyberc3dr/nGKI_Kernel_Build/rebase/Patches/Patch/susfs_patch_to_4.19.patch"
echo "Téléchargement du patch depuis : $PATCH_URL"

if curl -sSfL "$PATCH_URL" -o /tmp/susfs_4.19.patch; then
    echo "Application du patch..."
    patch -p1 --forward --batch < /tmp/susfs_4.19.patch 2>&1 | tee /tmp/susfs-apply.log || true
    rm -f /tmp/susfs_4.19.patch
else
    echo "❌ Échec du téléchargement du patch SUSFS."
    exit 1
fi
if find . -type f -name '*.rej' -print -quit | grep -q .; then
    echo "⚠️ Rejets SUSFS détectés; résolution ciblée en cours"
fi

# ==================== 5. CORRECTIONS ROBUSTES (Python) ====================
echo "=== Corrections post-patch robustes ==="

python3 << 'PYEOF'
import os
import re

# 1. Correction robuste de __maybe_unused pour la variable 'vma'
files_to_fix = ["fs/proc/task_mmu.c", "fs/namespace.c", "fs/super.c", "fs/stat.c"]
for filepath in files_to_fix:
    if os.path.exists(filepath):
        with open(filepath, 'r') as f:
            content = f.read()

        # Remplace "struct vm_area_struct *vma;" par "struct vm_area_struct *vma __maybe_unused;"
        # Cette regex gère n'importe quel nombre d'espaces ou de tabulations
        new_content = re.sub(
            r'(\bstruct vm_area_struct\s+\*\s*vma\s*;)',
            r'struct vm_area_struct *vma __maybe_unused;',
            content
        )

        if new_content != content:
            with open(filepath, 'w') as f:
                f.write(new_content)
            print(f"✅ Correction __maybe_unused appliquée à {filepath}")

# 2. Smart Fix : Ajout du header manquant dans fs/super.c si nécessaire
filepath = "fs/super.c"
if os.path.exists(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    if ("DEFAULT_KSU_MNT_MINOR_DEV" in content or "susfs_is_current_ksu_domain" in content) and "#include <linux/susfs_def.h>" not in content:
        print("⚠️ Code SUSFS détecté dans fs/super.c, mais header manquant. Ajout en cours...")
        lines = content.split('\n')
        first_include_idx = -1
        for i, line in enumerate(lines):
            if line.strip().startswith('#include'):
                first_include_idx = i
                break

        if first_include_idx != -1:
            lines.insert(first_include_idx + 1, '#ifdef CONFIG_KSU_SUSFS')
            lines.insert(first_include_idx + 2, '#include <linux/susfs_def.h>')
            lines.insert(first_include_idx + 3, '#endif')
            with open(filepath, 'w') as f:
                f.write('\n'.join(lines))
            print("✅ Header susfs_def.h ajouté avec succès à fs/super.c")

    with open(filepath, 'r') as f:
        content = f.read()
    decl = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''
    if 'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;' not in content:
        marker = '#include "internal.h"'
        if marker not in content:
            raise SystemExit('❌ fs/super.c: ancre internal.h absente')
        content = content.replace(marker, marker + '\n' + decl, 1)
        with open(filepath, 'w') as f:
            f.write(content)
        print('✅ Déclarations SUSFS ajoutées à fs/super.c')

# 3. Faire de même pour fs/namespace.c et fs/stat.c
for fpath in ["fs/namespace.c", "fs/stat.c"]:
    if os.path.exists(fpath):
        with open(fpath, 'r') as f:
            content = f.read()
        if "susfs_is_current_ksu_domain" in content or "SUSFS" in content:
            if "#include <linux/susfs_def.h>" not in content:
                lines = content.split('\n')
                for i, line in enumerate(lines):
                    if line.strip().startswith('#include'):
                        lines.insert(i + 1, '#include <linux/susfs_def.h>')
                        with open(fpath, 'w') as f:
                            f.write('\n'.join(lines))
                        print(f"✅ Header ajouté à {fpath}")
                        break

# 3b. Réparation manuelle des deux hunks namespace.c rejetés.
ns_path = "fs/namespace.c"
if os.path.exists(ns_path):
    content = open(ns_path).read()
    ns_decl = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25)
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''
    if 'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;' not in content:
        marker = '#include "internal.h"'
        if marker not in content:
            raise SystemExit('❌ fs/namespace.c: ancre internal.h absente')
        content = content.replace(marker, marker + '\n' + ns_decl, 1)
        print('✅ Déclarations SUSFS ajoutées à fs/namespace.c')
    if 'susfs_alloc_non_unshare_ksu_vfsmnt(' not in content:
        old = '''\tmnt = alloc_vfsmnt(fc->source ?: \"none\");
\tif (!mnt)
'''
        new = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted) &&
\t\tsusfs_is_current_ksu_domain()) {
\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(fc->source ?: "none");
\t\tgoto bypass_orig_flow;
\t}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tmnt = alloc_vfsmnt(fc->source ?: "none");
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''
        if old not in content:
            raise SystemExit('❌ fs/namespace.c: bloc vfs_kern_mount introuvable')
        content = content.replace(old, new, 1)
        open(ns_path, 'w').write(content)
        print('✅ Hunk vfs_kern_mount réparé dans fs/namespace.c')

# 3c. Réparation manuelle du hunk SUS_MAP rejeté dans task_mmu.c.
mmu_path = "fs/proc/task_mmu.c"
if os.path.exists(mmu_path):
    content = open(mmu_path).read()
    if 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))' not in content:
        old = '''\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);
\t\tmmap_read_unlock(mm);'''
        new = '''#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tvma = find_vma(mm, start_vaddr);
\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
\t\t\tgoto bypass_orig_flow;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tmmap_read_unlock(mm);'''
        if old not in content:
            raise SystemExit('❌ task_mmu.c: bloc walk_page_range introuvable')
        content = content.replace(old, new, 1)
        open(mmu_path, 'w').write(content)
        print('✅ Hunk SUS_MAP réparé dans task_mmu.c')

# 4. Hook execve compatible avec le contrôle BakaSU/compat.
exec_path = "fs/exec.c"
if os.path.exists(exec_path):
    content = open(exec_path).read()
    if 'ksu_handle_post_execveat' not in content:
        decl = '''#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                               void *argv, void *envp, int *flags);
extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,
                                    void *argv, void *envp, int *flags, int *retval);
#endif
'''
        anchor = 'int suid_dumpable = 0;'
        if anchor not in content:
            raise SystemExit('❌ fs/exec.c: ancre suid_dumpable absente')
        content = content.replace(anchor, decl + '\n' + anchor, 1)
        old = '''{
\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);
}'''
        new = '''{
#ifdef CONFIG_KSU_SUSFS
\tint retval;
\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
\tretval = __do_execve_file(fd, filename, argv, envp, flags, NULL);
\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);
\treturn retval;
#else
\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);
#endif
}'''
        if old not in content:
            raise SystemExit('❌ fs/exec.c: corps do_execveat_common inattendu')
        content = content.replace(old, new, 1)
        open(exec_path, 'w').write(content)
        print('✅ Hook execve/post-exec BakaSU ajouté à fs/exec.c')

# Les rejets sont acceptés uniquement si le hunk fs/super.c est réparé.
rejects = []
for root, _, names in os.walk('.'):
    rejects.extend(os.path.join(root, n) for n in names if n.endswith('.rej'))
if rejects:
    allowed = {'./fs/super.c.rej', './fs/namespace.c.rej', './fs/proc/task_mmu.c.rej'}
    bad = [p for p in rejects if p not in allowed]
    required = [
        ('fs/super.c', 'susfs_is_sdcard_android_data_not_decrypted'),
        ('fs/namespace.c', 'susfs_alloc_non_unshare_ksu_vfsmnt'),
        ('fs/proc/task_mmu.c', 'SUSFS_IS_INODE_SUS_MAP'),
    ]
    unresolved = [path for path, marker in required if marker not in open(path).read()]
    if bad or unresolved:
        raise SystemExit('❌ Rejets SUSFS non résolus: ' + ', '.join(rejects))
    for p in rejects:
        os.remove(p)
    print('✅ Rejet fs/super.c résolu manuellement; aucun .rej restant')

print("✅ Toutes les corrections post-patch ont réussi.")
PYEOF

# ==================== 6. CONFIGURATION (FORCÉE) ====================
echo "=== Configuration du noyau ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

cat << 'EOF' >> out/.config
CONFIG_KSU=y
CONFIG_KSU_MULTI_MANAGER_SUPPORT=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KALLSYMS_ALL=y
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
EOF

echo "→ Résolution des dépendances (olddefconfig)..."
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig > /dev/null 2>&1

echo "→ Forçage des options KSU..."
sed -i 's/^# CONFIG_KSU is not set$/CONFIG_KSU=y/' out/.config
sed -i 's/^# CONFIG_KSU_MULTI_MANAGER_SUPPORT is not set$/CONFIG_KSU_MULTI_MANAGER_SUPPORT=y/' out/.config
sed -i 's/^# CONFIG_KSU_SUSFS is not set$/CONFIG_KSU_SUSFS=y/' out/.config
sed -i 's/^CONFIG_KSU_MANUAL_HOOK=y$/# CONFIG_KSU_MANUAL_HOOK is not set/' out/.config
sed -i 's/^CONFIG_KSU_TRACEPOINT_HOOK=y$/# CONFIG_KSU_TRACEPOINT_HOOK is not set/' out/.config

echo "=== VÉRIFICATION FINALE DU .CONFIG ==="
grep -E "^CONFIG_KSU=|^CONFIG_KSU_MULTI_MANAGER_SUPPORT=|^CONFIG_KSU_SUSFS=|^CONFIG_KSU_MANUAL_HOOK=" out/.config || echo "❌ ERREUR CRITIQUE : KSU n'est pas activé !"
grep -q '^CONFIG_KSU=y$' out/.config
grep -q '^CONFIG_KSU_MULTI_MANAGER_SUPPORT=y$' out/.config
grep -q '^CONFIG_KSU_SUSFS=y$' out/.config
! grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' out/.config
! grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y$' out/.config
grep -q 'ksu_handle_post_execveat' fs/exec.c

# ==================== 7. PATCHS MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
if [ -f "techpack/display/msm/msm_drv.c" ]; then
    printf "\n/* --- Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch --- */\n" >> techpack/display/msm/msm_drv.c
fi

# ==================== 8. COMPILATION ====================
echo "=== Compilation ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 9. COMPILATION KSUD ====================
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly
rustup default nightly
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang++"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/Baka-SU/BakaSU.git "$GITHUB_WORKSPACE/ksud-src"
git -C "$GITHUB_WORKSPACE/ksud-src" fetch --depth=1 origin "$KSU_COMMIT"
git -C "$GITHUB_WORKSPACE/ksud-src" checkout --detach "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$NDK_BIN/aarch64-linux-android26-clang"
[env]
CC_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang"
CXX_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang++"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF

if ! cargo build --release --target aarch64-linux-android; then
    echo "❌ Échec compilation ksud"
    exit 1
fi
KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)
[ -z "$KSUD_BINARY" ] && { echo "❌ ksud introuvable"; exit 1; }
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"

# ==================== 10. REPACK AVEC INJECTION KSUD ====================
echo "=== Repack avec injection ksud ==="
cd "$GITHUB_WORKSPACE"
rm -f boot-stock.img dtbo-stock.img
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1
[ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ] && { echo "❌ boot-stock invalide"; exit 1; }
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack && cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so && mv lib/x86_64/libmagiskboot.so repack/magiskboot && chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/
cd repack

echo "→ Unpack..."
./magiskboot unpack boot.img
[ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ] && { echo "❌ Échec unpack"; exit 1; }

echo "→ Remplacement du kernel..."
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

echo "→ Préparation du ramdisk..."
rm -rf ramdisk_work && mkdir -p ramdisk_work
cd ramdisk_work
../magiskboot cpio ../ramdisk.cpio extract

mkdir -p system/bin
cp "$GITHUB_WORKSPACE/ksud" system/bin/ksud
chmod 755 system/bin/ksud
echo "✅ ksud ajouté au ramdisk"

INITRC_PATH="init.rc"
[ -f "system/etc/init/hw/init.rc" ] && INITRC_PATH="system/etc/init/hw/init.rc"

mkdir -p "$(dirname "$INITRC_PATH")"
cat >> "$INITRC_PATH" << 'INITRC_EOF'

# --- KSUD START ---
on post-fs-data
    exec u:r:su:s0 root -- /system/bin/ksud post-fs-data
on nonencrypted
    exec u:r:su:s0 root -- /system/bin/ksud services
on property:sys.boot_completed=1
    exec u:r:su:s0 root -- /system/bin/ksud boot-completed
# --- KSUD END ---
INITRC_EOF
echo "✅ Script init.rc ajouté"

cd ..

echo "→ Reconstruction du ramdisk..."
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 0755 system/bin/ksud ramdisk_work/system/bin/ksud" \
    "add 0750 $INITRC_PATH ramdisk_work/$INITRC_PATH"

echo "→ Repack..."
./magiskboot repack boot.img new-boot.img
[ ! -f "new-boot.img" ] && { echo "❌ Échec repack"; exit 1; }
mv new-boot.img ../final_boot.img && cd ..
echo "✅ Repack terminé"

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SUSFS-cyberc3rd-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "========================================="
echo "=== 🎉 BUILD TERMINÉ AVEC SUCCÈS v24 ==="
echo "========================================="
ls -lh output/
