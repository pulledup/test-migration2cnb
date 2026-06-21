param(
    [Parameter(Mandatory=$true)][string]$owner,
    [Parameter(Mandatory=$true)][string]$repo,
    [Parameter(Mandatory=$true)][string]$path
)

Set-StrictMode -Version Latest

# Determine current branch
try {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
} catch {
    Write-Error "Failed to get git branch: $_"
    exit 2
}
if (-not $branch) { Write-Error "Cannot determine branch"; exit 2 }

# Ensure file exists
if (-not (Test-Path -Path $path)) { Write-Error "File '$path' not found"; exit 3 }

# Read file explicitly as UTF-8 text to preserve characters
try {
    $content = [System.IO.File]::ReadAllText((Resolve-Path -Path $path), [System.Text.Encoding]::UTF8)
} catch {
    Write-Error "Failed reading file as UTF-8: $_"
    exit 4
}

# Create base64 from UTF-8 bytes
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))

# Fetch existing remote sha (if any)
$sha = $null
try {
    $shaRaw = gh api "repos/$owner/$repo/contents/$path?ref=$branch" --jq '.sha' 2>$null | Out-String
    $shaRaw = $shaRaw.Trim().Trim('"')
    if ($shaRaw -and $shaRaw -ne 'null' -and $shaRaw -match '^[0-9a-f]{40}$') { $sha = $shaRaw }
} catch {
    # ignore - will create if not present
}

$message = "update $path at $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# Build gh api args using raw-field (-f) with base64 content (matches official example)
$args = @('--method','PUT','-H','Accept: application/vnd.github+json','-H','X-GitHub-Api-Version: 2026-03-10', "/repos/$owner/$repo/contents/$path", '-f', "message=$message", '-f', "content=$b64", '-f', "branch=$branch")
if ($sha) { $args += @('-f', "sha=$sha") }

Write-Output "DEBUG: sha='$sha'"
# Execute gh api
$resp = gh api @args 2>&1 | Out-String
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Error "gh api failed (exit $exitCode): $resp"
    exit $exitCode
}
Write-Output "Upload completed. Response: $resp"
