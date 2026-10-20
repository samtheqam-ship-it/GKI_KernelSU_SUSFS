#Requires -Version 5.1
# Fixed NP03J trust correction: verifies files, repacks stock boot, flashes boot_a in fastbootd.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $NpAdb = 'E:\platform-tools\adb.exe'
    $NpFastboot = 'E:\platform-tools\fastboot.exe'
    $NpSerial = 'PDNP03J000070074'
    $NpTag = 'np03j-6.1.177-r2-a1'
    $NpCommit = '06332cb86ced82735d4d9c7d86d5f26ec35bda38'
    $NpPackage = 'whdcxypn.tnrhybhl.intqycyv'
    $NpCertHash = '10a14f46738605bb3d87aadd16b1c3287b7c136eda63a499315d75ae1e0983d7'
    $NpStock = 'E:\11.0.6NP03J_EU\01_BOOTCHAIN\boot_a.img'
    $NpStockHash = 'ba131890119fa311dcef5de44e32eb3b1eecd57c1438e3c3d314d79a07ba5490'
    $NpStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $NpWork = "E:\11.0.6NP03J_EU\06_ROOT\trustfix_$NpStamp"
    $NpRemote = "/data/local/tmp/np03j_trustfix_$NpStamp"

    function Invoke-NpTool {
        param([string]$NpExe, [string[]]$NpArguments, [switch]$NpSoft)
        $ErrorActionPreference = 'Continue'
        $NpOutput = @(& $NpExe @NpArguments 2>&1 | ForEach-Object { "$_" })
        $NpExit = $LASTEXITCODE
        $NpText = ($NpOutput -join [Environment]::NewLine).Trim()
        if ($NpSoft) { return [pscustomobject]@{ Exit = $NpExit; Text = $NpText } }
        if ($NpExit -ne 0) { throw ("STOP: COMMAND_FAILED: $NpExe " + ($NpArguments -join ' ') + [Environment]::NewLine + $NpText) }
        return $NpText
    }
    function Invoke-NpAdb {
        param([string[]]$NpArguments, [switch]$NpSoft)
        Invoke-NpTool $NpAdb (@('-s', $NpSerial) + $NpArguments) -NpSoft:$NpSoft
    }
    function Invoke-NpFastboot {
        param([string[]]$NpArguments)
        Invoke-NpTool $NpFastboot (@('-s', $NpSerial) + $NpArguments)
    }
    function Assert-NpFastbootState {
        $NpChecks = @{
            'is-userspace' = 'yes'
            'product' = 'PQ83P01'
            'current-slot' = 'a'
            'unlocked' = 'yes'
            'partition-size:boot_a' = '0x0*6000000'
        }
        foreach ($NpKey in $NpChecks.Keys) {
            $NpValue = Invoke-NpFastboot @('getvar', $NpKey)
            Write-Host $NpValue
            $NpPattern = '(?im)^\s*(?:\(bootloader\)\s*)?' + [regex]::Escape($NpKey) + ':\s*' + $NpChecks[$NpKey] + '\s*$'
            if ($NpValue -notmatch $NpPattern) { throw "STOP: FASTBOOTD_CHECK_FAILED: $NpKey" }
        }
    }
    function Assert-NpHash {
        param([string]$NpPath, [string]$NpExpected)
        if (!(Test-Path -LiteralPath $NpPath -PathType Leaf)) { throw "STOP: FILE_MISSING: $NpPath" }
        if ((Get-FileHash -LiteralPath $NpPath -Algorithm SHA256).Hash -ne $NpExpected) { throw "STOP: HASH_MISMATCH: $NpPath" }
        Write-Host "VERIFIED=$NpPath"
    }
    if (!(Test-Path -LiteralPath $NpAdb -PathType Leaf)) { throw 'STOP: ADB_MISSING' }
    if (!(Test-Path -LiteralPath $NpFastboot -PathType Leaf)) { throw 'STOP: FASTBOOT_MISSING' }
    Assert-NpHash $NpStock $NpStockHash
    if ((Invoke-NpAdb @('get-state')) -ne 'device') { throw 'STOP: ANDROID_NOT_CONNECTED' }
    if ((Invoke-NpAdb @('shell', 'getprop ro.product.model')) -ne 'NP03J') { throw 'STOP: MODEL_MISMATCH' }
    if ((Invoke-NpAdb @('shell', 'getprop ro.build.version.incremental')) -ne '20260603.025850') { throw 'STOP: ROM_CHANGED' }
    if ((Invoke-NpAdb @('shell', 'getprop ro.boot.slot_suffix')) -ne '_a') { throw 'STOP: SLOT_CHANGED' }
    if ((Invoke-NpAdb @('shell', 'getprop ro.boot.flash.locked')) -ne '0') { throw 'STOP: BOOTLOADER_LOCKED' }
    if ((Invoke-NpAdb @('shell', 'getconf PAGESIZE')) -ne '4096') { throw 'STOP: PAGE_SIZE_CHANGED' }
    New-Item -ItemType Directory -Path $NpWork | Out-Null

    $NpRelease = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'NP03J-TrustFix' } -Uri "https://api.github.com/repos/samtheqam-ship-it/GKI_KernelSU_SUSFS/releases/tags/$NpTag"
    if ($NpRelease.draft -or $NpRelease.prerelease -or $NpRelease.target_commitish -ne $NpCommit) { throw 'STOP: WRONG_RELEASE' }
    $NpNames = @('NP03J-6.1.177-LTS-4K-AnyKernel3.zip', 'NP03J-Manager-Spoofed.apk', 'manager-identity.json', 'kernel-metadata.json', 'manager-cert.der')
    foreach ($NpName in $NpNames) {
        $NpAsset = @($NpRelease.assets | Where-Object { $_.name -ceq $NpName })
        if ($NpAsset.Count -ne 1 -or $NpAsset[0].digest -notmatch '^sha256:([0-9a-f]{64})$') { throw "STOP: INVALID_ASSET: $NpName" }
        $NpHash = $NpAsset[0].digest.Substring(7)
        $NpDestination = Join-Path $NpWork $NpName
        Invoke-WebRequest -UseBasicParsing -Uri $NpAsset[0].browser_download_url -OutFile $NpDestination
        Assert-NpHash $NpDestination $NpHash
    }

    $NpIdentity = Get-Content -Raw -LiteralPath (Join-Path $NpWork 'manager-identity.json') | ConvertFrom-Json
    $NpMeta = Get-Content -Raw -LiteralPath (Join-Path $NpWork 'kernel-metadata.json') | ConvertFrom-Json
    if ($NpIdentity.package -cne $NpPackage -or $NpIdentity.certificate_size -ne 730 -or $NpIdentity.certificate_sha256 -cne $NpCertHash) { throw 'STOP: SIGNING_IDENTITY_CHANGED' }
    if ($NpMeta.kmi -cne '6.1-android14-11' -or $NpMeta.page_size -ne 4096 -or $NpMeta.kernel_release -cne '6.1.177-android14-11') { throw 'STOP: KERNEL_PROFILE_CHANGED' }
    if ($NpIdentity.version_code -ne $NpMeta.manager_version_code -or $NpMeta.manager_certificate_sha256 -cne $NpCertHash -or $NpMeta.manager_package -cne $NpPackage -or $NpIdentity.uapi_version -ne $NpMeta.uapi_version) { throw 'STOP: MANAGER_KERNEL_PAIR_MISMATCH' }
    Assert-NpHash (Join-Path $NpWork 'manager-cert.der') $NpCertHash
    Assert-NpHash (Join-Path $NpWork 'NP03J-Manager-Spoofed.apk') $NpIdentity.apk_sha256

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $NpZip = [IO.Compression.ZipFile]::OpenRead((Join-Path $NpWork 'NP03J-6.1.177-LTS-4K-AnyKernel3.zip'))
    try {
        foreach ($NpEntryName in @('Image', 'tools/magiskboot')) {
            $NpEntries = @($NpZip.Entries | Where-Object { $_.FullName -ceq $NpEntryName })
            if ($NpEntries.Count -ne 1) { throw "STOP: ZIP_ENTRY_INVALID: $NpEntryName" }
            $NpTarget = Join-Path $NpWork ([IO.Path]::GetFileName($NpEntryName))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($NpEntries[0], $NpTarget, $false)
        }
    } finally { $NpZip.Dispose() }

    $NpImagePath = Join-Path $NpWork 'Image'
    Assert-NpHash $NpImagePath $NpMeta.image_sha256
    $NpImageBytes = [IO.File]::ReadAllBytes($NpImagePath)
    if ($NpImageBytes.Length -le 4096 -or [BitConverter]::ToUInt32($NpImageBytes, 56) -ne 0x644D5241) { throw 'STOP: INVALID_ARM64_IMAGE' }
    if ((([BitConverter]::ToUInt64($NpImageBytes, 24) -shr 1) -band 3) -ne 1) { throw 'STOP: IMAGE_NOT_4K' }
    $NpTrust = '0x2da:' + $NpCertHash + [char]0
    if ([Text.Encoding]::ASCII.GetString($NpImageBytes).IndexOf($NpTrust, [StringComparison]::Ordinal) -lt 0) { throw 'STOP: CORRECT_TRUST_ENTRY_MISSING' }
    Write-Host 'EXACT_MANAGER_TRUST_VERIFIED=0x2da:730_bytes'
    Copy-Item -LiteralPath $NpStock -Destination (Join-Path $NpWork 'boot_a.stock.img')
    Assert-NpHash (Join-Path $NpWork 'boot_a.stock.img') $NpStockHash

    $NpPrepare = @'
#!/system/bin/sh
set -eu
cd "$1"
chmod 700 magiskboot
mkdir stock patched verify
cd stock
../magiskboot unpack ../boot_a.stock.img
cd ..
cp -R stock/. patched/
cp Image patched/kernel
cd patched
../magiskboot repack ../boot_a.stock.img ../boot_a.fixed.img
cd ../verify
../magiskboot unpack ../boot_a.fixed.img
cmp kernel ../Image
for f in ../stock/*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    [ "$n" = kernel ] || cmp "$f" "$n"
done
echo REPACK_COMPONENTS_VERIFIED
'@
    [IO.File]::WriteAllText((Join-Path $NpWork 'prepare.sh'), ($NpPrepare.Replace([string][char]13, '') + [char]10), [Text.Encoding]::ASCII)
    Write-Host (Invoke-NpAdb @('shell', "mkdir '$NpRemote'"))
    foreach ($NpName in @('boot_a.stock.img', 'Image', 'magiskboot', 'prepare.sh')) {
        Write-Host (Invoke-NpAdb @('push', (Join-Path $NpWork $NpName), "$NpRemote/$NpName"))
    }
    foreach ($NpName in @('boot_a.stock.img', 'Image', 'magiskboot', 'prepare.sh')) {
        $NpExpected = (Get-FileHash -LiteralPath (Join-Path $NpWork $NpName) -Algorithm SHA256).Hash
        $NpTransferred = Invoke-NpAdb @('shell', "sha256sum '$NpRemote/$NpName'")
        if (($NpTransferred -split '\s+')[0] -ne $NpExpected) { throw "STOP: PUSH_HASH_MISMATCH: $NpName" }
    }
    Write-Host (Invoke-NpAdb @('shell', "sh '$NpRemote/prepare.sh' '$NpRemote'"))
    $NpReady = Join-Path $NpWork 'boot_a.fixed.img'
    Write-Host (Invoke-NpAdb @('pull', "$NpRemote/boot_a.fixed.img", $NpReady))
    $NpRemoteHash = Invoke-NpAdb @('shell', "sha256sum '$NpRemote/boot_a.fixed.img'")
    $NpReadyHash = (Get-FileHash -LiteralPath $NpReady -Algorithm SHA256).Hash
    if (($NpRemoteHash -split '\s+')[0] -ne $NpReadyHash) { throw 'STOP: TRANSFER_HASH_MISMATCH' }

    $NpOldBoot = [IO.File]::ReadAllBytes($NpStock)
    $NpNewBoot = [IO.File]::ReadAllBytes($NpReady)
    if ($NpNewBoot.Length -ne 100663296 -or $NpNewBoot.Length -ne $NpOldBoot.Length) { throw 'STOP: BOOT_SIZE_CHANGED' }
    if ([Text.Encoding]::ASCII.GetString($NpNewBoot, 0, 8) -cne 'ANDROID!' -or [BitConverter]::ToUInt32($NpNewBoot, 40) -ne 4) { throw 'STOP: BOOT_HEADER_INVALID' }
    $NpHeaderSize = [BitConverter]::ToUInt32($NpOldBoot, 20)
    if ($NpHeaderSize -ne 1584) { throw 'STOP: STOCK_HEADER_CHANGED' }
    for ($NpIndex = 0; $NpIndex -lt $NpHeaderSize; $NpIndex++) {
        if ($NpIndex -ge 8 -and $NpIndex -le 11) { continue }
        if ($NpOldBoot[$NpIndex] -ne $NpNewBoot[$NpIndex]) { throw "STOP: HEADER_METADATA_CHANGED_AT_$NpIndex" }
    }
    Write-Host "WORK_DIR=$NpWork"
    Write-Host "READY_IMAGE=$NpReady"
    Write-Host "READY_SHA256=$NpReadyHash"
    Write-Host "READY_BYTES=$($NpNewBoot.Length)"
    Write-Host 'BOOT_METADATA_PRESERVED'
    Write-Host 'CORRECTED_IMAGE_READY'

    Write-Host '=== INSTALL MATCHING MANAGER ==='
    Write-Host (Invoke-NpAdb @('install', '-r', (Join-Path $NpWork 'NP03J-Manager-Spoofed.apk')))
    Write-Host '=== ENTER USERSPACE FASTBOOT ==='
    Write-Host (Invoke-NpAdb @('reboot', 'fastboot'))
    $NpDeadline = (Get-Date).AddSeconds(180)
    $NpFound = $false
    while ((Get-Date) -lt $NpDeadline) {
        $NpDevices = Invoke-NpFastboot @('devices')
        if ($NpDevices -match ('(?m)^' + [regex]::Escape($NpSerial) + '\s+fastboot(?:\s|$)')) { $NpFound = $true; break }
        Start-Sleep -Seconds 2
    }
    if (!$NpFound) { throw 'STOP: FASTBOOTD_CONNECTION_TIMEOUT' }
    Assert-NpFastbootState

    Assert-NpHash $NpReady $NpReadyHash
    Write-Host '=== FLASH VERIFIED CORRECTED BOOT_A ==='
    Write-Host (Invoke-NpFastboot @('flash', 'boot_a', $NpReady))
    Write-Host 'BOOT_A_FLASH_SUCCEEDED'
    Write-Host (Invoke-NpFastboot @('reboot'))

    Write-Host '=== WAIT FOR ANDROID ==='
    $NpDeadline = (Get-Date).AddSeconds(360)
    $NpBooted = $false
    while ((Get-Date) -lt $NpDeadline) {
        $NpState = Invoke-NpAdb -NpArguments @('get-state') -NpSoft
        if ($NpState.Exit -eq 0 -and $NpState.Text -eq 'device') {
            $NpCompleted = Invoke-NpAdb -NpArguments @('shell', 'getprop sys.boot_completed') -NpSoft
            if ($NpCompleted.Exit -eq 0 -and $NpCompleted.Text -eq '1') { $NpBooted = $true; break }
        }
        Start-Sleep -Seconds 2
    }
    if (!$NpBooted) { throw 'STOP: ANDROID_BOOT_TIMEOUT' }
    $NpKernelNow = Invoke-NpAdb @('shell', 'uname -r')
    $NpSlotNow = Invoke-NpAdb @('shell', 'getprop ro.boot.slot_suffix')
    $NpPagesNow = Invoke-NpAdb @('shell', 'getconf PAGESIZE')
    $NpSelinuxNow = Invoke-NpAdb @('shell', 'getenforce')
    Write-Host "KERNEL=$NpKernelNow"
    Write-Host "SLOT=$NpSlotNow"
    Write-Host "PAGE_SIZE=$NpPagesNow"
    Write-Host "SELINUX=$NpSelinuxNow"
    if ($NpKernelNow -cne $NpMeta.kernel_release -or $NpSlotNow -ne '_a' -or $NpPagesNow -ne '4096' -or $NpSelinuxNow -cne 'Enforcing') { throw 'STOP: POST_BOOT_STATE_MISMATCH' }
    Write-Host (Invoke-NpAdb @('shell', "am force-stop --user 0 $NpPackage"))
    $NpLaunch = Invoke-NpAdb @('shell', "am start -W --user 0 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $NpPackage/.ui.MainActivity")
    Write-Host $NpLaunch
    if ($NpLaunch -notmatch '(?m)^Status:\s*ok\s*$') { throw 'STOP: MANAGER_LAUNCH_FAILED' }
    Write-Host 'CORRECTED_BOOT_FLASHED_AND_MANAGER_OPENED'
}