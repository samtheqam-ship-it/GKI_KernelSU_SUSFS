#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$NpRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$NpInstaller = Join-Path $NpRoot 'tools/Install-NP03JNoMount.ps1'
$NpTokens = $null
$NpErrors = $null
$NpAst = [System.Management.Automation.Language.Parser]::ParseFile($NpInstaller, [ref]$NpTokens, [ref]$NpErrors)
if ($NpErrors.Count -ne 0) { throw ($NpErrors | Out-String) }
$script:NpPassed = 0
function Assert-NpTest {
    param([bool]$NpCondition, [string]$NpName)
    if (!$NpCondition) { throw "TEST_FAILED: $NpName" }
    $script:NpPassed++
    Write-Host "PASS=$NpName"
}
function Assert-NpStops {
    param([scriptblock]$NpBody, [string]$NpName)
    $NpStopped = $false
    try { & $NpBody | Out-Null } catch {
        if ($_.Exception.Message -notlike 'STOP:*') { throw }
        $NpStopped = $true
    }
    Assert-NpTest $NpStopped $NpName
}
$NpFunctions = $NpAst.FindAll({ param($NpNode) $NpNode -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($NpFunction in $NpFunctions) { . ([scriptblock]::Create($NpFunction.Extent.Text)) }
Assert-NpTest ($NpFunctions.Count -eq 5) 'PowerShell syntax and expected helpers'

$NpTemporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $NpTemporary | Out-Null
try {
    $NpSerial = 'PDNP03J000070074'
    $NpAdb = Join-Path $NpTemporary 'native.sh'
    $NpNativeSource = "#!/bin/sh" + [char]10 + "echo native-out" + [char]10 + "echo native-err >&2" + [char]10 + "exit 0" + [char]10
    [IO.File]::WriteAllText($NpAdb, $NpNativeSource)
    & chmod 755 $NpAdb
    $NpNative = Invoke-NpAdb @('shell', 'id')
    Assert-NpTest ($NpNative -match 'native-out' -and $NpNative -match 'native-err') 'native stderr is captured without aborting success'
    [IO.File]::WriteAllText($NpAdb, $NpNativeSource.Replace('exit 0', 'exit 7'))
    Assert-NpStops { Invoke-NpAdb @('shell', 'id') } 'native command failure stops'
    $NpSoft = Invoke-NpAdb -NpArguments @('get-state') -NpSoft
    Assert-NpTest ($NpSoft.Exit -eq 7) 'polling retains the real exit status'

    $NpScripts = Get-NpNoMountScripts
    Assert-NpTest ($NpScripts.Count -eq 3) 'three device scripts'
    foreach ($NpName in $NpScripts.Keys) {
        $NpPath = Join-Path $NpTemporary $NpName
        [IO.File]::WriteAllText($NpPath, $NpScripts[$NpName] + [char]10)
        & bash -n $NpPath
        Assert-NpTest ($LASTEXITCODE -eq 0) ("shell syntax: " + $NpName)
    }
    $NpVersionLine = ($NpScripts['preflight.sh'] -split [char]10 | Where-Object { $_ -match 'grep -qF.*uapi: 6' } | Select-Object -First 1)
    $NpVersionTool = Join-Path $NpTemporary 'ksud-version'
    $NpVersionCheck = Join-Path $NpTemporary 'check-version.sh'
    [IO.File]::WriteAllText($NpVersionCheck, ('K="$1"' + [char]10 + 'stop() { exit 1; }' + [char]10 + $NpVersionLine + [char]10))
    foreach ($NpCase in @(
        @('ksud 3.4.2-50-gb427a3f9 (uapi: 6)', 0),
        @('ksud 3.4.2-50-gb427a3f9 (uapi: 5)', 1),
        @('ksud 3.4.2-51-other (uapi: 6)', 1)
    )) {
        [IO.File]::WriteAllText($NpVersionTool, ('#!/bin/sh' + [char]10 + "echo '" + $NpCase[0] + "'" + [char]10))
        & chmod 755 $NpVersionTool
        & bash $NpVersionCheck $NpVersionTool
        Assert-NpTest ($LASTEXITCODE -eq $NpCase[1]) ('pinned ksud CLI format: ' + $NpCase[0])
    }
    $NpBefore = $NpScripts['preflight.sh']
    Assert-NpTest ($NpBefore.Contains('COMPETING_METAMODULE') -and $NpBefore.Contains('NOMOUNT_UPDATE_ALREADY_PENDING') -and $NpBefore.Contains('NOMOUNT_SAFE_MODE_ALREADY_SET')) 'conflicts and safe mode stop before install'
    $NpVerify = $NpScripts['verify.sh']
    Assert-NpTest ($NpVerify.Contains('REBOOT_NOT_CONFIRMED') -and $NpVerify.Contains('STALE_BOOT_LOG') -and $NpVerify.Contains('BOOT_STAGES_NOT_CONFIRMED')) 'verification requires a new boot and fresh completed boot stages'
    Assert-NpTest ($NpVerify.Contains('trap cleanup EXIT') -and $NpVerify.Contains('REDIRECTED_READ_FAILED') -and $NpVerify.Contains('ORIGINAL_READ_NOT_RESTORED')) 'real read verification includes scoped cleanup and restoration'
    Assert-NpTest (!$NpVerify.Contains('clear all') -and !$NpVerify.Contains('clear rules') -and !$NpVerify.Contains('rm -rf')) 'verification never flushes user rules or recursively deletes data'

    $NpEmpty = Get-NpExclusions '[]'
    Assert-NpTest ($NpEmpty.Count -eq 0) 'empty exclusion list'
    $NpOne = Get-NpExclusions '[{"uid":12345,"package":"example.app","name":"Example"}]'
    Assert-NpTest ($NpOne.Count -eq 1 -and $NpOne[0].uid -is [string] -and $NpOne[0].uid -eq '12345' -and $NpOne[0].package -eq 'example.app') 'UID normalization preserves other properties'
    $NpNormalized = ConvertTo-Json -InputObject @($NpOne) -Compress -Depth 20
    Assert-NpTest ($NpNormalized -match '"uid":"12345"' -and $NpNormalized.StartsWith('[')) 'normalized data matches the upstream service parser'
    foreach ($NpBad in @('{}', '[{}]', '[{"uid":"bad"}]', '[{"uid":0}]', '[{"uid":4294967296}]', '[{"uid":-1}]')) {
        Assert-NpStops { Get-NpExclusions $NpBad } ('bad exclusion stops: ' + $NpBad)
    }

    $NpUnicodeName = [string][char]0x0639 + [char]0x0632 + [char]0x0644
    $NpUnicodeJson = ConvertTo-Json -InputObject @([pscustomobject]@{ uid = 12345; name = $NpUnicodeName }) -Compress
    $NpUnicodeItems = Get-NpExclusions $NpUnicodeJson
    Assert-NpTest ($NpUnicodeItems[0].name -ceq $NpUnicodeName) 'Arabic exclusion names survive normalization'

    $NpSource = [IO.File]::ReadAllText($NpInstaller)
    Assert-NpTest ($NpSource.Contains('[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)')) 'native output uses explicit UTF-8 decoding'
    Assert-NpTest ($NpSource -notmatch 'fastboot|boot-patch|insmod|modprobe') 'installer has no partition writes or kernel-loader calls'
    Assert-NpTest ($NpSource.Contains('5ba9e1b2bbffab1238d5ca748759f9c301da91a18f1128007278cbf8a73b160c')) 'module is pinned to the paired release hash'
    Assert-NpTest ($NpSource.IndexOf('$NpPreflightResult =') -lt $NpSource.IndexOf('$NpInstall =')) 'preflight precedes installation'
    Assert-NpTest ($NpSource.IndexOf('$NpExpectedUids =') -lt $NpSource.IndexOf('$NpInstall =')) 'existing exclusion data is validated before installation'
    Assert-NpTest ($NpSource.IndexOf('sh $NpRemote/configure.sh') -lt $NpSource.IndexOf("Invoke-NpAdb @('reboot')")) 'persistent settings are saved before reboot'
    Assert-NpTest ($NpSource.Contains('PERSISTENT_UID_NOT_RESTORED') -and $NpSource.Contains('MANAGER_MODULE_STATE_MISMATCH')) 'post-boot verification checks persisted UIDs and manager state'
    Write-Host "NOMOUNT_INSTALLER_CHECKS_PASSED=$script:NpPassed"
    Write-Host ("NOMOUNT_INSTALLER_SHA256=" + (Get-FileHash -LiteralPath $NpInstaller -Algorithm SHA256).Hash.ToLowerInvariant())
} finally { Remove-Item -LiteralPath $NpTemporary -Recurse -Force }

# Expected negative native fixtures must not become the workflow exit status.
# Any failed assertion throws before reaching this line.
exit 0
