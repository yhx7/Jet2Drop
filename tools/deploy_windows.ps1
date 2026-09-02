param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseRoot = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$deployRoot = Join-Path $projectRoot 'dist\Windows'
$deployExe = Join-Path $deployRoot 'jet2drop.exe'

Push-Location $projectRoot
try {
    if (-not $SkipBuild) {
        $env:APPDATA = (Resolve-Path '.\.flutter_appdata').Path
        $env:LOCALAPPDATA = (Resolve-Path '.\.flutter_localappdata').Path
        $env:PUB_CACHE = (Resolve-Path '.\.pub-cache').Path
        $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'safe.directory'
        $env:GIT_CONFIG_VALUE_0 = ($projectRoot -replace '\\', '/') + '/flutter_sdk'
        & '.\flutter_sdk\bin\flutter.bat' build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
    }
    if (-not (Test-Path -LiteralPath $releaseRoot)) {
        throw "Release directory does not exist: $releaseRoot"
    }

    $deployedProcesses = @(Get-Process jet2drop -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($deployExe) })
    $deployedProcesses | Stop-Process -Force
    foreach ($process in $deployedProcesses) {
        Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $deployRoot -Force | Out-Null
    $copied = $false
    for ($attempt = 1; $attempt -le 5 -and -not $copied; $attempt++) {
        try {
            Get-ChildItem -LiteralPath $releaseRoot -Force |
                Copy-Item -Destination $deployRoot -Recurse -Force
            $copied = $true
        } catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Seconds 1
        }
    }

    Get-ChildItem -LiteralPath $releaseRoot -File -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($releaseRoot.Length).TrimStart('\')
        $deployed = Join-Path $deployRoot $relative
        if (-not (Test-Path -LiteralPath $deployed)) { throw "Missing deployed file: $relative" }
        if ((Get-FileHash -LiteralPath $_.FullName).Hash -ne
            (Get-FileHash -LiteralPath $deployed).Hash) {
            throw "Deployed file verification failed: $relative"
        }
    }

    Start-Process explorer.exe -ArgumentList ('"' + $deployExe + '"')
    Start-Sleep -Seconds 4
    $running = Get-Process jet2drop -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($deployExe) }
    if (-not $running) { throw 'The deployed application did not stay running.' }
    Write-Host "Jet2Drop deployed and started: $deployExe"
} finally {
    Pop-Location
}
