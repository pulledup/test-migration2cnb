param(
    [Parameter(Mandatory=$true)][string]$owner,
    [Parameter(Mandatory=$true)][string]$repo,
    [Parameter(Mandatory=$true)][string]$path
)

Set-StrictMode -Version Latest

try {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
} catch {
    Write-Error "Failed to get git branch: $_"
    exit 2
}
if (-not $branch) { Write-Error "Cannot determine branch"; exit 2 }

if (-not (Test-Path -Path $path)) { Write-Error "File '$path' not found"; exit 3 }

try {
    $content = Get-Content -Raw -Path $path -ErrorAction Stop
} catch {
    Write-Error "Failed reading file: $_"
    exit 4
}

# Encode as UTF-8 base64 to preserve Chinese characters
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::Utf8.GetBytes($content))

# Write base64 to temp file without BOM to avoid CLI parsing/encoding issues
$tmpB64 = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ([System.Guid]::NewGuid().ToString() + '.b64'))
[System.IO.File]::WriteAllText($tmpB64, $b64, (New-Object System.Text.UTF8Encoding $false))

# Fetch existing file sha if present
$sha = $null
try {
    $shaRaw = gh api "repos/$owner/$repo/contents/$path?ref=$branch" --jq '.sha' 2>&1 | Out-String
    $shaRaw = $shaRaw.Trim()
    $shaRaw = $shaRaw.Trim('"')
    if ($shaRaw -and $shaRaw -ne 'null' -and $shaRaw -match '^[0-9a-f]{40}$') { $sha = $shaRaw }
} catch {
    # ignore - treat as creation if not found
}

$message = "update $path at $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# Build gh api args using -F and @file for content to avoid shell expansion issues
$cmd = @('--method','PUT','-H','Accept: application/vnd.github+json','-H','X-GitHub-Api-Version: 2026-03-10', "/repos/$owner/$repo/contents/$path", '-F', "message=$message", '-F', "content=@$tmpB64", '-F', "branch=$branch")
if ($sha) { $cmd += @('-F', "sha=$sha") }
nWrite-Output "DEBUG: sha='$sha'"
Write-Output "DEBUG: running gh api: gh api $($cmd -join ' ')"

$resp = gh api @cmd 2>&1 | Out-String
$exitCode = $LASTEXITCODE

# Clean up temp filentry { Remove-Item -LiteralPath $tmpB64 -ErrorAction SilentlyContinue } catch {}
nif ($exitCode -ne 0) {
    Write-Error "gh api failed (exit $exitCode): $resp"
    exit $exitCode
}
Write-Output "Upload completed. Response: $resp"