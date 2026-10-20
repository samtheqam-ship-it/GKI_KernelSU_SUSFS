#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$NpRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$NpInstaller = Join-Path $NpRoot 'tools/Update-NP03JTrust.ps1'
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
Assert-NpTest ($NpFunctions.Count -eq 5) 'installer parses and exposes only the expected helpers'

$NpPython = (Get-Command python3).Source
$NpNative = Invoke-NpTool -NpExe $NpPython -NpArguments @('-c', "import sys; print('native-out'); print('native-err', file=sys.stderr)")
Assert-NpTest ($NpNative -match 'native-out' -and $NpNative -match 'native-err') 'successful native stderr does not abort under Stop'
Assert-NpStops { Invoke-NpTool -NpExe $NpPython -NpArguments @('-c', 'import sys; sys.exit(7)') } 'native failure stops the installer'
$NpSoft = Invoke-NpTool -NpExe $NpPython -NpArguments @('-c', 'import sys; sys.exit(7)') -NpSoft
Assert-NpTest ($NpSoft.Exit -eq 7) 'polling preserves native failure status'

$NpSerial = 'PDNP03J000070074'
$NpAdb = (Get-Command echo -CommandType Application | Select-Object -First 1).Source
$NpFastboot = $NpAdb
Assert-NpTest ((Invoke-NpAdb @('shell', 'getprop test')) -eq '-s PDNP03J000070074 shell getprop test') 'adb wrapper preserves serial and argument array'
Assert-NpTest ((Invoke-NpFastboot @('getvar', 'is-userspace')) -eq '-s PDNP03J000070074 getvar is-userspace') 'fastboot wrapper preserves serial and argument array'

$NpTemporary = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($NpTemporary, 'fixture')
    Assert-NpHash $NpTemporary (Get-FileHash -LiteralPath $NpTemporary -Algorithm SHA256).Hash
    Assert-NpTest $true 'matching file hash passes'
    Assert-NpStops { Assert-NpHash $NpTemporary ('0' * 64) } 'wrong file hash stops'
    Assert-NpStops { Assert-NpHash ($NpTemporary + '.missing') ('0' * 64) } 'missing file stops'
} finally { Remove-Item -LiteralPath $NpTemporary -Force }

$NpGood = @{ 'is-userspace' = 'yes'; 'product' = 'PQ83P01'; 'current-slot' = 'a'; 'unlocked' = 'yes'; 'partition-size:boot_a' = '0x6000000' }
$script:NpFake = $NpGood.Clone()
function Invoke-NpFastboot {
    param([string[]]$NpArguments)
    if ($NpArguments.Count -ne 2 -or $NpArguments[0] -ne 'getvar') { throw 'A read-only guard attempted a non-getvar command' }
    return ('(bootloader) ' + $NpArguments[1] + ': ' + $script:NpFake[$NpArguments[1]] + [Environment]::NewLine + 'Finished. Total time: 0.001s')
}
Assert-NpFastbootState
Assert-NpTest $true 'correct device in userspace fastboot passes'
foreach ($NpCase in @(
    @('is-userspace', 'no'),
    @('product', 'another-device'),
    @('current-slot', 'b'),
    @('unlocked', 'no'),
    @('partition-size:boot_a', '0x4000000')
)) {
    $script:NpFake = $NpGood.Clone()
    $script:NpFake[$NpCase[0]] = $NpCase[1]
    Assert-NpStops { Assert-NpFastbootState } ('wrong ' + $NpCase[0] + ' stops before flashing')
}

$NpSource = [IO.File]::ReadAllText($NpInstaller)
$NpFlash = "@('flash', 'boot_a', " + '$NpReady)'
Assert-NpTest (($NpSource.Split($NpFlash, [StringSplitOptions]::None)).Length -eq 2) 'only one flash command targets boot_a'
Assert-NpTest ($NpSource.LastIndexOf('    Assert-NpFastbootState') -lt $NpSource.IndexOf($NpFlash)) 'userspace and device guards precede flash'
Assert-NpTest ($NpSource.LastIndexOf('    Assert-NpHash $NpReady $NpReadyHash') -lt $NpSource.IndexOf($NpFlash)) 'final image hash check precedes flash'
Assert-NpTest ($NpSource -notmatch "'flash', 'boot_b'|--disable-verity|--disable-verification|--force") 'no second slot, verification bypass, or forced flashing'
Write-Host "INSTALLER_CHECKS_PASSED=$script:NpPassed"
Write-Host ("INSTALLER_SHA256=" + (Get-FileHash -LiteralPath $NpInstaller -Algorithm SHA256).Hash.ToLowerInvariant())
