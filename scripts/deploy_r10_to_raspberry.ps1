[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ArtifactDir = $PSScriptRoot,

    [string]$RaspberryIp = '192.168.102.254',

    [string]$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519_rpi_reverse",

    [string]$KnownHostsFile = "$env:USERPROFILE\.ssh\known_hosts"
)

$ErrorActionPreference = 'Stop'

if ($RaspberryIp -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') {
    throw "Некорректный IPv4-адрес Raspberry: $RaspberryIp"
}

$ArtifactDir = [IO.Path]::GetFullPath($ArtifactDir)
foreach ($required in @(
    'install_and_smoke_r10.sh',
    'SHA256SUMS-R10.txt',
    'BUILD-INFO-openwrt-25.12.5-all.txt',
    'xray-core-26.9.30-linux-arm64',
    'luci-app-xray-3.7.1-r10.apk'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $ArtifactDir $required) -PathType Leaf)) {
        throw "В каталоге артефакта отсутствует $required"
    }
}

if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    throw "SSH-ключ не найден: $KeyPath"
}
if (-not (Test-Path -LiteralPath $KnownHostsFile -PathType Leaf)) {
    throw "Файл known_hosts не найден: $KnownHostsFile. Сначала один раз подтвердите ключ хоста обычным ssh-подключением."
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
$remoteDir = "/tmp/xray-r10-update-$stamp"

Write-Host "Проверяю SSH и создаю временный каталог $remoteDir ..."
& ssh.exe @sshOptions $target "test `$(id -u) -eq 0 && install -d -m 0700 '$remoteDir' && echo SSH_READY"
if ($LASTEXITCODE -ne 0) { throw 'SSH-проверка не пройдена' }

$files = @(Get-ChildItem -LiteralPath $ArtifactDir -File)
if ($files.Count -eq 0) { throw 'Каталог артефакта пуст' }
$scpArgs = @('-O', '-q') + $sshOptions + @($files.FullName) + @("${target}:$remoteDir/")

Write-Host "Передаю $($files.Count) файлов в RAM Raspberry ..."
& scp.exe @scpArgs
if ($LASTEXITCODE -ne 0) { throw 'Передача артефакта завершилась ошибкой' }

Write-Host 'Запускаю проверенную офлайн-установку с backup и восстановлением активных профилей ...'
$installOutput = @(& ssh.exe @sshOptions $target "cd '$remoteDir' && sh ./install_and_smoke_r10.sh" 2>&1)
$installOutput | ForEach-Object { Write-Host $_ }
$installExit = $LASTEXITCODE

if ($installExit -ne 0 -or $installOutput -notcontains 'R10_INSTALL_AND_HARDWARE_SMOKE_OK') {
    throw "Установка не подтверждена. Временный каталог оставлен для диагностики: $remoteDir"
}

& ssh.exe @sshOptions $target "rm -rf '$remoteDir'"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Обновление успешно, но временный каталог не удалён: $remoteDir"
}

Write-Host 'ОБНОВЛЕНИЕ УСПЕШНО: Xray 26.9.30, пакет R10 и активные профили проверены.' -ForegroundColor Green
