#Requires -Version 5.1
# Installs only the NP03J r2 built-in NoMount package; no partition flashing.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Console]::OutputEncoding
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $NpAdb = 'E:\platform-tools\adb.exe'
    $NpSerial = 'PDNP03J000070074'
    $NpPin = 'e6641659a7c445787520ff842bb4e6f28e99ea87'
    $NpExpectedZip = '5ba9e1b2bbffab1238d5ca748759f9c301da91a18f1128007278cbf8a73b160c'
    $NpZipUrl = 'https://github.com/samtheqam-ship-it/GKI_KernelSU_SUSFS/releases/download/np03j-6.1.177-r2-a1/NoMount-NP03J-Builtin.zip'
    $NpStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $NpWork = "E:\11.0.6NP03J_EU\06_ROOT\nomount_$NpStamp"
    $NpRemote = "/data/local/tmp/np03j_nomount_$NpStamp"

    function Invoke-NpAdb {
        param([string[]]$NpArguments, [switch]$NpSoft)
        $ErrorActionPreference = 'Continue'
        $NpOutput = @(& $NpAdb -s $NpSerial @NpArguments 2>&1 | ForEach-Object { "$_" })
        $NpExit = $LASTEXITCODE
        $NpText = ($NpOutput -join [Environment]::NewLine).Trim()
        if ($NpSoft) { return [pscustomobject]@{ Exit = $NpExit; Text = $NpText } }
        if ($NpExit -ne 0) { throw ("STOP: ADB_COMMAND_FAILED: " + ($NpArguments -join ' ') + [Environment]::NewLine + $NpText) }
        return $NpText
    }
    function Invoke-NpRoot {
        param([string]$NpCommand)
        if ($NpCommand.Contains("'")) { throw 'STOP: ROOT_COMMAND_QUOTING' }
        Invoke-NpAdb @('shell', ("su -c '" + $NpCommand + "'"))
    }
    function Assert-NpDevice {
        if ((Invoke-NpAdb @('shell', 'getprop ro.product.model')) -cne 'NP03J') { throw 'STOP: WRONG_MODEL' }
        if ((Invoke-NpAdb @('shell', 'getprop ro.build.version.incremental')) -cne '20260603.025850') { throw 'STOP: WRONG_ROM' }
        if ((Invoke-NpAdb @('shell', 'uname -r')) -cne '6.1.177-android14-11') { throw 'STOP: WRONG_KERNEL' }
        if ((Invoke-NpAdb @('shell', 'getconf PAGESIZE')) -ne '4096') { throw 'STOP: WRONG_PAGE_SIZE' }
        if ((Invoke-NpAdb @('shell', 'getenforce')) -cne 'Enforcing') { throw 'STOP: SELINUX_CHANGED' }
        if ((Invoke-NpRoot 'id -u') -ne '0') { throw 'STOP: SHELL_ROOT_NOT_GRANTED' }
    }
    function Get-NpExclusions {
        param([string]$NpJson)
        $NpTrimmed = $NpJson.Trim()
        if (!$NpTrimmed.StartsWith('[') -or !$NpTrimmed.EndsWith(']')) { throw 'STOP: EXCLUSIONS_NOT_AN_ARRAY' }
        $NpItems = @($NpJson | ConvertFrom-Json)
        foreach ($NpItem in $NpItems) {
            if ($null -eq $NpItem -or $null -eq $NpItem.PSObject.Properties['uid']) { throw 'STOP: EXCLUSION_UID_MISSING' }
            $NpUid = [string]$NpItem.uid
            $NpNumeric = [uint32]0
            if ($NpUid -notmatch '^[0-9]+$' -or ![uint32]::TryParse($NpUid, [ref]$NpNumeric)) { throw 'STOP: INVALID_EXCLUSION_UID' }
            if ($NpNumeric -eq 0) { throw 'STOP: ROOT_UID_EXCLUDED_FROM_NOMOUNT' }
            $NpItem.uid = [string]$NpNumeric
        }
        return ,$NpItems
    }
    function Get-NpNoMountScripts {
        $NpPreflight = @'
#!/system/bin/sh
# NP03J_NOMOUNT_PREFLIGHT
set -eu
R=$1
PIN=$2
D=/data/adb/nomount
M=/data/adb/modules/nomount
K=/data/adb/ksud
BB=/data/adb/ksu/bin/busybox
stop() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || stop ROOT_REQUIRED
[ -x "$K" ] && [ -x "$BB" ] || stop KSU_USERSPACE_MISSING
"$K" --version
"$K" --version | grep -qF '3.4.2-50-gb427a3f9 (uapi: 6)' || stop KSU_USERSPACE_VERSION_MISMATCH
[ ! -f "$D/disable" ] || stop NOMOUNT_SAFE_MODE_ALREADY_SET
[ ! -d /data/adb/modules_update/nomount ] || stop NOMOUNT_UPDATE_ALREADY_PENDING
if [ -L /data/adb/metamodule ]; then
    target=$(readlink -f /data/adb/metamodule) || stop BROKEN_METAMODULE_LINK
    [ "$target" = "$M" ] || stop "COMPETING_METAMODULE=$target"
elif [ -e /data/adb/metamodule ]; then
    stop METAMODULE_PATH_IS_NOT_A_SYMLINK
fi
for p in /data/adb/modules/*/module.prop /data/adb/modules_update/*/module.prop; do
    [ -f "$p" ] || continue
    if grep -Eiq '^metamodule=(true|1)[[:space:]]*$' "$p"; then
        dir=$(dirname "$p")
        [ "$(basename "$dir")" = nomount ] || stop "COMPETING_METAMODULE=$dir"
    fi
done
if [ -d "$M" ]; then
    [ ! -f "$M/remove" ] && [ ! -f "$M/update" ] || stop NOMOUNT_HAS_PENDING_STATE
    [ -f "$M/NOMOUNT_SOURCE_COMMIT" ] || stop EXISTING_NOMOUNT_SOURCE_UNKNOWN
    [ "$(cat "$M/NOMOUNT_SOURCE_COMMIT")" = "$PIN" ] || stop EXISTING_NOMOUNT_SOURCE_DIFFERS
fi
if grep -q '^nomount ' /proc/modules; then stop UNEXPECTED_NOMOUNT_LKM; fi
chmod 700 "$R/nm"
version=$("$R/nm" version) || stop BUILTIN_NOMOUNT_API_UNAVAILABLE
echo "NOMOUNT_KERNEL_VERSION=$version"
case "$version" in 21|21\ \(*\)) ;; *) stop UNEXPECTED_NOMOUNT_API_VERSION;; esac
cat /proc/sys/kernel/random/boot_id > "$R/boot-before"
if [ -f "$D/nomount.log" ]; then
    sha256sum "$D/nomount.log" | cut -d' ' -f1 > "$R/log-before.sha"
else
    echo MISSING > "$R/log-before.sha"
fi
if [ -f "$D/.exclusion_list.json" ]; then
    cp "$D/.exclusion_list.json" "$R/exclusions-before.json"
else
    printf '[]\n' > "$R/exclusions-before.json"
fi
if [ -f "$D/.block_isolated_uids" ]; then echo 1; else echo 0; fi > "$R/isolated-before"
"$K" module list > "$R/modules-before.json"
set --
[ ! -d "$D" ] || set -- "$@" nomount
[ ! -d "$M" ] || set -- "$@" modules/nomount
[ ! -d /data/adb/ksu/module_configs/nomount ] || set -- "$@" ksu/module_configs/nomount
if [ "$#" -gt 0 ]; then
    "$BB" tar -czf "$R/nomount-before.tar.gz" -C /data/adb "$@"
    chmod 644 "$R/nomount-before.tar.gz"
    echo BACKUP_CREATED=nomount-before.tar.gz
fi
echo PREFLIGHT_OK
'@
        $NpConfigure = @'
#!/system/bin/sh
# NP03J_NOMOUNT_CONFIGURE
set -eu
R=$1
D=/data/adb/nomount
stop() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || stop ROOT_REQUIRED
[ ! -f "$D/disable" ] || stop NOMOUNT_SAFE_MODE_SET
mkdir -p "$D"
cp "$R/exclusions-normalized.json" "$D/.exclusion_list.json"
chown 0:0 "$D" "$D/.exclusion_list.json"
chmod 700 "$D"
chmod 600 "$D/.exclusion_list.json"
expected=$(cat "$R/isolated-before")
if [ "$expected" = 1 ]; then
    [ -f "$D/.block_isolated_uids" ] || stop ISOLATED_SETTING_CHANGED
else
    [ ! -f "$D/.block_isolated_uids" ] || stop ISOLATED_SETTING_CHANGED
fi
/data/adb/ksud module enable nomount
echo CONFIGURATION_SAVED
'@
        $NpVerify = @'
#!/system/bin/sh
# NP03J_NOMOUNT_VERIFY
set -eu
R=$1
PIN=$2
D=/data/adb/nomount
M=/data/adb/modules/nomount
NM="$M/bin/nm"
K=/data/adb/ksud
stop() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || stop ROOT_REQUIRED_AFTER_REBOOT
before=$(cat "$R/boot-before")
after=$(cat /proc/sys/kernel/random/boot_id)
[ "$before" != "$after" ] || stop REBOOT_NOT_CONFIRMED
echo "BOOT_ID_BEFORE=$before"
echo "BOOT_ID_AFTER=$after"
[ -x "$NM" ] || stop NOMOUNT_CLI_MISSING
[ "$(cat "$M/NOMOUNT_SOURCE_COMMIT")" = "$PIN" ] || stop INSTALLED_SOURCE_MISMATCH
grep -qx 'id=nomount' "$M/module.prop" || stop MODULE_ID_MISMATCH
grep -qx 'metamodule=true' "$M/module.prop" || stop METAMODULE_FLAG_MISSING
grep -qx 'version=v2.1.1' "$M/module.prop" || stop MODULE_VERSION_MISMATCH
for mark in disable remove update; do
    [ ! -f "$M/$mark" ] || stop "MODULE_MARKER=$mark"
done
[ ! -f "$D/disable" ] || stop NOMOUNT_SELF_DISABLED
[ "$(readlink -f /data/adb/metamodule)" = "$M" ] || stop METAMODULE_REGISTRATION_MISMATCH
[ "$(readlink -f /data/adb/ksu/bin/nm)" = "$NM" ] || stop CLI_LINK_MISMATCH
"$K" module metamodule
"$NM" version
if grep -q '^nomount ' /proc/modules; then stop UNEXPECTED_NOMOUNT_LKM; fi
n=0
while [ "$n" -lt 90 ]; do
    if [ -f "$D/disable" ]; then stop NOMOUNT_SELF_DISABLED; fi
    if [ -s "$D/nomount.log" ] &&
       grep -qF '[OK] Kernel API ready (post-fs-data).' "$D/nomount.log" &&
       grep -qF '=== Injection Complete:' "$D/nomount.log" &&
       grep -qF '[OK] Boot completed safely.' "$D/nomount.log" &&
       [ ! -f "$D/.booting" ]; then break; fi
    n=$((n + 1))
    sleep 1
done
[ "$n" -lt 90 ] || { tail -n 100 "$D/nomount.log" 2>/dev/null || :; stop BOOT_STAGES_NOT_CONFIRMED; }
if grep -Eq '\[(FATAL|ERROR|WARN)\]' "$D/nomount.log"; then
    tail -n 100 "$D/nomount.log"
    stop NOMOUNT_LOG_REQUIRES_REVIEW
fi
old=$(cat "$R/log-before.sha")
new=$(sha256sum "$D/nomount.log" | cut -d' ' -f1)
[ "$new" != "$old" ] || stop STALE_BOOT_LOG
expected=$(cat "$R/isolated-before")
actual=$("$NM" uid block_isolated)
[ "$actual" = "$expected" ] || stop ISOLATED_SETTING_NOT_RESTORED
echo "ISOLATED_PROCESS_EXCLUSION=$actual"
echo BOOT_STAGES_VERIFIED

# Verify one actual VFS redirection; remove only our own rule and files.
P="$R/probe"
[ ! -e "$P" ] || stop PROBE_PATH_ALREADY_EXISTS
mkdir "$P"
chmod 700 "$P"
printf 'NP03J_ORIGINAL\n' > "$P/virtual.txt"
printf 'NP03J_REDIRECTED\n' > "$P/real.txt"
active=0
cleanup() {
    if [ "$active" = 1 ]; then "$NM" rule del "$P/virtual.txt" >/dev/null 2>&1 || return 1; fi
    rm -f "$P/virtual.txt" "$P/real.txt"
    rmdir "$P"
}
trap cleanup EXIT
active=1
"$NM" rule add "$P/virtual.txt" "$P/real.txt" || stop REDIRECTION_ADD_FAILED
[ "$(cat "$P/virtual.txt")" = NP03J_REDIRECTED ] || stop REDIRECTED_READ_FAILED
"$NM" rule del "$P/virtual.txt" || stop REDIRECTION_REMOVE_FAILED
active=0
[ "$(cat "$P/virtual.txt")" = NP03J_ORIGINAL ] || stop ORIGINAL_READ_NOT_RESTORED
cleanup
trap - EXIT
echo REAL_VFS_REDIRECTION_VERIFIED
echo ORIGINAL_FILE_VIEW_RESTORED
echo NOMOUNT_POST_REBOOT_CHECKS_PASSED
'@
        return [ordered]@{ 'preflight.sh' = $NpPreflight; 'configure.sh' = $NpConfigure; 'verify.sh' = $NpVerify }
    }

    if (!(Test-Path -LiteralPath $NpAdb -PathType Leaf)) { throw 'STOP: ADB_MISSING' }
    if ((Invoke-NpAdb @('get-state')) -ne 'device') { throw 'STOP: ANDROID_NOT_CONNECTED' }
    Assert-NpDevice
    New-Item -ItemType Directory -Path $NpWork | Out-Null
    $NpZipPath = Join-Path $NpWork 'NoMount-NP03J-Builtin.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $NpZipUrl -OutFile $NpZipPath
    if ((Get-FileHash -LiteralPath $NpZipPath -Algorithm SHA256).Hash -ne $NpExpectedZip) { throw 'STOP: MODULE_ZIP_HASH_MISMATCH' }
    Write-Host "VERIFIED=$NpZipPath"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $NpZip = [IO.Compression.ZipFile]::OpenRead($NpZipPath)
    try {
        if (@($NpZip.Entries | Where-Object { $_.FullName -match '(^|/)lkm/|[.]ko$' }).Count -ne 0) { throw 'STOP: UNEXPECTED_KERNEL_MODULE_PAYLOAD' }
        foreach ($NpName in @('NOMOUNT_SOURCE_COMMIT', 'module.prop', 'bin/nm-arm64')) {
            $NpEntries = @($NpZip.Entries | Where-Object { $_.FullName -ceq $NpName })
            if ($NpEntries.Count -ne 1) { throw "STOP: ZIP_ENTRY_MISMATCH: $NpName" }
            $NpTarget = if ($NpName -eq 'bin/nm-arm64') { Join-Path $NpWork 'nm' } else { Join-Path $NpWork $NpName }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($NpEntries[0], $NpTarget, $false)
        }
    } finally { $NpZip.Dispose() }
    if ((Get-Content -Raw -LiteralPath (Join-Path $NpWork 'NOMOUNT_SOURCE_COMMIT')).Trim() -cne $NpPin) { throw 'STOP: MODULE_SOURCE_MISMATCH' }
    $NpProps = Get-Content -Raw -LiteralPath (Join-Path $NpWork 'module.prop')
    if ($NpProps -notmatch '(?m)^id=nomount\r?$' -or $NpProps -notmatch '(?m)^metamodule=true\r?$' -or $NpProps -notmatch '(?m)^version=v2[.]1[.]1\r?$') { throw 'STOP: MODULE_METADATA_MISMATCH' }
    $NpElf = [IO.File]::ReadAllBytes((Join-Path $NpWork 'nm'))
    if ($NpElf.Length -lt 64 -or [BitConverter]::ToUInt32($NpElf, 0) -ne 0x464c457f -or $NpElf[4] -ne 2 -or $NpElf[5] -ne 1 -or [BitConverter]::ToUInt16($NpElf, 18) -ne 183) { throw 'STOP: CLI_NOT_ARM64_ELF' }

    $NpScripts = Get-NpNoMountScripts
    foreach ($NpName in $NpScripts.Keys) {
        [IO.File]::WriteAllText((Join-Path $NpWork $NpName), ($NpScripts[$NpName].Replace([string][char]13, '') + [char]10), [Text.Encoding]::ASCII)
    }
    Write-Host (Invoke-NpAdb @('shell', "mkdir -m 700 $NpRemote"))
    foreach ($NpName in @('NoMount-NP03J-Builtin.zip', 'nm', 'preflight.sh', 'configure.sh', 'verify.sh')) {
        $NpLocal = Join-Path $NpWork $NpName
        Write-Host (Invoke-NpAdb @('push', $NpLocal, "$NpRemote/$NpName"))
        $NpTransferred = Invoke-NpAdb @('shell', "sha256sum $NpRemote/$NpName")
        if (($NpTransferred -split '\s+')[0] -ne (Get-FileHash -LiteralPath $NpLocal -Algorithm SHA256).Hash) { throw "STOP: TRANSFER_HASH_MISMATCH: $NpName" }
    }

    Write-Host '=== ROOT AND CONFLICT CHECKS ==='
    $NpPreflightResult = Invoke-NpRoot "sh $NpRemote/preflight.sh $NpRemote $NpPin"
    Write-Host $NpPreflightResult
    [IO.File]::WriteAllText((Join-Path $NpWork 'preflight.log'), $NpPreflightResult, [Text.UTF8Encoding]::new($false))
    if ($NpPreflightResult -notmatch '(?m)^PREFLIGHT_OK$') { throw 'STOP: PREFLIGHT_INCOMPLETE' }
    if ($NpPreflightResult -match 'BACKUP_CREATED=nomount-before.tar.gz') {
        Write-Host (Invoke-NpAdb @('pull', "$NpRemote/nomount-before.tar.gz", (Join-Path $NpWork 'nomount-before.tar.gz')))
    }
    $NpExclusionText = Invoke-NpRoot "cat $NpRemote/exclusions-before.json"
    $NpExclusions = Get-NpExclusions $NpExclusionText
    $NpExpectedUids = @($NpExclusions | ForEach-Object { [uint32]$_.uid } | Sort-Object -Unique)
    $NpNormalized = ConvertTo-Json -InputObject @($NpExclusions) -Compress -Depth 20
    $NpExclusionPath = Join-Path $NpWork 'exclusions-normalized.json'
    [IO.File]::WriteAllText($NpExclusionPath, $NpNormalized, [Text.UTF8Encoding]::new($false))
    Write-Host (Invoke-NpAdb @('push', $NpExclusionPath, "$NpRemote/exclusions-normalized.json"))
    $NpTransferred = Invoke-NpAdb @('shell', "sha256sum $NpRemote/exclusions-normalized.json")
    if (($NpTransferred -split '\s+')[0] -ne (Get-FileHash -LiteralPath $NpExclusionPath -Algorithm SHA256).Hash) { throw 'STOP: CONFIG_TRANSFER_HASH_MISMATCH' }
    [IO.File]::WriteAllText((Join-Path $NpWork 'modules-before.json'), (Invoke-NpRoot "cat $NpRemote/modules-before.json"), [Text.UTF8Encoding]::new($false))
    Write-Host "WORK_DIR=$NpWork"
    Write-Host '=== INSTALL BUILT-IN NOMOUNT METAMODULE ==='
    $NpInstall = Invoke-NpRoot "/data/adb/ksud module install $NpRemote/NoMount-NP03J-Builtin.zip"
    Write-Host $NpInstall
    [IO.File]::WriteAllText((Join-Path $NpWork 'install.log'), $NpInstall, [Text.UTF8Encoding]::new($false))
    if ($NpInstall -notmatch 'Module installed successfully!' -or $NpInstall -match '(?im)^\s*(?:\[WARN(?:ING)?\]|\[FATAL\]|! preinit)') { throw 'STOP: MODULE_INSTALL_REQUIRES_REVIEW' }
    Write-Host (Invoke-NpRoot "sh $NpRemote/configure.sh $NpRemote")

    Write-Host '=== REBOOT AND VERIFY ==='
    Write-Host (Invoke-NpAdb @('reboot'))
    $NpDeadline = (Get-Date).AddSeconds(360)
    $NpBooted = $false
    while ((Get-Date) -lt $NpDeadline) {
        $NpState = Invoke-NpAdb -NpArguments @('get-state') -NpSoft
        if ($NpState.Exit -eq 0 -and $NpState.Text -eq 'device') {
            $NpBoot = Invoke-NpAdb -NpArguments @('shell', 'getprop sys.boot_completed') -NpSoft
            if ($NpBoot.Exit -eq 0 -and $NpBoot.Text -eq '1') { $NpBooted = $true; break }
        }
        Start-Sleep -Seconds 2
    }
    if (!$NpBooted) { throw 'STOP: ANDROID_BOOT_TIMEOUT' }
    Assert-NpDevice
    $NpVerification = Invoke-NpRoot "sh $NpRemote/verify.sh $NpRemote $NpPin"
    Write-Host $NpVerification
    [IO.File]::WriteAllText((Join-Path $NpWork 'verification.log'), $NpVerification, [Text.UTF8Encoding]::new($false))
    if ($NpVerification -notmatch '(?m)^NOMOUNT_POST_REBOOT_CHECKS_PASSED$') { throw 'STOP: POST_REBOOT_CHECKS_INCOMPLETE' }
    $NpActualUidsJson = Invoke-NpRoot '/data/adb/modules/nomount/bin/nm uid list'
    $NpActualUids = @($NpActualUidsJson | ConvertFrom-Json)
    foreach ($NpUid in $NpExpectedUids) {
        if ($NpActualUids -notcontains $NpUid) { throw "STOP: PERSISTENT_UID_NOT_RESTORED: $NpUid" }
    }
    $NpRulesJson = Invoke-NpRoot '/data/adb/modules/nomount/bin/nm rule list --json'
    $NpRules = @($NpRulesJson | ConvertFrom-Json)
    $NpModulesJson = Invoke-NpRoot '/data/adb/ksud module list'
    $NpModules = @($NpModulesJson | ConvertFrom-Json)
    $NpInstalled = @($NpModules | Where-Object { $_.id -ceq 'nomount' })
    if ($NpInstalled.Count -ne 1 -or $NpInstalled[0].enabled -cne 'true' -or $NpInstalled[0].remove -cne 'false' -or $NpInstalled[0].update -cne 'false') { throw 'STOP: MANAGER_MODULE_STATE_MISMATCH' }
    [IO.File]::WriteAllText((Join-Path $NpWork 'active-rules.json'), $NpRulesJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $NpWork 'active-uids.json'), $NpActualUidsJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $NpWork 'modules-after.json'), $NpModulesJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $NpWork 'nomount-boot.log'), (Invoke-NpRoot 'cat /data/adb/nomount/nomount.log'), [Text.UTF8Encoding]::new($false))
    Write-Host "ACTIVE_RULES=$($NpRules.Count)"
    Write-Host "EXCLUDED_UIDS=$($NpActualUids.Count)"
    Write-Host "PERSISTENT_UIDS_VERIFIED=$($NpExpectedUids.Count)"
    Write-Host "REPORT_DIR=$NpWork"
    Write-Host 'NOMOUNT_INSTALLED_ENABLED_AND_VERIFIED_AFTER_REBOOT'
}
