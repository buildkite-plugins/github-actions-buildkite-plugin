# Windows is an execution target, not an importer host.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    & pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}
$runtimeStatus = 1
$runtimeDir = $null

function Assert-Keys($value, [string[]]$required, [string[]]$optional = @()) {
    if ($value -isnot [System.Collections.IDictionary]) { throw 'expected an object' }
    foreach ($key in $required) {
        if (-not $value.Contains($key)) { throw "missing $key" }
    }
    foreach ($key in $value.Keys) {
        if ($key -cnotin ($required + $optional)) { throw "unknown option $key" }
    }
}

function Assert-Text($value, [string]$pattern) {
    if ($value -isnot [string] -or $value -cmatch '[\x00-\x1f\x7f]' -or $value -cnotmatch $pattern) {
        throw 'invalid pinned runtime or plan reference'
    }
}

function Test-Digest([string]$path, [string]$expected) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expected
}

try {
    try { $configuration = ConvertFrom-Json -AsHashtable $env:BUILDKITE_PLUGIN_CONFIGURATION }
    catch { throw 'configuration must be a JSON object' }
    Assert-Keys $configuration @('run')
    $run = $configuration.run
    Assert-Keys $run @('plan', 'runtime') @('event', 'hosted-tool-cache', 'namespace')
    Assert-Keys $run.plan @('digest') @('path', 'producer', 'inline')
    if (@('path', 'producer', 'inline').Where({ $run.plan.Contains($_) }).Count -ne 1) { throw 'plan requires exactly one of path, inline or producer' }
    Assert-Text $run.plan.digest '^sha256:[0-9a-f]{64}$'
    if ($run.plan.Contains('path')) {
        Assert-Text $run.plan.path '^.+$'
    } elseif ($run.plan.Contains('inline')) {
        Assert-Text $run.plan.inline '^[A-Za-z0-9+/]+={0,2}$'
    } else {
        Assert-Text $run.plan.producer '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    }
    if ($run.Contains('event')) {
        if ($run.plan.Contains('producer')) { throw 'inline event cannot override a plan producer' }
        Assert-Keys $run.event @() @('inline', 'env')
        if ($run.event.Contains('inline') -eq $run.event.Contains('env')) { throw 'event requires exactly one of inline or env' }
        if ($run.event.Contains('env')) {
            if ($run.event.env -cne 'BUILDKITE_GHA_EVENT_PAYLOAD') { throw 'unsupported event environment variable' }
            $eventBase64 = $env:BUILDKITE_GHA_EVENT_PAYLOAD
            Remove-Item Env:BUILDKITE_GHA_EVENT_PAYLOAD -ErrorAction SilentlyContinue
        } else { $eventBase64 = $run.event.inline }
        Assert-Text $eventBase64 '^[A-Za-z0-9+/]+={0,2}$'
        if ($eventBase64.Length -gt 87384) { throw 'inline event exceeds 64 KiB' }
    }
    Assert-Keys $run.runtime @('platform', 'url', 'sha256')
    if ($run.runtime.platform -cne 'windows/amd64' -or -not $IsWindows -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
        throw 'runtime platform must match windows/amd64'
    }
    Assert-Text $run.runtime.url '^https://[^/@\s?#]+([/?][^\s#]*)?$'
    Assert-Text $run.runtime.sha256 '^[0-9a-fA-F]{64}$'
    foreach ($key in @('hosted-tool-cache', 'namespace')) {
        if ($run.Contains($key) -and $run[$key] -isnot [bool]) { throw "$key must be boolean" }
    }
    if ($run.namespace) { throw 'Namespace setup is not supported on Windows' }
    Remove-Item Env:BUILDKITE_GHA_PLUGIN_RELEASE -ErrorAction SilentlyContinue
    $runtimeDir = Join-Path ([IO.Path]::GetTempPath()) ('buildkite-gha-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runtimeDir | Out-Null
    $binary = Join-Path $runtimeDir 'buildkite-gha.exe'
    $digest = $run.runtime.sha256.ToLowerInvariant()
    $cacheRoot = $null
    if ($env:BUILDKITE_GHA_CACHE_DIR) { $cacheRoot = $env:BUILDKITE_GHA_CACHE_DIR }
    elseif ($env:MISE_DATA_DIR) { $cacheRoot = Join-Path $env:MISE_DATA_DIR 'buildkite-gha' }
    elseif ($env:BUILDKITE_AGENT_DATA_PATH) { $cacheRoot = Join-Path $env:BUILDKITE_AGENT_DATA_PATH 'cache/buildkite-gha' }
    elseif ($env:LOCALAPPDATA) { $cacheRoot = Join-Path $env:LOCALAPPDATA 'buildkite-gha' }
    $cached = $null
    if ($cacheRoot -and [IO.Path]::IsPathFullyQualified($cacheRoot)) {
        $cached = Join-Path $cacheRoot "binaries/windows-amd64/$digest"
    }
    $cacheHit = $false
    if ($cached -and (Test-Path -LiteralPath $cached -PathType Leaf)) {
        Copy-Item -LiteralPath $cached -Destination $binary
        $cacheHit = Test-Digest $binary $digest
    }
    if (-not $cacheHit) {
        Write-Host '--- :github: Prepare pinned runtime'
        & curl.exe --disable --fail --silent --show-error --location --globoff --proto '=https' --proto-redir '=https' --tlsv1.2 $run.runtime.url --output $binary
        if ($LASTEXITCODE -ne 0) { throw "runtime download failed with exit code $LASTEXITCODE" }
        if (-not (Test-Digest $binary $digest)) { throw 'binary checksum verification failed' }
        if ($cached) {
            $staged = "$cached.$([Guid]::NewGuid().ToString('N'))"
            try {
                New-Item -ItemType Directory -Force -Path (Split-Path $cached) | Out-Null
                Copy-Item -LiteralPath $binary -Destination $staged
                Move-Item -LiteralPath $staged -Destination $cached -Force
            } catch {
                Write-Warning 'github-actions plugin: could not write cache'
            } finally {
                Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $plan = Join-Path $runtimeDir 'plan.json'
    if ($run.plan.producer) {
        $artifact = '.buildkite-gha/plans/' + $run.plan.digest.Substring(7) + '.json'
        & buildkite-agent artifact download $artifact $runtimeDir --step $run.plan.producer
        if ($LASTEXITCODE -ne 0) { throw "plan download failed with exit code $LASTEXITCODE" }
        Move-Item -LiteralPath (Join-Path $runtimeDir $artifact) -Destination $plan
    } elseif ($run.plan.inline) {
        try { $bytes = [Convert]::FromBase64String($run.plan.inline) }
        catch { throw 'invalid inline plan encoding' }
        [IO.File]::WriteAllBytes($plan, $bytes)
    } else {
        Copy-Item -LiteralPath $run.plan.path -Destination $plan
    }
    if (-not (Test-Digest $plan $run.plan.digest.Substring(7))) { throw 'plan checksum verification failed' }
    $producer = $run.plan.producer
    if ($run.Contains('event')) {
        $producer = $env:BUILDKITE_JOB_ID
        Assert-Text $producer '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        try { $eventBinding = (Get-Content -Raw -LiteralPath $plan | ConvertFrom-Json -AsHashtable).event }
        catch { throw 'invalid plan JSON' }
        if ($eventBinding.payload_artifact -cne $true) { throw 'plan requires a digest-bound event artifact' }
        Assert-Text $eventBinding.payload_digest '^sha256:[0-9a-f]{64}$'
        try { $bytes = [Convert]::FromBase64String($eventBase64) }
        catch { throw 'invalid inline event encoding' }
        if ($bytes.Length -gt 65536) { throw 'inline event exceeds 64 KiB' }
        $eventPath = '.buildkite-gha/events/' + $eventBinding.payload_digest.Substring(7) + '.json'
        New-Item -ItemType Directory -Force -Path (Join-Path $runtimeDir '.buildkite-gha/events') | Out-Null
        $eventFile = Join-Path $runtimeDir $eventPath
        [IO.File]::WriteAllBytes($eventFile, $bytes)
        if (-not (Test-Digest $eventFile $eventBinding.payload_digest.Substring(7))) { throw 'event checksum verification failed' }
        Push-Location $runtimeDir
        try {
            & buildkite-agent artifact upload $eventPath
            if ($LASTEXITCODE -ne 0) { throw "event upload failed with exit code $LASTEXITCODE" }
        } finally { Pop-Location }
    }
    $arguments = @('run-job', '--plan', $plan)
    if ($producer) { $arguments += @('--artifact-producer', $producer) }
    if ($run['hosted-tool-cache']) { $arguments += '--hosted-tool-cache' }
    $env:BUILDKITE_GHA_PLAN_DIGEST = $run.plan.digest
    & $binary @arguments
    $runtimeStatus = $LASTEXITCODE
} catch {
    Write-Error "github-actions plugin: $_" -ErrorAction Continue
} finally {
    if ($runtimeDir) { Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $runtimeStatus
