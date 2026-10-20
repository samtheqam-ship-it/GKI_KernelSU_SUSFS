param(
    [string]$Repository = 'samtheqam-ship-it/GKI_KernelSU_SUSFS',
    [string]$BackupDirectory = (Join-Path $env:USERPROFILE 'NP03J-Signing-Backup')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository name.' }
$gh = (Get-Command gh -ErrorAction Stop).Source
$keytool = Get-Command keytool -ErrorAction SilentlyContinue
if (-not $keytool) {
    $studioKeytool = Join-Path $env:ProgramFiles 'Android\Android Studio\jbr\bin\keytool.exe'
    if (Test-Path $studioKeytool) { $keytool = Get-Item $studioKeytool }
    else { throw 'Java keytool is required. Install a JDK or Android Studio, then run this script again.' }
}
$keytoolPath = if ($keytool.PSObject.Properties['Source']) { $keytool.Source } else { $keytool.FullName }
& $gh auth status
if ($LASTEXITCODE -ne 0) { throw 'Sign in with gh auth login, then run this script again.' }

function Set-PrivateSecret([string]$Name, [string]$Value) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $gh
    $info.Arguments = "secret set $Name --repo $Repository"
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $process.StandardInput.Write($Value)
    $process.StandardInput.Close()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Could not save $Name. Keep the local backup and rerun this script." }
    $process.Dispose()
}

$BackupDirectory = [IO.Path]::GetFullPath($BackupDirectory)
New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
# Remove inherited access and grant only this Windows account access to the backup directory.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -Path $BackupDirectory -AclObject $acl

$keystore = Join-Path $BackupDirectory 'np03j-manager.p12'
$passwordFile = Join-Path $BackupDirectory 'np03j-password.txt'
$certFile = Join-Path $BackupDirectory 'np03j-manager-cert.der'
if ((Test-Path $keystore) -xor (Test-Path $passwordFile)) {
    throw 'Incomplete signing backup. Restore the missing original file; do not replace an existing manager identity.'
}
try {
    if (-not (Test-Path $keystore)) {
        $bytes = New-Object byte[] 36
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        $rng.Dispose()
        $password = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        [IO.File]::WriteAllText($passwordFile, $password, (New-Object Text.UTF8Encoding($false)))
        $env:NP03J_LOCAL_SIGN_PASSWORD = $password
        & $keytoolPath -genkeypair -keystore $keystore -storetype PKCS12 -alias np03j -keyalg RSA -keysize 2048 -sigalg SHA256withRSA -validity 36500 -dname 'CN=NP03J Manager' -storepass:env NP03J_LOCAL_SIGN_PASSWORD -keypass:env NP03J_LOCAL_SIGN_PASSWORD
        if ($LASTEXITCODE -ne 0) { throw 'Keystore creation failed. No repository secret has been written.' }
    } else {
        $password = [IO.File]::ReadAllText($passwordFile).Trim()
        if ($password -notmatch '^[A-Za-z0-9_-]{24,128}$') { throw 'Invalid backed-up password.' }
        $env:NP03J_LOCAL_SIGN_PASSWORD = $password
    }
    if (Test-Path $certFile) { Remove-Item $certFile }
    & $keytoolPath -exportcert -keystore $keystore -storetype PKCS12 -alias np03j -storepass:env NP03J_LOCAL_SIGN_PASSWORD -file $certFile
    if ($LASTEXITCODE -ne 0) { throw 'The original signing key could not be opened.' }
    if ((Get-Item $certFile).Length -gt 1024) { throw 'Certificate exceeds the size supported by the kernel.' }
    Set-PrivateSecret 'NP03J_KEYSTORE_B64' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore)))
    Set-PrivateSecret 'NP03J_KEYSTORE_PASSWORD' $password
    Write-Host "Signing identity saved. Keep this private backup: $BackupDirectory"
    Write-Host "Workflow: https://github.com/$Repository/actions/workflows/np03j-6.1-lts.yml"
} finally {
    Remove-Item Env:NP03J_LOCAL_SIGN_PASSWORD -ErrorAction SilentlyContinue
    $password = $null
}
