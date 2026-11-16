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

function Save-Cache([string]$source, [string]$destination) {
    if (-not $destination) { return }
    $staged = "$destination.$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $staged
        Move-Item -LiteralPath $staged -Destination $destination -Force
    } catch {
        Write-Warning 'github-actions plugin: could not write cache'
    } finally {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    }
}

function Read-ReleaseAsset([string]$path, [string]$version) {
    $release = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
    Assert-Text $release.tag_name $releasePattern
    if ($version -cne 'latest' -and $release.tag_name -cne $version) { throw 'release response tag does not match version' }
    $assets = @($release.assets | Where-Object { $_.name -ceq 'buildkite-gha_windows_x86_64.exe' })
    if ($assets.Count -eq 0) {
        $assets = @($release.assets | Where-Object { $_.name -ceq 'buildkite-gha_Windows_x86_64.tar.gz' })
    }
    if ($assets.Count -ne 1) { throw 'release requires a unique Windows executable or historical archive' }
    Assert-Text $assets[0].browser_download_url '^https://[^/@\s?#]+([/?][^\s#]*)?$'
    Assert-Text $assets[0].digest '^sha256:[0-9a-fA-F]{64}$'
    return $assets[0]
}

try {
    try { $configuration = ConvertFrom-Json -AsHashtable $env:BUILDKITE_PLUGIN_CONFIGURATION }
    catch { throw 'configuration must be a JSON object' }
    Assert-Keys $configuration @('run') @('version', 'binary', 'hosted-tool-cache')
    if ($configuration.Contains('version') -and $configuration.Contains('binary')) { throw 'version and binary are mutually exclusive' }
    $run = $configuration.run
    Assert-Keys $run @('plan') @('runtime', 'event', 'hosted-tool-cache', 'namespace')
    if ($run.Contains('runtime') -and ($configuration.Contains('version') -or $configuration.Contains('binary'))) { throw 'legacy runtime cannot be combined with version or binary' }
    if ($configuration.Contains('hosted-tool-cache') -and $configuration['hosted-tool-cache'] -isnot [bool]) { throw 'hosted-tool-cache must be boolean' }
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
    if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
        throw 'runtime platform must match windows/amd64'
    }
    $url = $null
    $digest = $null
    $version = 'latest'
    $releasePattern = '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?$'
    if ($run.Contains('runtime')) {
        Assert-Keys $run.runtime @('platform', 'url', 'sha256')
        if ($run.runtime.platform -cne 'windows/amd64') { throw 'runtime platform must match windows/amd64' }
        Assert-Text $run.runtime.url '^https://[^/@\s?#]+([/?][^\s#]*)?$'
        Assert-Text $run.runtime.sha256 '^[0-9a-fA-F]{64}$'
        $url = $run.runtime.url
        $digest = $run.runtime.sha256.ToLowerInvariant()
    } elseif ($configuration.Contains('binary')) {
        $source = $configuration.binary
        $urlPattern = '^https://[^/@\s?#]+([/?][^\s#]*)?(#sha256=[0-9a-fA-F]{64})?$'
        if ($source -is [System.Collections.IDictionary]) {
            Assert-Keys $source @() @('linux/amd64', 'linux/arm64', 'darwin/arm64', 'windows/amd64')
            foreach ($value in $source.Values) { Assert-Text $value $urlPattern }
            $source = $source['windows/amd64']
        }
        Assert-Text $source $urlPattern
        $parts = $source -split '#sha256=', 2
        $url = $parts[0]
        if ($parts.Count -eq 2) { $digest = $parts[1].ToLowerInvariant() }
    } elseif ($configuration.Contains('version')) {
        Assert-Text $configuration.version ('^(latest|' + $releasePattern.TrimStart('^').TrimEnd('$') + ')$')
        if ($configuration.version -cne 'latest') { $version = 'v' + $configuration.version.TrimStart('v') }
    }
    foreach ($key in @('hosted-tool-cache', 'namespace')) {
        if ($run.Contains($key) -and $run[$key] -isnot [bool]) { throw "$key must be boolean" }
    }
    if ($run.namespace) { throw 'Namespace setup is not supported on Windows' }
    Remove-Item Env:BUILDKITE_GHA_PLUGIN_RELEASE -ErrorAction SilentlyContinue
    $runtimeDir = Join-Path ([IO.Path]::GetTempPath()) ('buildkite-gha-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runtimeDir | Out-Null
    $binary = Join-Path $runtimeDir 'buildkite-gha.exe'
    $cacheRoot = $null
    if ($env:BUILDKITE_GHA_CACHE_DIR) { $cacheRoot = $env:BUILDKITE_GHA_CACHE_DIR }
    elseif ($env:MISE_DATA_DIR) { $cacheRoot = Join-Path $env:MISE_DATA_DIR 'buildkite-gha' }
    elseif ($env:BUILDKITE_AGENT_DATA_PATH) { $cacheRoot = Join-Path $env:BUILDKITE_AGENT_DATA_PATH 'cache/buildkite-gha' }
    elseif ($env:LOCALAPPDATA) { $cacheRoot = Join-Path $env:LOCALAPPDATA 'buildkite-gha' }
    if ($cacheRoot -and -not [IO.Path]::IsPathFullyQualified($cacheRoot)) { $cacheRoot = $null }
    $archive = $false
    if (-not $url) {
        $releasePath = if ($version -ceq 'latest') { 'latest' } else { "tags/$version" }
        $metadataCache = if ($cacheRoot) { Join-Path $cacheRoot "releases/$releasePath.json" } else { $null }
        $metadata = Join-Path $runtimeDir 'release.json'
        $selected = $null
        if ($metadataCache -and (Test-Path -LiteralPath $metadataCache -PathType Leaf)) {
            $modified = (Get-Item -LiteralPath $metadataCache).LastWriteTimeUtc
            $age = [DateTime]::UtcNow - $modified
            $clean = $env:BUILDKITE_CLEAN_CHECKOUT -cin @('1', 't', 'T', 'TRUE', 'true', 'True')
            if ($version -cne 'latest' -or (-not $clean -and $age.TotalSeconds -ge 0 -and $age.TotalSeconds -lt 3600)) {
                try {
                    Copy-Item -LiteralPath $metadataCache -Destination $metadata
                    $selected = Read-ReleaseAsset $metadata $version
                } catch { $selected = $null }
            }
        }
        if (-not $selected) {
            Assert-Text $env:BUILDKITE_AGENT_ENDPOINT '^https://[^/@\s?#]+(/[^\s?#]*)?$'
            Assert-Text $env:BUILDKITE_JOB_ID '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            Assert-Text $env:BUILDKITE_AGENT_ACCESS_TOKEN '^.+$'
            $headers = Join-Path $runtimeDir 'agent-headers'
            [IO.File]::WriteAllText($headers, "Authorization: Token $env:BUILDKITE_AGENT_ACCESS_TOKEN`n")
            $endpoint = $env:BUILDKITE_AGENT_ENDPOINT.TrimEnd('/')
            & curl.exe --disable --fail --silent --show-error --location --globoff --proto '=https' --proto-redir '=https' --tlsv1.2 "$endpoint/jobs/$env:BUILDKITE_JOB_ID/github-actions/releases/$releasePath" --output $metadata --header "@$headers" --max-redirs 0
            if ($LASTEXITCODE -ne 0) { throw "release lookup failed with exit code $LASTEXITCODE" }
            Remove-Item -LiteralPath $headers -Force
            $selected = Read-ReleaseAsset $metadata $version
            Save-Cache $metadata $metadataCache
        }
        $url = $selected.browser_download_url
        $digest = $selected.digest.Substring(7).ToLowerInvariant()
        $archive = $selected.name -ceq 'buildkite-gha_Windows_x86_64.tar.gz'
    }
    $downloadPath = if ($archive) { Join-Path $runtimeDir 'release.tar.gz' } else { $binary }
    $cached = $null
    if ($cacheRoot -and $digest) {
        $kind = if ($archive) { 'archives' } else { 'binaries' }
        $cached = Join-Path $cacheRoot "$kind/windows-amd64/$digest"
    }
    $cacheHit = $false
    if ($cached -and (Test-Path -LiteralPath $cached -PathType Leaf)) {
        Copy-Item -LiteralPath $cached -Destination $downloadPath
        $cacheHit = Test-Digest $downloadPath $digest
    }
    if (-not $cacheHit) {
        Write-Host '--- :github: Prepare runtime'
        & curl.exe --disable --fail --silent --show-error --location --globoff --proto '=https' --proto-redir '=https' --tlsv1.2 $url --output $downloadPath
        if ($LASTEXITCODE -ne 0) { throw "runtime download failed with exit code $LASTEXITCODE" }
        if ($digest -and -not (Test-Digest $downloadPath $digest)) { throw 'binary checksum verification failed' }
        Save-Cache $downloadPath $cached
    }
    if ($archive) {
        & tar -xzf $downloadPath -C $runtimeDir buildkite-gha.exe
        if ($LASTEXITCODE -ne 0) { throw 'runtime archive extraction failed' }
    }
    if ((Get-Item -LiteralPath $binary).Length -eq 0) { throw 'downloaded executable is empty' }
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
    $hostedToolCache = if ($configuration.Contains('hosted-tool-cache')) { $configuration['hosted-tool-cache'] } else { $run['hosted-tool-cache'] }
    if ($hostedToolCache) { $arguments += '--hosted-tool-cache' }
    $env:BUILDKITE_GHA_PLAN_DIGEST = $run.plan.digest
    & $binary @arguments
    $runtimeStatus = $LASTEXITCODE
} catch {
    Write-Error "github-actions plugin: $_" -ErrorAction Continue
} finally {
    if ($runtimeDir) { Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $runtimeStatus
