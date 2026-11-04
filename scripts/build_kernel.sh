#!/bin/bash
set -euo pipefail

# =============================================================================
# KernelSU-Next (legacy) + SuSFS 2.3.0 — PREMIER LANCEMENT (sonde + build au mieux)
# Noyau 4.19 - Motorola One 5G Ace (kiev)
#
# Base : script v2.9 (KernelSU-Next legacy, hooks manuels) qui fonctionne SANS SuSFS
#      + méthode du build SukiSU/SuSFS validé : sources épinglées, patch SuSFS local
#        contrôlé (patches/), rattrapage des blocs rejetés, make -k, audits dans output/.
#
# Ce que ce run fait : applique la partie NOYAU de SuSFS 2.3.0 (patch de Jack), ajoute une
# colle minimale côté driver, et liste tout ce qui manque. Le driver KernelSU-Next legacy
# épinglé ne contient PAS la colle SuSFS 2.3.0 de SukiSU : des erreurs sont attendues.
# Le script de hooks "inline" de Jack n'est PAS utilisé (hooks manuels v2.9 conservés).
# =============================================================================

# ---- Driver KernelSU-Next (comme v2.9) ----
KSU_REF="${KSU_REF:-legacy}"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"
KSU_COMMIT="${KSU_COMMIT:-465490a}"           # vide = ne pas épingler
KSU_EXPECTED_UAPI="${KSU_EXPECTED_UAPI:-5}"   # vide = ne pas vérifier l'UAPI
# Dépôt alternatif pour le DRIVER (fork avec colle SuSFS). Vide = dépôt officiel + setup.sh.
# Exemple : KSU_REPO_URL=https://github.com/sidex15/KernelSU-Next.git KSU_REF=<branche> KSU_COMMIT= KSU_EXPECTED_UAPI=
KSU_REPO_URL="${KSU_REPO_URL:-}"

# ---- Source du noyau (même commit que les builds validés) ----
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"

# ---- SuSFS ----
SUSFS_SUS_MOUNT="${SUSFS_SUS_MOUNT:-1}"
SUSFS_OPEN_REDIRECT="${SUSFS_OPEN_REDIRECT:-1}"
SUSFS_PRIORITY_UID_FILTER="${SUSFS_PRIORITY_UID_FILTER:-1}"
SUSFS_GLUE="${SUSFS_GLUE:-1}"                 # colle minimale côté driver (fs/susfs_glue.c)

VER="ksun-susfs-probe1"

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

# ==================== 0. SONDE : où trouver une colle SuSFS côté driver ? ====================
{
    echo ""
    echo "=== SONDE : branches et tags des dépôts KernelSU-Next connus ==="
    for url in "https://github.com/KernelSU-Next/KernelSU-Next.git" \
               "https://github.com/sidex15/KernelSU-Next.git" \
               "https://github.com/pershoot/KernelSU-Next.git"; do
        echo "--- $url"
        git ls-remote --heads --tags "$url" 2>&1 | awk '{print $2}' \
            | sed 's#refs/heads/#branche : #; s#refs/tags/#tag : #; s#\^{}##' \
            | grep -iE "susfs|legacy|n3x7g3n|4\.|dev" | sort -u | head -60 || true
    done
    true
} 2>&1 | tee -a "$AUDIT"

# ==================== 1. CLONAGE DU NOYAU (source épinglée) ====================
KERNEL_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
if [ -n "$KERNEL_PIN" ]; then
    git clone --filter=blob:none --no-checkout -b lineage-23.2 "$KERNEL_URL" kernel_sources
    cd kernel_sources
    echo "Tête actuelle de lineage-23.2 : $(git log --oneline -1 origin/lineage-23.2)" | tee -a "$AUDIT"
    if ! git checkout -q "$KERNEL_PIN" 2>/dev/null; then
        echo "⚠️ $KERNEL_PIN absent de lineage-23.2, recherche dans les autres branches..." | tee -a "$AUDIT"
        git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
        git checkout -q "$KERNEL_PIN" || { echo "❌ commit $KERNEL_PIN introuvable dans le dépôt"; exit 1; }
    fi
    echo "Source figée sur : $KERNEL_PIN" | tee -a "$AUDIT"
else
    git clone "$KERNEL_URL" -b lineage-23.2 --depth=1 kernel_sources
    cd kernel_sources
fi
git log --oneline -1 | tee -a "$AUDIT"
echo "SHA complet de la source : $(git rev-parse HEAD)" | tee -a "$AUDIT"

# ==================== 2. SuSFS 2.3.0 : PARTIE NOYAU (patch de Jack, copie épinglée) ====================
# Appliqué AVANT KernelSU-Next, sur un arbre vierge, comme dans le build SukiSU validé.
@@SEG_PATCH@@

# Corrections de compatibilité 4.19 (partie noyau uniquement)
@@SEG_COMPAT@@

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

# --- Épinglage du driver sur un commit précis + vérification de l'UAPI ---
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
        echo "❌ UAPI du driver ($UAPI_FOUND) différente de celle attendue ($KSU_EXPECTED_UAPI) : abandon avant compilation"
        exit 1
    fi
else
    echo "⚠️  uapi/supercall.h introuvable, UAPI non vérifiée"
fi

# --- Traçabilité : ce qui a RÉELLEMENT été compilé ---
echo ""
echo "=== Version KernelSU-Next intégrée ==="
for d in KernelSU-Next KernelSU; do
    if [ -d "$d/.git" ]; then
        echo "Dépôt : $d"
        echo -n "  describe : "; git -C "$d" describe --tags --always 2>/dev/null || echo "?"
        echo -n "  commit   : "; git -C "$d" rev-parse HEAD 2>/dev/null || echo "?"
        echo -n "  branche  : "; git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?"
    fi
done 2>&1 | tee -a "$AUDIT"

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi
echo "KSU_DIR : $KSU_DIR"

# Dossier racine du dépôt KernelSU-Next cloné (pour ksud plus tard)
KSU_REPO_ROOT=""
for d in "$GITHUB_WORKSPACE/kernel_sources/KernelSU-Next" "$GITHUB_WORKSPACE/kernel_sources/KernelSU"; do
    if [ -d "$d" ]; then KSU_REPO_ROOT="$d"; break; fi
done
echo "KSU_REPO_ROOT : ${KSU_REPO_ROOT:-introuvable}"

# ==================== 3a. AUDIT DU DRIVER : que contient-il côté SuSFS ? ====================
{
    echo ""
    echo "=== DRIVER : fichiers principaux ==="
    find "$KSU_DIR/" -maxdepth 2 -type f \( -name "*.c" -o -name "*.h" -o -name "Kconfig*" -o -name "Makefile" -o -name "*.mk" \) 2>/dev/null | sort | head -80 || true
    echo ""
    echo "=== DRIVER : symboles Kconfig ==="
    grep -rn "^config \|^menu \|^menuconfig " "$KSU_DIR/" --include="Kconfig*" 2>/dev/null | head -60 || true
    echo ""
    echo "=== DRIVER : références à SuSFS ==="
    grep -rn -i "susfs" "$KSU_DIR/" --include="*.c" --include="*.h" --include="Kconfig*" --include="Makefile" --include="*.mk" 2>/dev/null | head -80 || true
    echo ""
    echo "=== DRIVER : fonctions clés (domaine ksu, SELinux, reboot, setuid) ==="
    grep -rn "is_ksu_domain\|setup_selinux\|ksu_cred\|ksu_handle_sys_reboot\|KSU_INSTALL_MAGIC\|apply_kernelsu_rules\|ksu_handle_setuid\|ksu_handle_setresuid" "$KSU_DIR/" 2>/dev/null | head -60 || true
    echo ""
    echo "=== DRIVER : ksu_handle_sys_reboot (extrait) ==="
    f=$(grep -rln "int ksu_handle_sys_reboot" "$KSU_DIR/" 2>/dev/null | head -1 || true)
    if [ -n "$f" ]; then
        n=$(grep -n "int ksu_handle_sys_reboot" "$f" | head -1 | cut -d: -f1)
        echo "$f (ligne $n)"
        sed -n "${n},$((n+70))p" "$f" || true
    else
        echo "introuvable"
    fi
    true
} 2>&1 | tee -a "$AUDIT"

# ==================== 3b. KCONFIG SuSFS INJECTÉ SI LE DRIVER N'EN A PAS ====================
if ! grep -rqE "^config KSU_SUSFS$" "$KSU_DIR/" --include="Kconfig*" 2>/dev/null; then
    echo "⚠️ Le driver n'a pas de symbole KSU_SUSFS : Kconfig injecté (fs/Kconfig.susfs_inject)" | tee -a "$AUDIT"
    {
        echo 'menu "KernelSU - SUSFS (injecté par le script)"'
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

# ==================== 3c. COLLE MINIMALE SuSFS <-> driver (fs/susfs_glue.c) ====================
# Définitions FAIBLES : si le driver fournit déjà un symbole, c'est le sien qui gagne.
if [ "$SUSFS_GLUE" = "1" ]; then
    cat > fs/susfs_glue.c <<'GLUEEOF'
/* Colle minimale SuSFS <-> KernelSU-Next (premier lancement).
 * Ne câble PAS les commandes SuSFS du driver : elle satisfait seulement l'édition de liens. */
#include <linux/types.h>
#include <linux/cred.h>
#include <linux/init.h>
#include <linux/compiler.h>

extern bool is_ksu_domain(void) __weak;
extern void susfs_init(void);

u32 susfs_ksu_sid __weak;
u32 susfs_priv_app_sid __weak;
struct cred *ksu_cred __weak;

void __weak setup_selinux(const char *domain, struct cred *cred)
{
}

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

# ==================== 3d. NEUTRALISATION CHECK.MK ====================
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

# ==================== 3e. NETTOYAGE UNICODE ====================
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

# ==================== 3f. FIX symbol_resolver.h ====================
echo "=== Fix symbol_resolver.h ==="
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h"; do
    if [ -f "$h" ]; then
        sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$h"
        sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$h"
        sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$h"
    fi
done

# ==================== 3g. STATIC EXPORTS SELINUX ====================
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

# ==================== 3h. FIX O_CLOEXEC ====================
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

# ==================== 4. PATCHS MANUELS KERNELSU-NEXT (hooks v2.9, inchangés) ====================
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

# 2. fs/open.c (Ciblage de do_faccessat)
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n#endif\n\n"
    content = re.sub(r'(long\s+do_faccessat\s*\()', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\n\t"
    content = re.sub(r'(\tif\s*\(mode\s*&\s*~S_IRWXO\))', call + r'\1', content, count=1)
    with open('fs/open.c', 'w') as f: f.write(content)
    print("✅ fs/open.c patché (via do_faccessat)")
else:
    print("✅ fs/open.c déjà patché")

# 3. fs/read_write.c (Ciblage chirurgical + cast)
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern = "#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n#endif\n\n"
    match = re.search(r'(SYSCALL_DEFINE3\s*\(\s*read\s*,)', content)
    if match:
        content = content[:match.start()] + extern + content[match.start():]
        start_pos = content.find('SYSCALL_DEFINE3(read,')
        ret_pos = content.find('ssize_t ret = -EBADF;', start_pos)
        if ret_pos != -1:
            # Le cast (char __user **) est crucial pour le noyau 4.19
            call = "\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, (char __user **)&buf, &count);\n#endif"
            insert_pos = ret_pos + len('ssize_t ret = -EBADF;')
            content = content[:insert_pos] + call + content[insert_pos:]
            with open('fs/read_write.c', 'w') as f: f.write(content)
            print("✅ fs/read_write.c patché (chirurgical + cast)")
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

# 6. fs/namespace.c (Backport de path_umount depuis Linux 5.9)
with open('fs/namespace.c', 'r') as f: content = f.read()
if 'int path_umount(struct path *path, int flags)' not in content:
    backport = '''
#ifdef CONFIG_KSU
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we must not call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}
#endif

'''
    content = re.sub(r'(int ksys_umount\(char __user \*name, int flags\))', backport + r'\1', content, count=1)
    with open('fs/namespace.c', 'w') as f: f.write(content)
    print("✅ fs/namespace.c patché (backport path_umount)")
else:
    print("✅ fs/namespace.c déjà patché")

PYEOF

# ==================== 5. CONFIGURATION ====================
echo ""
echo "=== Configuration (KernelSU-Next hooks manuels + SuSFS) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

@@SEG_CLANG@@

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
{
    grep -E "KSU|SECCOMP" out/.config | head -40 || true
    for o in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SUS_MAP KSU_SUSFS_SUS_MOUNT KSU_SUSFS_OPEN_REDIRECT; do
        if grep -q "^CONFIG_${o}=y" out/.config; then echo "  ✅ CONFIG_${o} actif"; else echo "  ℹ️ CONFIG_${o} inactif ou inexistant"; fi
    done
    true
} 2>&1 | tee -a "$AUDIT"

if ! grep -q "^CONFIG_KSU=y" out/.config; then
    echo "❌ CONFIG_KSU non activé, abandon"
    exit 1
fi
if ! grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    echo "❌ CONFIG_KSU_SUSFS supprimé par olddefconfig : SuSFS ne serait pas compilé, abandon" | tee -a "$AUDIT"
    exit 1
fi

# -----------------------------------------------------------------------------
@@SEG_4C@@

# ==================== 6. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 7. COMPILATION KERNEL (make -k : toutes les erreurs d'un coup) ====================
echo "=== Compilation du kernel ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement $PRIO_FLAG" \
  -k -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    grep -iE "error:|undefined symbol|undefined reference|fatal error:" build.log | head -30 || true
    {
        echo "=== ERREURS (rc=$MAKE_RC) ==="
        grep -nE "error:|undefined symbol|undefined reference|fatal error:|\*\*\*" build.log | head -150 || true
        echo ""
        echo "=== SYMBOLES NON DÉFINIS (édition de liens) ==="
        grep -oE "undefined reference to \`[^']+'" build.log | sort | uniq -c | sort -rn | head -60 || true
        echo ""
        echo "=== 150 DERNIÈRES LIGNES ==="
        tail -n 150 build.log
    } > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅ Compilation réussie"
ls -lh out/arch/arm64/boot/
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-${VER}"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-${VER}"

{
    echo ""
    echo "=== AUDIT SYMBOLES dans System.map ==="
    echo "symboles susfs_ : $(grep -ci ' susfs_' out/System.map || true)"
    grep -E " (susfs_init|susfs_is_current_ksu_domain|susfs_add_sus_path|susfs_set_priority_uid_filter|ksu_handle_sys_reboot|ksu_handle_execveat)$" out/System.map || echo "⚠️ symboles clés absents"
    true
} 2>&1 | tee -a "$AUDIT"

# ==================== 8. COMPILATION KSUD (même checkout que le driver) ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"

# Source de ksud : on privilégie le checkout déjà utilisé pour le driver
KSUD_DIR=""
KSUD_ROOT=""
if [ -n "$KSU_REPO_ROOT" ] && [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"
    KSUD_ROOT="$KSU_REPO_ROOT"
    echo "✅ ksud pris dans le MÊME checkout que le driver ($KSU_REF) : $KSUD_DIR"
else
    echo "⚠️  userspace/ksud absent du checkout $KSU_REF"
    echo "⚠️  Fallback : ksud depuis la branche '$KSUD_FALLBACK_REF' (risque de protocole différent du driver)"
    rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
    git clone --depth=1 --branch "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksud-src"
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
    KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
    echo -n "  ksud fallback commit : "; git -C "$GITHUB_WORKSPACE/ksud-src" rev-parse HEAD
    echo -n "  ksud fallback describe : "; git -C "$GITHUB_WORKSPACE/ksud-src" describe --tags --always 2>/dev/null || echo "?"
    echo "  UAPI vue par ksud :"; grep -rn "KERNEL_SU_UAPI_VERSION" "$GITHUB_WORKSPACE/ksud-src" --include=*.h --include=*.rs 2>/dev/null | head -5 || true
fi

if [ ! -f "$KSUD_DIR/Cargo.toml" ]; then
    echo "❌ Cargo.toml de ksud introuvable dans $KSUD_DIR"; exit 1
fi

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"; export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
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
echo "✅ ksud compilé ($KSUD_BINARY)"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK (MÉTHODE BACKSLASHXX) ====================
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

# ==================== 10. DIAGNOSTIC ====================
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

# ==================== 11. SORTIE ====================
cp final_boot.img "output/KernelSU-Next-SUSFS-${VER}-boot.img"
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ ${VER} (KernelSU-Next $KSU_REF + SuSFS 2.3.0) ==="
ls -lh output/
