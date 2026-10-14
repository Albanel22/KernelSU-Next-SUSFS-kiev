#!/usr/bin/env bash
# build_all_autopatch.sh
# Script autonome : patch task_mmu, neutralise input hook, build kernel, (optionnel) ksud, (optionnel) repack boot
# Usage examples:
#  ./build_all_autopatch.sh
#  DO_BUILD_KSUD=0 DO_REPACK=0 ./build_all_autopatch.sh
#  SKIP_DEPS=1 ./build_all_autopatch.sh
set -Eeuo pipefail

# ====================== CONFIGURATION ===========================
WORKSPACE="${WORKSPACE:-$PWD}"
ROOT="${ROOT:-$WORKSPACE/work}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_motorola_sm8250.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-23.2}"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
OUTPUT_DIR="${OUTPUT_DIR:-$WORKSPACE/output}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/build.log}"

# Optional toggles
SKIP_DEPS="${SKIP_DEPS:-0}"          # 1 = don't apt-get install packages
SKIP_RESUKISU="${SKIP_RESUKISU:-0}"  # 1 = skip ReSukiSU setup (for quick tests)
DO_BUILD_KERNEL="${DO_BUILD_KERNEL:-1}"
DO_BUILD_KSUD="${DO_BUILD_KSUD:-1}"   # requires rust + ndk; set 0 to skip
DO_REPACK="${DO_REPACK:-1}"          # repack boot.img
SKIP_KSUD="${SKIP_KSUD:-0}"          # alias
SKIP_REPACK="${SKIP_REPACK:-0}"

JOBS="${JOBS:-$(nproc)}"

# Boot / dtbo sources for repack (change if needed)
BOOT_GDRIVE_ID="${BOOT_GDRIVE_ID:-1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis}"
DTBO_GDRIVE_ID="${DTBO_GDRIVE_ID:-11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX}"
MAGISK_URL="${MAGISK_URL:-https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk}"
ANDROID_NDK_URL="${ANDROID_NDK_URL:-https://dl.google.com/android/repository/android-ndk-r26d-linux.zip}"

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"

echo "=============================================="
echo "BUILD ALL AUTOPATCH"
echo "Workspace: $WORKSPACE"
echo "Kernel dir: $KERNEL_DIR"
echo "Output: $OUTPUT_DIR"
echo "Jobs: $JOBS"
echo "DO_BUILD_KSUD:$DO_BUILD_KSUD DO_REPACK:$DO_REPACK SKIP_RESUKISU:$SKIP_RESUKISU"
echo "=============================================="

mkdir -p "$ROOT" "$KERNEL_DIR" "$OUT_DIR" "$OUTPUT_DIR" "$LOG_DIR"
# tee all output to log
exec > >(tee -a "$LOG_FILE") 2>&1

# ====================== HELPERS ===========================
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

download_with_retry() {
  local url="$1" out="$2" tries="${3:-4}"
  local i=0
  while [ $i -lt $tries ]; do
    if curl -fsSL --connect-timeout 20 --max-time 600 "$url" -o "$out"; then
      return 0
    fi
    i=$((i+1))
    sleep 3
  done
  return 1
}

download_gdrive_image() {
  local id="$1" out="$2" label="$3"
  info "Téléchargement Google Drive: $label -> $out"
  # use a simple gdrive download link (may require gdown if large)
  # try direct usercontent link first
  if ! curl -fsSL -o "$out" "https://drive.usercontent.google.com/download?id=${id}&export=download&confirm=t"; then
    warn "Google Drive direct failed, trying gdown (pip) if available"
    if command -v gdown >/dev/null 2>&1; then
      gdown "https://drive.google.com/uc?id=${id}" -O "$out"
    else
      die "gdown not installed and direct download failed"
    fi
  fi
}

# ====================== DEPENDENCIES ===========================
if [ "$SKIP_DEPS" != "1" ]; then
  info "Installation dépendances apt (peut demander sudo)..."
  sudo apt-get update -qq || warn "apt-get update a échoué (continuation)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld llvm-tools device-tree-compiler \
    zip unzip curl wget git python3 python3-pip mkbootimg rsync cpio || warn "apt install a rencontré des erreurs"
  # pip user tools
  python3 -m pip install --user --upgrade pip || true
  python3 -m pip install --user gdown || true
  export PATH="$HOME/.local/bin:$PATH"
else
  info "SKIP_DEPS=1 -> skip installing apt deps"
fi

# ====================== CLONE KERNEL ===========================
if [ ! -d "$KERNEL_DIR/.git" ]; then
  info "Clone kernel depuis $KERNEL_REPO (branch $KERNEL_BRANCH)"
  git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR" || die "git clone noyau échoué"
else
  info "Kernel déjà présent: $KERNEL_DIR"
fi

cd "$KERNEL_DIR"
# ensure on branch head
git fetch --depth=1 origin "$KERNEL_BRANCH" || true
if git rev-parse --verify "origin/$KERNEL_BRANCH" >/dev/null 2>&1; then
  git reset --hard "origin/$KERNEL_BRANCH"
else
  git reset --hard HEAD
fi
info "Kernel commit: $(git log --oneline -1 | sed -n '1p')"

# ====================== PATCH task_mmu.c (vma unused) ===========================
TARGET_TM="${KERNEL_DIR}/fs/proc/task_mmu.c"
if [ -f "$TARGET_TM" ]; then
  info "Patch automatique: fs/proc/task_mmu.c (vma unused) -> backup & patch"
  cp -a "$TARGET_TM" "${TARGET_TM}.bak.$(date +%Y%m%d%H%M%S)"
  python3 - <<'PY'
from pathlib import Path
import re, sys

p = Path("$TARGET_TM")
s = p.read_text()

# pattern for simple declaration
decl_re = re.compile(r'(?m)^[ \t]*struct\s+vm_area_struct\s*\*\s*vma\s*;\s*$')
m = decl_re.search(s)
if not m:
    print("[PATCH] Aucune déclaration standard 'struct vm_area_struct *vma;' trouvée -> skip")
    sys.exit(0)

start, end = m.start(), m.end()
window = s[end:end+4000]  # regarder après la déclaration
uses_arrow = bool(re.search(r'\bvma\s*->', window))
uses_word = bool(re.search(r'\bvma\b', window))
susfs_nearby = bool(re.search(r'(?i)susfs|SUS_MAP|susfs_is_current_ksu_domain', window))

print(f"[PATCH] position {start}, usages arrow={uses_arrow}, word={uses_word}, susfs_nearby={susfs_nearby}")

if not uses_arrow and not uses_word:
    # safe: not used -> add (void)vma;
    s = s[:end] + "\n\t(void)vma;\n" + s[end:]
    p.write_text(s)
    print("[PATCH] (void)vma; ajouté après la déclaration")
    sys.exit(0)

if susfs_nearby:
    # wrap the declaration in #ifdef CONFIG_KSU_SUSFS_SUS_MAP
    decl_text = m.group(0)
    wrapped = "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n" + decl_text + "\n#endif\n"
    s = s[:start] + wrapped + s[end:]
    p.write_text(s)
    print("[PATCH] Déclaration entourée par #ifdef CONFIG_KSU_SUSFS_SUS_MAP")
    sys.exit(0)

# If we get here, vma seems used but not clearly SUSFS -> conservative exit
print("[PATCH] Usage de 'vma' détecté mais contexte incertain; aucune modification appliquée.")
sys.exit(2)
PY
  rc=$? || true
  if [ "$rc" -eq 0 ]; then
    info "Patch task_mmu.c appliqué (ou aucune modification nécessaire)"
  else
    if [ "$rc" -eq 2 ]; then
      warn "Le script automatique a détecté un usage incertain de vma. Vérifie manuellement ${TARGET_TM} (backup créé)."
    else
      warn "Erreur inconnue lors du patch task_mmu.c (code $rc)."
    fi
  fi
else
  warn "Fichier fs/proc/task_mmu.c introuvable, skip patch vma"
fi

# ====================== RESTORE / CLEAN drivers/input/input.c ===========================
INPUT_C="${KERNEL_DIR}/drivers/input/input.c"
if [ -f "$INPUT_C" ]; then
  info "Restoration / nettoyage drivers/input/input.c -> backup & restore + sanitize"
  cp -a "$INPUT_C" "${INPUT_C}.bak.$(date +%Y%m%d%H%M%S)"
  # try git checkout if tracked
  if git ls-files --error-unmatch "$INPUT_C" >/dev/null 2>&1; then
    git checkout -- "$INPUT_C" || warn "git checkout drivers/input/input.c failed (continuing with sanitize)"
  fi
  # sanitize residual injection and identifiers
  python3 - <<'PY'
from pathlib import Path
p = Path("$INPUT_C")
if not p.exists():
    print("[INPUT] Pas de drivers/input/input.c -> skip")
    raise SystemExit(0)
s = p.read_text()
changed = False
# patterns to remove
s_new = s.replace('#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\n', '')
if s_new != s:
    s = s_new; changed = True
# remove extern decl block if present
s_new = s.replace('extern bool ksu_input_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_input_handle_event(\n\t\t\tunsigned int *type, unsigned int *code, int *value);\n', '')
if s_new != s:
    s = s_new; changed = True
# remove stray identifiers
if 'ksu_input_hook' in s or 'ksu_handle_input_handle_event' in s:
    s = s.replace('ksu_input_hook', '')
    s = s.replace('ksu_handle_input_handle_event', '')
    changed = True
if changed:
    p.write_text(s)
    print("[INPUT] Nettoyage effectué: injection KSU supprimée si présente")
else:
    print("[INPUT] Aucun code d'injection KSU détecté")
PY
else
  warn "drivers/input/input.c absent dans le tree kernel"
fi

# ====================== INTEGRATE ReSukiSU / SUSFS (optional) ===========================
if [ "$SKIP_RESUKISU" = "1" ]; then
  info "SKIP_RESUKISU=1 -> skip ReSukiSU/SUSFS integration"
else
  info "Integration ReSukiSU (setup.sh) - attempt"
  # attempt simple setup via upstream script (as in previous scripts)
  if curl -fsSL "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s --; then
    info "ReSukiSU setup executed"
  else
    warn "ReSukiSU setup script failed (continuation allowed)"
  fi
  # ensure Kconfig / Makefile lines present
  if ! grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig 2>/dev/null; then
    sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig || warn "Cannot modify drivers/Kconfig"
  fi
  if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile 2>/dev/null; then
    echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile || warn "Cannot modify drivers/Makefile"
  fi
fi

# ====================== CONFIGURE KERNEL (set desired KSU options) ===========================
info "Configuration kernel (defconfig + configure options)"
# pick config file
CONFIG_CANDIDATE="$(find arch/arm64/configs -type f -name '*lito*' -o -name '*kiev*' 2>/dev/null | head -1 || true)"
if [ -z "$CONFIG_CANDIDATE" ]; then
  CONFIG_NAME="vendor/lito-perf_defconfig"
else
  CONFIG_NAME="${CONFIG_CANDIDATE#arch/arm64/configs/}"
fi
info "Using config: $CONFIG_NAME"

make O="$OUT_DIR" LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" "$CONFIG_NAME"

# Append desired KSU/SUSFS flags while explicitly disabling the auto input hook
cat >> "$OUT_DIR/.config" <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_TRACEPOINT_HOOK is not set
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
# force disable auto input hook
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
EOF

# Ensure the auto input hook is explicitly disabled
sed -i 's/^CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y/# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set/' "$OUT_DIR/.config" || true
# run olddefconfig
make O="$OUT_DIR" LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" olddefconfig

# sanity check for config values
grep -E 'KSU_MANUAL_HOOK|KSU_SUSFS|KSU_MANUAL_HOOK_AUTO_INPUT_HOOK|KPROBES' "$OUT_DIR/.config" | sed -n '1,200p' || true

# ====================== BUILD KERNEL ===========================
if [ "$DO_BUILD_KERNEL" = "1" ]; then
  info "Compilation kernel (Image) - jobs=$JOBS"
  make O="$OUT_DIR" LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" -j"$JOBS" Image 2>&1 | tee "$LOG_DIR/kernel_build.log" || {
    warn "Compilation kernel échouée: voir $LOG_DIR/kernel_build.log"
    die "Build failed"
  }
  info "Kernel build finished"
else
  info "DO_BUILD_KERNEL=0 -> skip kernel build"
fi

# ====================== BUILD KSUD (optionnel, lent) ===========================
if [ "$DO_BUILD_KSUD" = "1" ] && [ "$SKIP_KSUD" != "1" ]; then
  info "Compilation ksud (Rust + NDK) - this can be slow"

  # install rustup if missing
  if ! command -v cargo >/dev/null 2>&1; then
    info "Installing rustup (non-interactive)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
  fi

  rustup toolchain install nightly || true
  rustup default nightly || true
  rustup target add aarch64-linux-android || true

  # download NDK if not present
  if [ ! -d "$WORKSPACE/android-ndk-r26d" ]; then
    info "Downloading Android NDK (r26d) - can be large"
    if ! download_with_retry "$ANDROID_NDK_URL" "$WORKSPACE/android-ndk-r26d.zip" 3; then
      warn "NDK download failed; skipping ksud build"
      SKIP_KSUD=1
    else
      unzip -q "$WORKSPACE/android-ndk-r26d.zip" -d "$WORKSPACE"
      rm -f "$WORKSPACE/android-ndk-r26d.zip"
    fi
  fi

  if [ "$SKIP_KSUD" != "1" ]; then
    NDK_ROOT=$(find "$WORKSPACE" -maxdepth 2 -type d -name "android-ndk-*" | head -1)
    if [ -z "$NDK_ROOT" ] || [ ! -d "$NDK_ROOT" ]; then
      warn "NDK not found; abort ksud build"
      SKIP_KSUD=1
    else
      export ANDROID_NDK_ROOT="$NDK_ROOT"
      export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
      export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
      export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
      export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

      # clone ReSukiSU userspace & build ksud
      KSUD_SRC="$WORKSPACE/ksud-src"
      rm -rf "$KSUD_SRC"
      git clone --depth=1 https://github.com/ReSukiSU/ReSukiSU.git "$KSUD_SRC" || warn "git clone ReSukiSU failed"
      if [ -d "$KSUD_SRC" ]; then
        cd "$KSUD_SRC/userspace/ksud"
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
          warn "ksud build failed; see /tmp/ksud_build.log"
          SKIP_KSUD=1
        }
        KSUD_BIN=$(find . -type f -name ksud -executable 2>/dev/null | head -1 || true)
        if [ -n "$KSUD_BIN" ]; then
          cp "$KSUD_BIN" "$WORKSPACE/ksud"
          chmod 755 "$WORKSPACE/ksud"
          info "ksud built and copied to $WORKSPACE/ksud"
        else
          warn "ksud binary not found"
          SKIP_KSUD=1
        fi
      fi
    fi
  fi
else
  info "DO_BUILD_KSUD=0 or SKIP_KSUD=1 -> skip ksud build"
fi

# ====================== REPACK BOOT (magiskboot) - optional ===========================
if [ "$DO_REPACK" = "1" ] && [ "$SKIP_REPACK" != "1" ]; then
  info "Repack boot.img (magiskboot) - attempting"

  cd "$WORKSPACE"
  mkdir -p repack
  # prefer official mirror then fallback to gdrive
  BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"
  if ! download_with_retry "$BOOT_URL" "$WORKSPACE/boot-stock.img" 2; then
    info "Mirror download failed -> trying google drive id"
    download_gdrive_image "$BOOT_GDRIVE_ID" "$WORKSPACE/boot-stock.img" "boot.img" || die "boot.img download failed"
  fi
  # dtbo
  if ! download_with_retry "https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img" "$WORKSPACE/dtbo-stock.img" 2; then
    download_gdrive_image "$DTBO_GDRIVE_ID" "$WORKSPACE/dtbo-stock.img" "dtbo.img" || warn "dtbo not downloaded"
  fi

  cp "$WORKSPACE/boot-stock.img" repack/boot.img

  # magiskboot
  if ! [ -x repack/magiskboot ]; then
    info "Extract magiskboot from Magisk apk"
    download_with_retry "$MAGISK_URL" "$WORKSPACE/Magisk.apk" 3 || die "Magisk download failed"
    unzip -q "$WORKSPACE/Magisk.apk" lib/x86_64/libmagiskboot.so || die "magisk unzip failed"
    mkdir -p repack
    mv lib/x86_64/libmagiskboot.so repack/magiskboot
    chmod +x repack/magiskboot
    rm -rf lib "$WORKSPACE/Magisk.apk"
  fi

  cd repack
  ./magiskboot unpack boot.img || die "magiskboot unpack failed"
  # replace kernel
  if [ -f "$OUT_DIR/arch/arm64/boot/Image" ]; then
    cp "$OUT_DIR/arch/arm64/boot/Image" kernel
  elif [ -f "$OUT_DIR/arch/arm64/boot/Image.gz" ]; then
    cp "$OUT_DIR/arch/arm64/boot/Image.gz" kernel
  else
    warn "Kernel image not found for repack"
  fi

  # inject ksud if present
  if [ -f "$WORKSPACE/ksud" ]; then
    ./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" "add 0755 data/adb/ksud/ksud $WORKSPACE/ksud"
    cp "$WORKSPACE/ksud" local_su_binary && chmod 755 local_su_binary
    ./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su_binary"
    rm -f local_su_binary
  else
    warn "ksud not found -> skipping injection"
  fi

  ./magiskboot repack boot.img new-boot.img || die "magiskboot repack failed"
  mv new-boot.img "$WORKSPACE/final_boot.img"
  cd "$WORKSPACE"
  cp "$WORKSPACE/final_boot.img" "$OUTPUT_DIR/ReSukiSU-SuSFS-boot-no-inputhook.img"
  info "Boot repacked -> $OUTPUT_DIR/ReSukiSU-SuSFS-boot-no-inputhook.img"
else
  info "DO_REPACK=0 or SKIP_REPACK=1 -> skip repack"
fi

# ====================== COLLECT ARTIFACTS ===========================
info "Collecte des artefacts dans $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
if [ -f "$OUT_DIR/arch/arm64/boot/Image" ]; then
  cp "$OUT_DIR/arch/arm64/boot/Image" "$OUTPUT_DIR/kernel-Image" || true
fi
if [ -f "$OUT_DIR/arch/arm64/boot/Image.gz" ]; then
  cp "$OUT_DIR/arch/arm64/boot/Image.gz" "$OUTPUT_DIR/kernel-Image.gz" || true
fi
cp "$LOG_FILE" "$OUTPUT_DIR/build.log" 2>/dev/null || true
if [ -f "$WORKSPACE/ksud" ]; then
  cp "$WORKSPACE/ksud" "$OUTPUT_DIR/ksud" 2>/dev/null || true
fi
if [ -f "$WORKSPACE/final_boot.img" ]; then
  cp "$WORKSPACE/final_boot.img" "$OUTPUT_DIR/final_boot.img" 2>/dev/null || true
fi

info "=== BUILD COMPLETE ==="
ls -lh "$OUTPUT_DIR" || true
echo ""
info "Si tactile toujours absent après flash, récupère dmesg / adb logs et je t'aide à diagnostiquer (driver/DT/firmware)."

# end
