#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$NpRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$NpInstaller = Join-Path $NpRoot 'tools/Install-NP03JNoMount.ps1'
$NpTokens = $null
$NpErrors = $null
$NpAst = [System.Management.Automation.Language.Parser]::ParseFile($NpInstaller, [ref]$NpTokens, [ref]$NpErrors)
if ($NpErrors.Count -ne 0) { throw ($NpErrors | Out-String) }
$NpFunctions = $NpAst.FindAll({ param($NpNode) $NpNode -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($NpFunction in $NpFunctions) { . ([scriptblock]::Create($NpFunction.Extent.Text)) }
$script:NpPassed = 0
function Assert-NpArrayTest {
    param([bool]$NpCondition, [string]$NpName)
    if (!$NpCondition) { throw "TEST_FAILED: $NpName" }
    $script:NpPassed++
    Write-Host "PASS=$NpName"
}
function Assert-NpArrayRejects {
    param([scriptblock]$NpBody, [string]$NpName)
    $NpStopped = $false
    try { & $NpBody | Out-Null } catch { $NpStopped = $true }
    Assert-NpArrayTest $NpStopped $NpName
}
Write-Host ("POWERSHELL_VERSION=" + $PSVersionTable.PSVersion)
$NpEmpty = Get-NpExclusions '[]'
Assert-NpArrayTest ($NpEmpty -is [array] -and $NpEmpty.Count -eq 0) 'empty exclusion array contains no phantom UID'
Assert-NpArrayTest ((ConvertTo-Json -InputObject @($NpEmpty) -Compress) -ceq '[]') 'empty exclusions serialize as an array'
$NpSingle = Get-NpExclusions '[{"uid":12345,"name":"Example","package":"example.app"}]'
Assert-NpArrayTest ($NpSingle -is [array] -and $NpSingle.Count -eq 1 -and $NpSingle[0] -isnot [array]) 'singleton exclusion is not wrapped twice'
Assert-NpArrayTest ($NpSingle[0].uid -is [string] -and $NpSingle[0].uid -ceq '12345' -and $NpSingle[0].package -ceq 'example.app') 'UID normalization preserves metadata'
$NpSingleJson = ConvertTo-Json -InputObject @($NpSingle) -Compress -Depth 20
Assert-NpArrayTest ($NpSingleJson.StartsWith('[') -and $NpSingleJson.Contains('"uid":"12345"')) 'singleton remains compatible with upstream service'
$NpMany = Get-NpExclusions '[{"uid":"12345"},{"uid":12346}]'
Assert-NpArrayTest ($NpMany.Count -eq 2 -and $NpMany[1].uid -ceq '12346') 'multiple exclusion entries survive'
$NpExpectedUids = @($NpMany | ForEach-Object { [uint32]$_.uid } | Sort-Object -Unique)
$NpActiveUids = ConvertFrom-NpJsonArray '[12345,12346]'
Assert-NpArrayTest ($NpExpectedUids.Count -eq 2 -and $NpActiveUids -contains $NpExpectedUids[0] -and $NpActiveUids -contains $NpExpectedUids[1]) 'post-reboot UID comparison reads individual UIDs'
foreach ($NpJson in @('[]', '[12345]', '[12345,12346]')) {
    $NpArray = ConvertFrom-NpJsonArray $NpJson
    $NpExpectedCount = if ($NpJson -ceq '[]') { 0 } elseif ($NpJson -ceq '[12345]') { 1 } else { 2 }
    Assert-NpArrayTest ($NpArray -is [array] -and $NpArray.Count -eq $NpExpectedCount) ("UID array cardinality: " + $NpJson)
}
$NpNull = ConvertFrom-NpJsonArray '[null]'
Assert-NpArrayTest ($NpNull.Count -eq 1 -and $null -eq $NpNull[0]) 'null entry is preserved for validation'
$NpNested = ConvertFrom-NpJsonArray '[[1,2]]'
Assert-NpArrayTest ($NpNested.Count -eq 1 -and $NpNested[0] -is [array] -and $NpNested[0].Count -eq 2) 'nested arrays are not flattened'
foreach ($NpBad in @('{}', 'null', '[', '[] trailing ]', '[] , []')) {
    Assert-NpArrayRejects { ConvertFrom-NpJsonArray $NpBad } ("invalid array rejected: " + $NpBad)
}
foreach ($NpBad in @('[{}]', '[null]', '[[{"uid":12345}]]', '[{"uid":0}]', '[{"uid":-1}]', '[{"uid":4294967296}]', '[{"uid":"bad"}]')) {
    Assert-NpArrayRejects { Get-NpExclusions $NpBad } ("invalid exclusion rejected: " + $NpBad)
}
$NpUnicodeName = [string][char]0x0639 + [char]0x0632 + [char]0x0644
$NpUnicodeJson = ConvertTo-Json -InputObject @([pscustomobject]@{ uid = 12345; name = $NpUnicodeName }) -Compress
$NpUnicode = Get-NpExclusions $NpUnicodeJson
Assert-NpArrayTest ($NpUnicode[0].name -ceq $NpUnicodeName) 'Arabic names survive'
$NpRules = ConvertFrom-NpJsonArray '[]'
Assert-NpArrayTest ($NpRules.Count -eq 0) 'empty post-reboot rules count is zero'
$NpRules = ConvertFrom-NpJsonArray '[{"virtual":"/v1","real":"/r1"},{"virtual":"/v2","real":"/r2"}]'
Assert-NpArrayTest ($NpRules.Count -eq 2 -and $NpRules[1].real -ceq '/r2') 'multiple rules remain separate objects'
$NpModules = ConvertFrom-NpJsonArray '[{"id":"nomount","enabled":"true","remove":"false","update":"false"}]'
$NpInstalled = @($NpModules | Where-Object { $_.id -ceq 'nomount' })
Assert-NpArrayTest ($NpInstalled.Count -eq 1 -and $NpInstalled[0].enabled -ceq 'true' -and $NpInstalled[0].remove -ceq 'false' -and $NpInstalled[0].update -ceq 'false') 'singleton manager state matches post-reboot verification'
$NpModules = ConvertFrom-NpJsonArray '[{"id":"other","enabled":"true"},{"id":"nomount","enabled":"true","remove":"false","update":"false"}]'
$NpInstalled = @($NpModules | Where-Object { $_.id -ceq 'nomount' })
Assert-NpArrayTest ($NpModules.Count -eq 2 -and $NpInstalled.Count -eq 1) 'multiple manager modules enumerate individually'
$NpSource = [IO.File]::ReadAllText($NpInstaller)
Assert-NpArrayTest ($NpSource -notmatch '@\(\$Np\w+\s*\|\s*ConvertFrom-Json\)') 'installer has no version-dependent top-level JSON pipeline'
Write-Host "NOMOUNT_JSON_CHECKS_PASSED=$script:NpPassed"
