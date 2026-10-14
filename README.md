# Build GitHub Actions — kiev / ReSukiSU + SUSFS

Ce kit construit le kernel LineageOS pour kiev depuis la branche par défaut du dépôt source, applique le patch tactile avant compilation, puis génère un `boot.img` avec le kernel `Image.gz`, le ramdisk de référence et les modules compilés.

## Installation dans le dépôt GitHub

Copier le contenu de ce dossier à la racine du dépôt GitHub :

```text
.github/workflows/build-kiev-kernel.yml
integration/
scripts/
manual-integrate.md
README.md
```

Le workflow est lancé automatiquement lorsqu’un de ces fichiers change, ou manuellement depuis **Actions → Build kiev ReSukiSU SUSFS kernel → Run workflow**.

## Versions reproductibles

| Élément | Valeur |
|---|---|
| Kernel | `LineageOS/android_kernel_motorola_sm8250` — branche par défaut, sans commit fixe |
| Driver manager BakaSU/ReSukiSU | `5b76b884c75f729a220bb317aa4a4fc78f0e0e9c` |
| Image boot de référence | Google Drive ID `1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis` |
| Image dtbo de référence | Google Drive ID `11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX` |
| Defconfig | `vendor/lito-perf_defconfig` |
| Architecture | `arm64` |

La révision du driver manager est alignée sur l’APK `BakaSU_v4.2.0-rc3_35222-arm64-v8a-release.apk`, qui utilise le même commit. La révision du noyau suit volontairement la branche par défaut du dépôt LineageOS, sans commit fixe.

`manual-integrate.md` conserve les modèles de hooks manuels ReSukiSU. Pour un kernel non-GKI, ces hooks doivent être vérifiés et adaptés à la version exacte du code source ; leur absence peut faire échouer la compilation. SUSFS sur non-GKI est un backport spécifique, et non une compatibilité universelle garantie.

## Choix Kconfig ReSukiSU

La révision `5b76b884c75f729a220bb317aa4a4fc78f0e0e9c` place `KSU_TRACEPOINT_HOOK`, `KSU_MANUAL_HOOK` et `KSU_SUSFS` dans un choix exclusif. Les adaptations de `Branche-B` utilisent les hooks protégés par `CONFIG_KSU_SUSFS`; le build sélectionne donc exclusivement `CONFIG_KSU_SUSFS=y` et force `CONFIG_KSU_MANUAL_HOOK` ainsi que `CONFIG_KSU_TRACEPOINT_HOOK` à `n`. Les options `KSU_MANUAL_HOOK_AUTO_*` restent désactivées car elles dépendent du mode Manual Hook.

## Patch tactile

Avant la compilation, le script racine `build.sh` applique obligatoirement le patch tactile dans `techpack/display/msm/msm_drv.c`. Il ajoute `panel_register_notifier`, `panel_unregister_notifier` et `touch_set_state`, puis vérifie que les deux symboles principaux sont présents. Le script échoue si ce fichier est absent.

## Artefacts produits

Le job téléverse :

- `boot-resukisu-susfs-kiev-20260920.img` : image boot finale, de taille normalement égale à la partition de référence ;
- `dtbo.img` : image DTBO de référence ;
- `Image.gz` : kernel compressé séparément ;
- `boot.img` original et `build.log` pour diagnostic.

Le workflow ne flashe aucune image et ne modifie aucun appareil.

## Exécution locale équivalente

Depuis la racine du kit :

```bash
WORKSPACE="$PWD" JOBS=2 bash build.sh

ROOT="$PWD/work" \
REFERENCE_BOOT="$PWD/work/reference/boot.img" \
KERNEL_IMAGE="$PWD/work/kernel/out/arch/arm64/boot/Image.gz" \
MODULE_ROOT="$PWD/work/kernel/out" \
OUTPUT_BOOT="$PWD/work/boot-resukisu-susfs-kiev-20260920.img" \
  python3 scripts/repack_bootimg.py
```

La compilation demande plusieurs gigaoctets d’espace disque et peut dépasser une heure sur un runner partagé. Le workflow limite volontairement la parallélisation à deux jobs pour réduire le risque d’épuisement mémoire.

## Vérifications importantes

Avant tout flash, vérifier la somme SHA-256 de l’artefact, confirmer que `file boot-resukisu-susfs-kiev-20260920.img` identifie une Android boot image, et comparer la taille à la partition `boot` réelle du téléphone. La génération de l’image ne constitue pas une validation de démarrage sur matériel.
