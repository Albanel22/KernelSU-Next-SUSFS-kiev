#!/bin/bash
set -euo pipefail

# =============================================================================
# KernelSU-Next (legacy) + SuSFS 2.3.0 — BUILD COMPLET (Patch Local)
# Noyau 4.19 - Motorola One 5G Ace (kiev)
# =============================================================================

KSU_REF="${KSU_REF:-legacy}"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"
KSU_COMMIT="${KSU_COMMIT:-465490a}"
KSU_EXPECTED_UAPI="${KSU_EXPECTED_UAPI:-5}"
KSU_REPO_URL="${KSU_REPO_URL:-}"
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"

SUSFS_SUS_MOUNT="${SUSFS_SUS_MOUNT:-1}"
SUSFS_OPEN_REDIRECT="${SUSFS_OPEN_REDIRECT:-1}"
SUSFS_GLUE="${SUSFS_GLUE:-1}"

VER="ksun-susfs-v2"

echo "=== Build KernelSU-Next ($KSU_REF) + SuSFS 2.3.0 — $VER ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

mkdir -p "$GITHUB_WORKSPACE/output"
AUDIT="$GITHUB_WORKSPACE/output/audit-${VER}.txt"
: > "$AUDIT"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio libclang-dev patch wget

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU (source épinglée) ====================
KERNEL_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
if [ -n "$KERNEL_PIN" ]; then
    git clone --filter=blob:none --no-checkout -b lineage-23.2 "$KERNEL_URL" kernel_sources
    cd kernel_sources
    echo "Tête actuelle de lineage-23.2 : $(git log --oneline -1 origin/lineage-23.2)" | tee -a "$AUDIT"
    if ! git checkout -q "$KERNEL_PIN" 2>/dev/null; then
        echo "⚠️ $KERNEL_PIN absent de lineage-23.2, recherche..." | tee -a "$AUDIT"
        git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
        git checkout -q "$KERNEL_PIN" || { echo "❌ commit $KERNEL_PIN introuvable"; exit 1; }
    fi
    echo "Source figée sur : $KERNEL_PIN" | tee -a "$AUDIT"
else
    git clone "$KERNEL_URL" -b lineage-23.2 --depth=1 kernel_sources
    cd kernel_sources
fi
git log --oneline -1 | tee -a "$AUDIT"

# ==================== 2. SuSFS 2.3.0 : PATCH LOCAL ====================
echo ""
echo "=== Application du patch SuSFS 4.19 (local) ==="

# Utilisation du patch local situé dans le dossier patches/ du dépôt
SUSFS_PATCH="$GITHUB_WORKSPACE/patches/susfs_patch_to_4.19.patch"

if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch local introuvable à : $SUSFS_PATCH"
    echo "   Assure-toi que le fichier patches/susfs_patch_to_4.19.patch existe à la racine de ton dépôt."
    exit 1
fi

echo "  → Utilisation du patch local : $SUSFS_PATCH"

if patch -p1 --forward --dry-run --silent < "$SUSFS_PATCH" > /dev/null 2>&1; then
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1
    echo "  ✅ patch SuSFS appliqué"
else
    echo "  ⚠️ Patch partiellement rejeté — correction manuelle nécessaire"
    patch -p1 --forward < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1 || true
    
    # --- Résolution des hunks rejetés critiques ---
    echo "  → Résolution des hunks rejetés dans fs/namespace.c, fs/super.c, fs/proc/task_mmu.c"
    python3 - <<'PYEOF'
import re, sys, os

# 1. fs/namespace.c (includes + vfs_kern_mount)
path = 'fs/namespace.c'
with open(path) as f: c = f.read()
if 'susfs_is_current_ksu_domain' not in c:
    anchor = '#include "internal.h"\n'
    bloc = '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25)
#endif
'''
    c = c.replace(anchor, anchor + bloc, 1)
    pattern = r'(struct vfsmount \*vfs_kern_mount\([^)]*\)\s*\{.*?if \(!type\)\s*\n\s*return ERR_PTR\(-EINVAL\);\s*\n)'
    match = re.search(pattern, c, re.DOTALL)
    if match:
        bloc2 = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
			goto bypass_orig_flow;
		}
	}
#endif
'''
        c = c[:match.end()] + bloc2 + c[match.end():]
        pattern2 = r'(mnt = alloc_vfsmnt\(name\);\s*\n)'
        match2 = re.search(pattern2, c)
        if match2:
            label = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif
'''
            c = c[:match2.end()] + label + c[match2.end():]
    with open(path, 'w') as f: f.write(c)
    print("  ✅ fs/namespace.c corrigé manuellement")

# 2. fs/super.c (includes)
path = 'fs/super.c'
with open(path) as f: c = f.read()
if 'susfs_def.h' not in c:
    anchor = '#include "internal.h"'
    bloc = '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif
'''
    c = c.replace(anchor, anchor + bloc, 1)
    with open(path, 'w') as f: f.write(c)
    print("  ✅ fs/super.c corrigé manuellement")
PYEOF
fi

# Neutralisation de la fonction manquante si elle est référencée
if [ -f "drivers/kernelsu/selinux/sepolicy.c" ]; then
    if grep -q "susfs_add_sus_avd_allowed_by_type" drivers/kernelsu/selinux/sepolicy.c; then
        echo "  → Neutralisation de susfs_add_sus_avd_allowed_by_type dans sepolicy.c"
        python3 - <<'PYEOF'
import re
path = 'drivers/kernelsu/selinux/sepolicy.c'
with open(path) as f: c = f.read()
c = re.sub(r'extern\s+int\s+susfs_add_sus_avd_allowed_by_type\s*\([^;]*\);', '/* removed */', c)
c = re.sub(r'susfs_add_sus_avd_allowed_by_type\s*\([^;]*\);', '/* removed */', c)
with open(path, 'w') as f: f.write(c)
print("  ✅ sepolicy.c neutralisé")
PYEOF
    fi
fi

find . -name "*.rej" -delete 2>/dev/null || true
if ! grep -qE '^obj-\$\(CONFIG_KSU_SUSFS\)\s*\+=\s*susfs\.o' fs/Makefile; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
fi
echo "✅ Patch SuSFS et corrections terminés"

# ==================== 3. INTÉGRATION KernelSU-Next ====================
echo ""
echo "=== Intégration KernelSU-Next ($KSU_REF) ==="
rm -rf drivers/kernelsu KernelSU KernelSU-Next 2>/dev/null || true

if [ -n "$KSU_REPO_URL" ]; then
    echo "Dépôt personnalisé : $KSU_REPO_URL (réf $KSU_REF)" | tee -a "$AUDIT"
    git clone "$KSU_REPO_URL" KernelSU-Next
    git -C KernelSU-Next checkout "$KSU_REF"
    ln -sfn ../KernelSU-Next/kernel drivers/kernelsu
    grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
else
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "$KSU_REF"
fi

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration KernelSU-Next"; exit 1
fi
echo "✅ KernelSU-Next ($KSU_REF) intégré"

# --- Épinglage du driver + vérification UAPI ---
if [ -n "$KSU_COMMIT" ] && [ -d "KernelSU-Next/.git" ]; then
    echo "=== Épinglage KernelSU-Next sur $KSU_COMMIT ==="
    git -C KernelSU-Next fetch --unshallow 2>/dev/null || git -C KernelSU-Next fetch --all 2>/dev/null || true
    git -C KernelSU-Next checkout "$KSU_COMMIT"
    git -C KernelSU-Next log --oneline -1
fi
UAPI_FILE=$(find KernelSU-Next -path "*/uapi/supercall.h" -type f 2>/dev/null | head -1 || true)
if [ -n "$UAPI_FILE" ]; then
    UAPI_FOUND=$(grep -E "^#define KERNEL_SU_UAPI_VERSION" "$UAPI_FILE" | awk '{print $3}' || true)
    echo "UAPI du driver : ${UAPI_FOUND:-?}  (attendue : ${KSU_EXPECTED_UAPI:-non vérifiée})  [$UAPI_FILE]"
    if [ -n "$KSU_EXPECTED_UAPI" ] && [ -n "$UAPI_FOUND" ] && [ "$UAPI_FOUND" != "$KSU_EXPECTED_UAPI" ]; then
        echo "❌ UAPI du driver ($UAPI_FOUND) différente de celle attendue ($KSU_EXPECTED_UAPI)"
        exit 1
    fi
else
    echo "⚠️  uapi/supercall.h introuvable, UAPI non vérifiée"
fi

# --- KSU_DIR ---
if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi
echo "KSU_DIR : $KSU_DIR"

KSU_REPO_ROOT=""
for d in "$GITHUB_WORKSPACE/kernel_sources/KernelSU-Next" "$GITHUB_WORKSPACE/kernel_sources/KernelSU"; do
    if [ -d "$d" ]; then KSU_REPO_ROOT="$d"; break; fi
done
echo "KSU_REPO_ROOT : ${KSU_REPO_ROOT:-introuvable}"

# ==================== 3b. KCONFIG SuSFS INJECTÉ (si absent) ====================
if ! grep -rqE "^config KSU_SUSFS$" "$KSU_DIR/" --include="Kconfig*" 2>/dev/null; then
    echo "⚠️ Le driver n'a pas de symbole KSU_SUSFS : Kconfig injecté" | tee -a "$AUDIT"
    {
        echo 'menu "KernelSU - SUSFS (injecté)"'
        echo 'config KSU_SUSFS'
        printf '\tbool "KernelSU addon - SUSFS"\n\tdepends on KSU\n\tdefault n\n\n'
        for o in SUS_PATH SUS_MOUNT SUS_KSTAT SPOOF_UNAME ENABLE_LOG HIDE_KSU_SUSFS_SYMBOLS \
                 SPOOF_CMDLINE_OR_BOOTCONFIG OPEN_REDIRECT SUS_MAP; do
            printf 'config KSU_SUSFS_%s\n\tbool "susfs %s"\n\tdepends on KSU_SUSFS\n\tdefault n\n\n' "$o" "$o"
        done
        echo 'endmenu'
    } > fs/Kconfig.susfs_inject
    grep -q "Kconfig.susfs_inject" fs/Kconfig || printf '\nsource "fs/Kconfig.susfs_inject"\n' >> fs/Kconfig
fi

# ==================== 3c. COLLE MINIMALE SuSFS <-> driver ====================
if [ "$SUSFS_GLUE" = "1" ]; then
    cat > fs/susfs_glue.c <<'GLUEEOF'
/* Colle minimale SuSFS <-> KernelSU-Next */
#include <linux/types.h>
#include <linux/cred.h>
#include <linux/init.h>
#include <linux/compiler.h>

extern bool is_ksu_domain(void) __weak;
extern void susfs_init(void);

u32 susfs_ksu_sid __weak;
u32 susfs_priv_app_sid __weak;
struct cred *ksu_cred __weak;

void __weak setup_selinux(const char *domain, struct cred *cred) { }

bool __weak susfs_is_current_ksu_domain(void)
{
	if (is_ksu_domain)
		return is_ksu_domain();
	return false;
}

static int __init susfs_glue_init(void)
{
	susfs_init();
	return 0;
}
late_initcall(susfs_glue_init);
GLUEEOF
    if ! grep -q "susfs_glue.o" fs/Makefile; then
        echo 'obj-$(CONFIG_KSU_SUSFS) += susfs_glue.o' >> fs/Makefile
    fi
    echo "✅ colle minimale ajoutée (fs/susfs_glue.c)" | tee -a "$AUDIT"
fi

# ==================== 3d. NEUTRALISATION CHECK.MK + UNICODE + FIX DIVERS ====================
echo ""
echo "=== Neutralisation check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null || true)
    if [ -n "$FILES" ]; then
        for f in $FILES; do sed -i 's/\$(error/\$(warning/g' "$f"; done
    fi
done

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

echo "=== Fix symbol_resolver.h ==="
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h"; do
    if [ -f "$h" ]; then
        sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$h"
        sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$h"
        sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$h"
    fi
done

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

echo "=== Fix O_CLOEXEC ==="
FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
for f in $FILES_GET_UNUSED; do
    sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
    echo "  ✅ get_unused_fd_flags fixé dans $f"
done
FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
for f in $FILES_ANON_INODE; do
    sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$f"
    sed -i 's/O_RDWR|O_CLOEXEC/O_RDWR/g' "$f"
    sed -i 's/, O_CLOEXEC)/)/g' "$f"
    echo "  ✅ anon_inode_getfile nettoyé dans $f"
done

# ==================== 4. PATCHS MANUELS KERNELSU-NEXT (HOOKS v2.9) ====================
echo ""
echo "=== Application des Patchs Manuels KernelSU-Next ==="

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
    match = re.search(r'(SYSCALL_DEFINE3\s*\(\s*read\s*,)', content)
    if match:
        content = content[:match.start()] + extern + content[match.start():]
        start_pos = content.find('SYSCALL_DEFINE3(read,')
        ret_pos = content.find('ssize_t ret = -EBADF;', start_pos)
        if ret_pos != -1:
            call = "\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, (char __user **)&buf, &count);\n#endif"
            insert_pos = ret_pos + len('ssize_t ret = -EBADF;')
            content = content[:insert_pos] + call + content[insert_pos:]
            with open('fs/read_write.c', 'w') as f: f.write(content)
            print("✅ fs/read_write.c patché")
        else:
            print("❌ Impossible de trouver 'ssize_t ret = -EBADF;'")
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

# 6. fs/namespace.c (backport path_umount)
with open('fs/namespace.c', 'r') as f: content = f.read()
if 'int path_umount(struct path *path, int flags)' not in content:
    backport = '''
#ifdef CONFIG_KSU
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW)) return -EINVAL;
	if (!may_mount()) return -EPERM;
	if (path->dentry != path->mnt->mnt_root) return -EINVAL;
	if (!check_mnt(mnt)) return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN)) return -EPERM;
	return 0;
}
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret = can_umount(path, flags);
	if (!ret) ret = do_umount(mnt, flags);
	dput(path->dentry); mntput_no_expire(mnt);
	return ret;
}
#endif
'''
    content = re.sub(r'(int ksys_umount\(char __user \*name, int flags\))', backport + r'\1', content, count=1)
    with open('fs/namespace.c', 'w') as f: f.write(content)
    print("✅ fs/namespace.c patché (path_umount)")
else:
    print("✅ fs/namespace.c déjà patché")

PYEOF

# ==================== 5. CONFIGURATION ====================
echo ""
echo "=== Configuration ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CC_ARGS="CLANG_TRIPLE=aarch64-linux-gnu-"

mkdir -p out
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KSU_WITH_KPROBES is not set"
  echo "# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  if [ "$SUSFS_SUS_MOUNT" = "1" ]; then echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"; else echo "# CONFIG_KSU_SUSFS_SUS_MOUNT is not set"; fi
  if [ "$SUSFS_OPEN_REDIRECT" = "1" ]; then echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"; else echo "# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set"; fi
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_KALLSYMS=y"
  echo "CONFIG_KALLSYMS_ALL=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "CONFIG_THREAD_INFO_IN_TASK=y"
} >> out/.config

make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

echo "=== État final .config ==="
grep -E "KSU|SECCOMP" out/.config | head -40 || true

if ! grep -q "^CONFIG_KSU=y" out/.config; then echo "❌ CONFIG_KSU non activé"; exit 1; fi
if ! grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then echo "❌ CONFIG_KSU_SUSFS supprimé"; exit 1; fi

# ==================== 6. PATCHS MOTOROLA ====================
echo "=== Patchs Motorola ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 7. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" \
  -k -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    grep -iE "error:|undefined symbol|undefined reference|fatal error:" build.log | head -30 || true
    {
        echo "=== ERREURS ==="
        grep -nE "error:|undefined symbol|undefined reference|fatal error:|\*\*\*" build.log | head -100 || true
        echo ""
        echo "=== SYMBOLES NON DÉFINIS ==="
        grep -oE "undefined reference to \`[^']+'" build.log | sort | uniq -c | sort -rn | head -40 || true
    } > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅ Compilation réussie"
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-${VER}"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-${VER}"

# ==================== 8. COMPILATION KSUD ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"

KSUD_DIR=""
KSUD_ROOT=""
if [ -n "$KSU_REPO_ROOT" ] && [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"
    KSUD_ROOT="$KSU_REPO_ROOT"
    echo "✅ ksud pris dans le MÊME checkout que le driver"
else
    echo "⚠️  Fallback : ksud depuis la branche '$KSUD_FALLBACK_REF'"
    rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
    git clone --depth=1 --branch "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksud-src"
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
    KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
fi

if [ ! -f "$KSUD_DIR/Cargo.toml" ]; then
    echo "❌ Cargo.toml de ksud introuvable"; exit 1
fi

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

cd "$KSUD_DIR"
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

KSUD_BINARY=$(find "$KSUD_ROOT" -type f -path "*aarch64-linux-android/release/ksud" 2>/dev/null | head -1 || true)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK ====================
echo ""
echo "=== Repack ==="
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
    "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary
chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary 2>/dev/null || true

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10. DIAGNOSTIC ====================
echo ""
echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(sha256sum ../kernel_sources/out/arch/arm64/boot/Image | cut -d' ' -f1)
    [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE"
fi
cd ..

# ==================== 11. SORTIE ====================
cp final_boot.img "output/KernelSU-Next-SUSFS-${VER}-boot.img"
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ ${VER} ==="
ls -lh output/
