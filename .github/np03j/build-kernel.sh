#!/usr/bin/env bash
set -euo pipefail

cd "${GITHUB_WORKSPACE:?}/kernel"
test ! -f build/build.sh || { echo 'Expected the Android14 6.1 LTS Kleaf build'; exit 1; }
python3 - <<'PY'
from pathlib import Path
# This LTS uses define_common_kernels(), whose target dictionary does not
# accept check_defconfig. Its check lives in build.config.gki instead.
p = Path('common/build.config.gki')
s = p.read_text()
if 'POST_DEFCONFIG_CMDS' not in s or 'check_defconfig' not in s:
    raise SystemExit('Upstream defconfig-check mechanism changed')
p.write_text(s.replace('check_defconfig', ''))
PY

# Preserve the source KMI/version machinery; only remove the dirty marker.
sed -i 's/-dirty//' common/scripts/setlocalversion
sed -i '/stable_scmversion_cmd/s/-maybe-dirty//g' build/kernel/kleaf/impl/stamp.bzl
git -C common add .
git -C common -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -m 'NP03J: integrate locked KernelSU-Next, SUSFS, NoMount and BBG'

# No ccache setup, no disk cache, no remote cache, no restoration or saving.
tools/bazel build --config=fast --disk_cache= --remote_cache= //common:kernel_aarch64/Image
cd "$GITHUB_WORKSPACE"
python3 .github/np03j/np03j.py collect-kernel \
  source-lock/source-lock.json manager-artifacts/manager-identity.json kernel kernel-artifacts
