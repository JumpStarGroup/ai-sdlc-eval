Set-StrictMode -Version Latest

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Prefix,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 60,
        [string]$InputText,
        [hashtable]$Environment = @{}
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    if ($Arguments.Count -ge 3 -and $Arguments[0] -eq '-NoProfile' -and
        $Arguments[1] -eq '-File' -and $Arguments[2].EndsWith('.ps1')) {
        $bootstrap = @'
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$invocation = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__INVOCATION__')) | ConvertFrom-Json
$scriptArguments = @($invocation.arguments)
& $invocation.path @scriptArguments
$invocationSucceeded = $?
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
if (-not $invocationSucceeded) { exit 1 }
exit 0
'@
        $payload = @{ path = $Arguments[2]; arguments = @($Arguments | Select-Object -Skip 3) } | ConvertTo-Json -Compress
        $bootstrap = $bootstrap.Replace('__INVOCATION__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)))
        $Arguments = @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap)))
    }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) {
        if ($null -eq $Environment[$name]) { [void]$info.Environment.Remove($name) }
        else { $info.Environment[$name] = [string]$Environment[$name] }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $stdout = [IO.File]::Open("$Prefix.stdout", 'Create', 'Write', 'Read')
    $stderr = [IO.File]::Open("$Prefix.stderr", 'Create', 'Write', 'Read')
    $started = $false
    try {
        $started = $process.Start()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $outCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errCopy = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $timedOut = $false
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $writeTask = $process.StandardInput.WriteAsync($InputText)
            try { $timedOut = -not $writeTask.Wait($TimeoutSeconds * 1000) }
            catch { if (-not $process.HasExited) { throw } }
        }
        if (-not $timedOut) {
            try { $process.StandardInput.Close() }
            catch { if (-not $process.HasExited) { throw } }
            while (-not $process.HasExited) {
                $remaining = [int][Math]::Max(0, $TimeoutSeconds * 1000 - $timer.ElapsedMilliseconds)
                if ($remaining -eq 0) { $timedOut = $true; break }
                if ($process.WaitForExit([Math]::Min(30000, $remaining))) { break }
                Write-Host "[$([DateTimeOffset]::UtcNow.ToString('o'))] Process $($process.Id) running: $([int]$timer.Elapsed.TotalSeconds)/${TimeoutSeconds}s; stdout=$($stdout.Length) bytes; evidence=$Prefix.stdout"
            }
        }
        if ($timedOut -and -not $process.HasExited) { $process.Kill($true) }
        $drained = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outCopy, $errCopy), 5000)
        if (-not $drained) {
            $process.StandardOutput.Close()
            $process.StandardError.Close()
        }
        return @{
            exitCode = $(if ($process.HasExited) { $process.ExitCode } else { -1 })
            timedOut = $timedOut
            outputDrainIncomplete = -not $drained
            durationSeconds = $timer.Elapsed.TotalSeconds
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true) }
        $stdout.Dispose()
        $stderr.Dispose()
        $process.Dispose()
    }
}

Export-ModuleMember -Function Invoke-CapturedProcess
