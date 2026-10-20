### NP03J-only AnyKernel3 installer. AnyKernel3 core is supplied at its locked revision.
# AnyKernel reads this literal property block from the file; it does not call it.
# shellcheck disable=SC2289
properties() { '
kernel.string=NP03J Android 6.1 LTS / built-in KernelSU-Next
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
do.check_boot_version=0
supported.versions=16
supported.patchlevels=
supported.vendorpatchlevels=
'; }

# Variables below are consumed by the sourced AnyKernel core.
# shellcheck disable=SC2034
block=boot
# shellcheck disable=SC2034
is_slot_device=1
# shellcheck disable=SC2034
ramdisk_compression=auto
# shellcheck disable=SC2034
patch_vbmeta_flag=auto
# shellcheck disable=SC2034
no_magisk_check=1
. tools/ak3-core.sh

# Model/product guard: the generic Snapdragon 'pineapple' platform is not sufficient.
np03j_match=false
for np03j_prop in ro.product.model ro.product.vendor.model ro.product.device ro.product.name ro.product.vendor.name; do
  np03j_value=$(getprop "$np03j_prop")
  case "$np03j_value" in
    NP03J|PQ83P01|PQ83P01-EEA|PQ83P01-UN|PQ83P01_EEA|PQ83P01_UN) np03j_match=true ;;
  esac
done
$np03j_match || abort 'This kernel package is restricted to REDMAGIC Nova NP03J.'
case "$(uname -r)" in
  6.1.*-android14-11|6.1.*-android14-11-*) ;;
  *) abort 'Expected the NP03J 6.1 / android14-11 KMI family.' ;;
esac
np03j_page=$(getconf PAGESIZE 2>/dev/null)
[ -z "$np03j_page" ] || [ "$np03j_page" = 4096 ] || abort 'This package requires a 4K-page device.'

split_boot
if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
  unpack_ramdisk
  write_boot
else
  flash_boot
fi
