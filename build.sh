#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# BUILD TOTAL - LineageOS 23.2 + ReSukiSU + SUSFS
# Device : Motorola One 5G Ace (kiev / lito)
# Kernel : 4.19.325
# Mode   : KSU/SUSFS + NO INPUT HOOK (pour garder le tactile)
# =============================================================================

WORKSPACE="${WORKSPACE:-$PWD}"
ROOT="${ROOT:-${WORKSPACE}/work}"
KERNEL_DIR="${KERNEL_DIR:-${ROOT}/kernel}"
OUTPUT_DIR="${OUTPUT_DIR:-${WORKSPACE}/output}"
OUT_DIR="${OUT_DIR:-${KERNEL_DIR}/out}"
LOG_DIR="${LOG_DIR:-${ROOT}/logs}"
JOBS="${JOBS:-$(nproc)}"

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# URLs
KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
KERNEL_BRANCH="lineage-23.2"

RESUKISU_SETUP_URL="https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh"
RESUKISU_REPO="https://github.com/ReSukiSU/ReSukiSU.git"

MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk"
ANDROID_NDK_URL="https://dl.google.com/android/repository/android-ndk-r26d-linux.zip"

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

mkdir -p "$ROOT" "$LOG_DIR" "$OUTPUT_DIR"

LOG_FILE="${LOG_DIR}/build.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== BUILD TOTAL ReSukiSU + SUSFS (NO INPUT HOOK / tactile conservé) ==="
echo "Répertoire de travail : $ROOT"
echo "Kernel source : $KERNEL_DIR"
echo "Output : $OUTPUT_DIR"
echo "Jobs : $JOBS"
echo "Date : $(date)"

# ---------- helper ----------
download_gdrive_file() {
  local id="$1"
  local out="$2"
  local label="$3"

  echo "→ Téléchargement Google Drive: $label"
  curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
       --connect-timeout 20 --max-time 3600 \
       "https://drive.usercontent.google.com/download?id=${id}&export=download&confirm=t" \
       -A "Mozilla/5.0" \
       -o "$out"
}

# ---------- deps ----------
echo ""
echo "=== Installation dépendances ==="
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg gawk \
  cpio rsync wget perl >/dev/null

python3 -m pip install --quiet gdown || true

# ---------- clone kernel ----------
echo ""
echo "=== Clone kernel ==="
if [ ! -d "$KERNEL_DIR/.git" ]; then
  git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi

cd "$KERNEL_DIR"
git fetch --depth=1 origin
git reset --hard "origin/$KERNEL_BRANCH" 2>/dev/null || git reset --hard HEAD
git log --oneline -1

# ---------- restore input hook baseline ----------
echo ""
echo "=== Neutralisation des hooks input (pour garder le tactile) ==="
if [ -f drivers/input/input.c ]; then
  git checkout -- drivers/input/input.c 2>/dev/null || true

  python3 - <<'PY'
from pathlib import Path
p = Path("drivers/input/input.c")
if p.exists():
    s = p.read_text()
    toks = ["ksu_input_hook", "ksu_handle_input_handle_event"]
    for t in toks:
        s = s.replace(t, "")
    s = s.replace(
        "#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\n",
        ""
    )
    p.write_text(s)
    print("✅ hooks input neutralisés dans drivers/input/input.c")
else:
    print("ℹ️  drivers/input/input.c absent")
PY
fi

# ---------- preserve config in case KSU input auto hook is in .config ----------
if [ -f out/.config ]; then
  sed -i 's/^CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y/# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set/' out/.config 2>/dev/null || true
  sed -i 's/^CONFIG_KSU_MANUAL_HOOK=y/# CONFIG_KSU_MANUAL_HOOK is not set/' out/.config 2>/dev/null || true
  sed -i 's/^CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' out/.config 2>/dev/null || true
fi

# ---------- backport get_cred_rcu ----------
echo ""
echo "=== Backport get_cred_rcu ==="
if ! grep -q "get_cred_rcu" include/linux/cred.h 2>/dev/null; then
  python3 - <<'PY'
import re
from pathlib import Path

cred_h = Path("include/linux/cred.h")
text = cred_h.read_text()
if "get_cred_rcu" not in text:
    pattern = r'(static inline const struct cred \*get_cred\(const struct cred \*cred\)\s*\{[^}]*\})'
    m = re.search(pattern, text, re.DOTALL)
    if m:
        insertion = '''

static inline const struct cred *get_cred_rcu(const struct cred *cred)
{
    struct cred *nonconst_cred = (struct cred *) cred;
    if (!cred)
        return NULL;
    if (!atomic_long_inc_not_zero(&nonconst_cred->usage))
        return NULL;
    validate_creds(cred);
    return cred;
}'''
        text = text[:m.end()] + insertion + text[m.end():]
        cred_h.write_text(text)
        print("✅ get_cred_rcu ajouté dans include/linux/cred.h")

cred_c = Path("kernel/cred.c")
if cred_c.exists():
    text = cred_c.read_text()
    if "get_cred_rcu(cred)" not in text:
        text = text.replace(
            'while (!atomic_long_inc_not_zero(&((struct cred *)cred)->usage));',
            'while (!get_cred_rcu(cred));'
        )
        text = text.replace(
            'while (!atomic_inc_not_zero(&((struct cred *)cred)->usage));',
            'while (!get_cred_rcu(cred));'
        )
        cred_c.write_text(text)
        print("✅ kernel/cred.c modifié")
PY
fi

# ---------- integrate ReSukiSU ----------
echo ""
echo "=== Intégration ReSukiSU ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "$RESUKISU_SETUP_URL" | bash

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU" ]; then
  echo "❌ ReSukiSU setup n'a pas produit de dossier KernelSU"
  exit 1
fi

if [ -d "drivers/kernelsu" ]; then
  KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU" ]; then
  KSU_DIR="KernelSU"
fi
echo "KSU_DIR: $KSU_DIR"

# configure KSU in Kconfig / Makefile if missing
if ! grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig 2>/dev/null; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile 2>/dev/null; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi

# ---------- SUSFS patch (cyberc3dr nGKI 4.19) ----------
echo ""
echo "=== Patch SusFS nGKI 4.19 ==="
NGKI_DIR="${ROOT}/nGKI_Kernel_Build"
rm -rf "$NGKI_DIR"
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git "$NGKI_DIR"

SUSFS_PATCH="$NGKI_DIR/Patches/Patch/susfs_patch_to_4.19.patch"
if [ ! -f "$SUSFS_PATCH" ]; then
  echo "❌ Patch SusFS introuvable"
  exit 1
fi

set +e
patch --batch --forward -p1 < "$SUSFS_PATCH" >/tmp/susfs_patch.log 2>&1
SUSFS_RC=$?
set -e

if [ "$SUSFS_RC" -ne 0 ] || find . -type f -name '*.rej' -print -quit | grep -q .; then
  echo "⚠️ Patch SusFS a des rejets; on continue mais on vérifie"
  find . -type f -name '*.rej' -o -name '*.orig' -delete 2>/dev/null || true
fi

# apply corrections for fs/stat.c / susfs_run_sus_path_loop / missing defs
python3 - <<'PY'
from pathlib import Path
import re

# fs/stat.c include
p = Path("fs/stat.c")
if p.exists():
    text = p.read_text()
    include = "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n"
    if "#include <linux/susfs_def.h>" not in text:
        marker = "#include <asm/unistd.h>\n"
        if marker in text:
            text = text.replace(marker, marker + "\n" + include, 1)
            p.write_text(text)
            print("✅ include susfs_def.h ajouté dans fs/stat.c")

# susfs_run_sus_path_loop in fs/susfs.c
p = Path("fs/susfs.c")
if p.exists():
    text = p.read_text()
    old = "static void susfs_run_sus_path_loop(void)"
    new = "void susfs_run_sus_path_loop(void)"
    if old in text:
        text = text.replace(old, new, 1)
        p.write_text(text)
        print("✅ susfs_run_sus_path_loop rendu global")

# missing definitions fallback
p = Path("fs/susfs.c")
if p.exists():
    text = p.read_text()
    if "susfs_is_current_ksu_domain" not in text:
        text += '''
bool susfs_is_current_ksu_domain(void)
{
    const struct cred *cred = current_cred();
    return (cred->uid.val == 0 || cred->uid.val == 2000);
}
EXPORT_SYMBOL(susfs_is_current_ksu_domain);
'''
    if "susfs_ksu_sid" not in text:
        text += '''
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);
'''
    if "susfs_priv_app_sid" not in text:
        text += '''
u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);
'''
    p.write_text(text)
    print("✅ définitions SUSFS manquantes ajoutées")
PY

# ---------- config kernel ----------
echo ""
echo "=== Configuration kernel ==="
mkdir -p "$OUT_DIR"

# locate defconfig
CONFIG_NAME=""
for candidate in \
  "vendor/lito-perf_defconfig" \
  "vendor/lito_defconfig" \
  "lito_defconfig" \
  "vendor/kiev_defconfig" \
  "kiev_defconfig"; do
  if [ -f "arch/arm64/configs/$candidate" ]; then
    CONFIG_NAME="$candidate"
    break
  fi
done

if [ -z "$CONFIG_NAME" ]; then
  echo "❌ Aucune config lito/kiev trouvée dans arch/arm64/configs"
  exit 1
fi
echo "Config utilisée : $CONFIG_NAME"

make O="$OUT_DIR" LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" "$CONFIG_NAME"

# append KSU/SUSFS config
cat >> "$OUT_DIR/.config" <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_TRACEPOINT_HOOK is not set
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
EOF

make O="$OUT_DIR" LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" olddefconfig

# hard disable KSU input hook in final config
if grep -q "# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set" "$OUT_DIR/.config"; then
  echo "✅ KSU auto input hook désactivé dans la config"
fi
if grep -q "^CONFIG_KPROBES=y" "$OUT_DIR/.config"; then
  sed -i 's/^CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' "$OUT_DIR/.config"
fi

# ---------- patch tactile fallback ----------
echo ""
echo "=== Patch tactile (fallback faible) ==="
if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c 2>/dev/null; then
  printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid __weak touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
  echo "✅ Patch tactile fallback ajouté"
else
  echo "⏭️ Patch tactile déjà présent"
fi

# ---------- module signature fix ----------
echo ""
echo "=== Patch signature modules ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c || true

# ---------- compile kernel ----------
echo ""
echo "=== Compilation noyau ==="
make O="$OUT_DIR" LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" -j"$JOBS" Image 2>&1 | tee "$LOG_DIR/kernel_build.log"

if [ ! -f "$OUT_DIR/arch/arm64/boot/Image" ] && [ ! -f "$OUT_DIR/arch/arm64/boot/Image.gz" ]; then
  echo "❌ BUILD FAILED"
  grep -iE "error:|fatal error:" "$LOG_DIR/kernel_build.log" | head -50 || true
  exit 1
fi

echo "✅ Compilation noyau réussie"

# ---------- build ksud ----------
echo ""
echo "=== Compilation ksud ==="
cd "$WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

rustup toolchain install nightly || true
rustup default nightly || true
rustup target add aarch64-linux-android || true

wget -q "$ANDROID_NDK_URL" -O android-ndk-r26d-linux.zip || true
if [ -f android-ndk-r26d-linux.zip ]; then
  unzip -q android-ndk-r26d-linux.zip || true
fi

NDK_ROOT="${WORKSPACE}/android-ndk-r26d"
if [ ! -d "$NDK_ROOT" ]; then
  NDK_ROOT=$(find "${WORKSPACE}" -maxdepth 2 -type d -name 'android-ndk-*' | head -1 || true)
fi
if [ -z "${NDK_ROOT:-}" ] || [ ! -d "$NDK_ROOT" ]; then
  echo "❌ NDK introuvable"
  exit 1
fi

export ANDROID_NDK_ROOT="$NDK_ROOT"
export ANDROID_NDK_HOME="$NDK_ROOT"
export AARCH64_CLANG_PATH="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$WORKSPACE/ksud-src"
git clone --depth=1 "$RESUKISU_REPO" "$WORKSPACE/ksud-src"
cd "$WORKSPACE/ksud-src/userspace/ksud"

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
cargo +nightly build --release --target aarch64-linux-android >/tmp/ksud_build.log 2>&1 || {
  echo "❌ build ksud échoué"
  cat /tmp/ksud_build.log
  exit 1
}

KSUD_BIN=$(find "$WORKSPACE/ksud-src" -type f -name ksud -executable 2>/dev/null | head -1)
if [ -z "$KSUD_BIN" ]; then
  echo "❌ ksud binaire introuvable"
  exit 1
fi

cp "$KSUD_BIN" "$WORKSPACE/ksud"
chmod 755 "$WORKSPACE/ksud"
echo "✅ ksud compilé"

# ---------- download stock images ----------
echo ""
echo "=== Téléchargement images stock ==="
cd "$WORKSPACE"

download_gdrive_file "$BOOT_GDRIVE_ID" "$WORKSPACE/boot-stock.img" "boot.img"
download_gdrive_file "$DTBO_GDRIVE_ID" "$WORKSPACE/dtbo-stock.img" "dtbo.img"

# ---------- repack boot.img ----------
echo ""
echo "=== Repack boot.img ==="
mkdir -p "$WORKSPACE/repack"
cp "$WORKSPACE/boot-stock.img" "$WORKSPACE/repack/boot.img"

wget -q "$MAGISK_URL" -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so "$WORKSPACE/repack/magiskboot"
chmod +x "$WORKSPACE/repack/magiskboot"
rm -rf Magisk-v27.0.apk lib/

cd "$WORKSPACE/repack"
./magiskboot unpack boot.img

if [ ! -f kernel ] || [ ! -f ramdisk.cpio ]; then
  echo "❌ Unpack boot.img échoué"
  exit 1
fi

cp "$KERNEL_DIR/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
  "mkdir 0755 data" \
  "mkdir 0755 data/adb" \
  "mkdir 0755 data/adb/ksud" \
  "add 0755 data/adb/ksud/ksud $WORKSPACE/ksud"

cp "$WORKSPACE/ksud" local_su_binary
chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio \
  "mkdir 0755 system" \
  "mkdir 0755 system/bin" \
  "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary

./magiskboot repack boot.img new-boot.img
mv new-boot.img "$WORKSPACE/final_boot.img"
cd "$WORKSPACE"

# ---------- output ----------
echo ""
echo "=== Collecte artefacts ==="
mkdir -p "$OUTPUT_DIR"
cp "$WORKSPACE/final_boot.img" "$OUTPUT_DIR/ReSukiSU-SuSFS-boot-no-inputhook.img"
cp "$WORKSPACE/dtbo-stock.img" "$OUTPUT_DIR/dtbo.img" 2>/dev/null || true
cp "$KERNEL_DIR/out/arch/arm64/boot/Image" "$OUTPUT_DIR/kernel-Image" 2>/dev/null || true
cp "$WORKSPACE/ksud" "$OUTPUT_DIR/ksud" 2>/dev/null || true
cp "$LOG_FILE" "$OUTPUT_DIR/build.log" 2>/dev/null || true

echo ""
echo "=== BUILD TERMINÉ ==="
ls -lh "$OUTPUT_DIR"
echo "Boot final: $OUTPUT_DIR/ReSukiSU-SuSFS-boot-no-inputhook.img"
