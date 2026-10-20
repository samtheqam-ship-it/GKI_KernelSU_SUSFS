# Built-in-only NP03J package. No LKM loader or fallback is shipped.
[ "$ARCH" = arm64 ] || abort 'This NoMount package supports ARM64 only.'
[ "$KSU" = true ] || abort 'This package requires KernelSU-Next.'
[ -f "$MODPATH/bin/nm-arm64" ] || abort 'NoMount CLI is missing.'
mv "$MODPATH/bin/nm-arm64" "$MODPATH/bin/nm"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/nm" 0 0 0755
"$MODPATH/bin/nm" version >/dev/null 2>&1 || abort 'Install the matching NP03J kernel with built-in NoMount first.'
if grep -q '^nomount ' /proc/modules; then
  abort 'A separately loaded NoMount driver is present; this release requires built-in NoMount.'
fi
for np03j_script in "$MODPATH"/*.sh; do
  set_perm "$np03j_script" 0 0 0755
done
mkdir -p /data/adb/ksu/bin /data/adb/nomount
ln -sf /data/adb/modules/nomount/bin/nm /data/adb/ksu/bin/nm
rm -f /data/adb/nomount/.booting
ui_print 'NoMount: matched built-in kernel API; ARM64 CLI installed.'
