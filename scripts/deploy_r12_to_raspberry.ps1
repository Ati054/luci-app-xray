[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ArtifactDir,

    [string]$RaspberryIp = '192.168.102.254',

    [string]$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519_rpi_reverse",

    [string]$KnownHostsFile = "$env:USERPROFILE\.ssh\known_hosts"
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
    $ArtifactDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ($RaspberryIp -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') {
    throw "Invalid Raspberry IPv4 address: $RaspberryIp"
}

$ArtifactDir = [IO.Path]::GetFullPath($ArtifactDir)
foreach ($required in @(
    'install_and_smoke_r12.sh',
    'SHA256SUMS-R12.txt',
    'BUILD-INFO-openwrt-25.12.5-all.txt',
    'xray-core-26.10.21-linux-arm64',
    'luci-app-xray-3.7.1-r12.apk'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $ArtifactDir $required) -PathType Leaf)) {
        throw "Required artifact file is missing: $required"
    }
}

if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    throw "SSH key was not found: $KeyPath"
}
if (-not (Test-Path -LiteralPath $KnownHostsFile -PathType Leaf)) {
    throw "known_hosts was not found: $KnownHostsFile. Confirm the host key once with a normal ssh connection first."
}

$sshOptions = @(
    '-i', $KeyPath,
    '-o', 'IdentitiesOnly=yes',
    '-o', 'BatchMode=yes',
    '-o', 'KexAlgorithms=curve25519-sha256',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$KnownHostsFile"
)
$target = "root@$RaspberryIp"
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmss')
$remoteDir = "/tmp/xray-r12-update-$stamp"

Write-Host "Checking SSH and creating temporary directory $remoteDir ..."
& ssh.exe @sshOptions $target "test `$(id -u) -eq 0 && umask 077 && mkdir -p '$remoteDir' && chmod 0700 '$remoteDir' && echo SSH_READY"
if ($LASTEXITCODE -ne 0) { throw 'SSH verification failed' }

$files = @(Get-ChildItem -LiteralPath $ArtifactDir -File)
if ($files.Count -eq 0) { throw 'Artifact directory is empty' }
$scpArgs = @('-O', '-q') + $sshOptions + @($files.FullName) + @("${target}:$remoteDir/")

Write-Host "Copying $($files.Count) files to Raspberry RAM ..."
& scp.exe @scpArgs
if ($LASTEXITCODE -ne 0) { throw 'Artifact transfer failed' }

Write-Host 'Starting verified offline installation with backup and active-profile restoration ...'
$installOutput = @(& ssh.exe @sshOptions $target "cd '$remoteDir' && sh ./install_and_smoke_r12.sh" 2>&1)
$installOutput | ForEach-Object { Write-Host $_ }
$installExit = $LASTEXITCODE

if ($installExit -ne 0 -or $installOutput -notcontains 'R12_INSTALL_AND_HARDWARE_SMOKE_OK') {
    throw "Installation was not confirmed. Temporary files were kept for diagnostics: $remoteDir"
}

& ssh.exe @sshOptions $target "rm -rf '$remoteDir'"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Update succeeded, but the temporary directory could not be removed: $remoteDir"
}

Write-Host 'UPDATE SUCCEEDED: Xray 26.10.21, R12 package, and active profiles were verified.' -ForegroundColor Green
