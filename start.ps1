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
    $installer = @('ci', '--no-audit', '--no-fund')
    $cache = $null
    $storage = Join-Path $PSScriptRoot '.multiplexor\storage.json'
    $keep = (Test-Path -LiteralPath $storage) -and
        ((Get-Content -LiteralPath $storage -Raw | ConvertFrom-Json).keepDownloads -eq $true)
    if (-not $keep) {
        $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('multiplexor-npm-cache-' + [guid]::NewGuid())
        $installer += @('--cache', $cache)
    }
    Push-Location -LiteralPath $harnessDirectory
    try {
        Invoke-SetupCommand $npmCommand.Source $installer
    } finally {
        Pop-Location
        if ($null -ne $cache -and (Test-Path -LiteralPath $cache)) {
            Remove-Item -LiteralPath $cache -Recurse -Force
        }
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

# Antivirus scans and other installers hold these files briefly.
function Invoke-FileOperation([scriptblock] $Operation) {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            & $Operation
            return
        } catch {
            if ($timer.Elapsed.TotalSeconds -ge 60) {
                throw
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Install-Multiplexor([string] $Candidate) {
    $stateDirectory = Join-Path $PSScriptRoot '.multiplexor'
    # Same lock as self_update_installer.dart, so only one installer swaps the binary at a time.
    $lockPath = Join-Path $PSScriptRoot '.multiplexor.exe.update.lock'
    $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
    try {
        Invoke-FileOperation { $lock.Lock(0, [long]::MaxValue) }
        # Windows can rename a running executable but cannot replace it.
        $previous = $null
        if (Test-Path -LiteralPath $executable) {
            New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
            $previous = Join-Path $stateDirectory ('multiplexor.exe.replaced.' + [guid]::NewGuid().ToString('N'))
            Invoke-FileOperation { Move-Item -LiteralPath $executable -Destination $previous }
        }
        try {
            Invoke-FileOperation { Move-Item -LiteralPath $Candidate -Destination $executable }
        } catch {
            $installError = $_
            if ($null -ne $previous) {
                try {
                    Invoke-FileOperation { Move-Item -LiteralPath $previous -Destination $executable }
                } catch {
                    throw "Install failed: $installError. Restore failed: $_. The previous executable is at $previous."
                }
            }
            throw $installError
        }
        # A copy that is still running cannot be deleted, so a later build removes it.
        Get-ChildItem -LiteralPath $stateDirectory -Filter 'multiplexor.exe.replaced.*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } finally {
        $lock.Dispose()
    }
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
        Install-Multiplexor $staging
        Write-LauncherMessage 'Build complete'
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
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
