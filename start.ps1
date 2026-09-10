$ErrorActionPreference = 'Stop'
$launcherArguments = $args
$appDirectory = Join-Path $PSScriptRoot 'MultiplexorApp'
$executable = Join-Path $PSScriptRoot 'multiplexor.exe'
$harnessDirectory = Join-Path $appDirectory 'tool\mineflayer'

function Write-LauncherMessage([string] $Message) {
    [Console]::Error.WriteLine("[start.ps1] $Message")
}

function Invoke-SetupCommand([string] $ExecutablePath, [string[]] $Arguments) {
    $ErrorActionPreference = 'Continue'
    & $ExecutablePath @Arguments 2>&1 | ForEach-Object { [Console]::Error.WriteLine($_) }
    if ($LASTEXITCODE -ne 0) {
        throw "$ExecutablePath exited with code $LASTEXITCODE."
    }
}

function ConvertTo-NativeArgument([string] $Argument) {
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    return '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
}

function Install-Harness {
    $installedLock = Join-Path $harnessDirectory 'node_modules\.package-lock.json'
    $manifest = Join-Path $harnessDirectory 'package.json'
    $lock = Join-Path $harnessDirectory 'package-lock.json'
    if ((Test-Path -LiteralPath $installedLock) -and
        (Test-Path -LiteralPath $lock) -and
        (Get-Item -LiteralPath $installedLock).LastWriteTimeUtc -ge (Get-Item -LiteralPath $manifest).LastWriteTimeUtc -and
        (Get-Item -LiteralPath $installedLock).LastWriteTimeUtc -ge (Get-Item -LiteralPath $lock).LastWriteTimeUtc) {
        return
    }

    $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $npmCommand) {
        throw 'npm is not on PATH; install Node.js 22+ to use the gameplay commands.'
    }
    Write-LauncherMessage 'Installing the pinned Mineflayer harness dependencies'
    Push-Location -LiteralPath $harnessDirectory
    try {
        Invoke-SetupCommand $npmCommand.Source @('ci', '--no-audit', '--no-fund')
    } finally {
        Pop-Location
    }
}

function Test-GameplayCommand {
    $skip = $false
    foreach ($argument in $launcherArguments) {
        if ($skip) {
            $skip = $false
            continue
        }
        if ($argument -eq '--root' -or $argument -eq '--consumer') {
            $skip = $true
        } elseif ($argument -eq 'gameplay') {
            return $true
        }
    }
    return $false
}

function Test-BuildRequired {
    if ($env:MULTIPLEXOR_REBUILD -or !(Test-Path -LiteralPath $executable)) {
        return $true
    }
    $binaryTime = (Get-Item -LiteralPath $executable).LastWriteTimeUtc
    foreach ($manifest in @('pubspec.yaml', 'pubspec.lock')) {
        $manifestPath = Join-Path $appDirectory $manifest
        if ((Test-Path -LiteralPath $manifestPath) -and
            (Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc -gt $binaryTime) {
            return $true
        }
    }
    foreach ($sourceDirectory in @('lib', 'bin', 'tool')) {
        $newer = Get-ChildItem -LiteralPath (Join-Path $appDirectory $sourceDirectory) -Filter '*.dart' -Recurse -File |
            Where-Object { $_.LastWriteTimeUtc -gt $binaryTime } |
            Select-Object -First 1
        if ($null -ne $newer) {
            return $true
        }
    }
    return $false
}

function Build-Multiplexor {
    $dartCommand = Get-Command dart -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $dartCommand) {
        throw 'dart is not on PATH; install the Dart SDK to compile multiplexor.'
    }
    $dartExecutable = $dartCommand.Source
    $cachedDart = Join-Path (Split-Path -Parent $dartExecutable) 'cache\dart-sdk\bin\dart.exe'
    if (Test-Path -LiteralPath $cachedDart) {
        $dartExecutable = $cachedDart
    }

    $staging = "$executable.building.$PID"
    Push-Location -LiteralPath $appDirectory
    try {
        Write-LauncherMessage 'Resolving dependencies'
        Invoke-SetupCommand $dartExecutable @('pub', 'get')
        Write-LauncherMessage 'Sources changed; compiling multiplexor'
        Invoke-SetupCommand $dartExecutable @('run', 'tool/build_exe.dart', '--output', $staging)
        Move-Item -LiteralPath $staging -Destination $executable -Force
        Write-LauncherMessage 'Build complete'
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Force
        }
    }
}

Push-Location -LiteralPath $PSScriptRoot
try {
    if ($launcherArguments.Count -gt 0 -and $launcherArguments[0] -eq 'bootstrap') {
        Install-Harness
        Write-LauncherMessage 'Bootstrap complete'
        exit 0
    }
    if (!$env:MULTIPLEXOR_NO_BOOTSTRAP -and (Test-GameplayCommand)) {
        Install-Harness
    }
    if (Test-BuildRequired) {
        Build-Multiplexor
    }
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $executable
    $processInfo.WorkingDirectory = $PSScriptRoot
    $processInfo.UseShellExecute = $false
    $processInfo.Arguments = (@($launcherArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $process = [System.Diagnostics.Process]::Start($processInfo)
    try {
        $process.WaitForExit()
        exit $process.ExitCode
    } finally {
        $process.Dispose()
    }
} catch {
    Write-LauncherMessage $_.Exception.Message
    exit 1
} finally {
    Pop-Location
}
