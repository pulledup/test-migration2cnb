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

# Read file explicitly as UTF-8 text and create base64 of exact UTF-8 bytes (robust)
try {
    $fullPath = (Resolve-Path -Path $path)
    $content = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
} catch {
    Write-Error "Failed reading or encoding file as UTF-8: $_"
    exit 4
}

# Fetch existing remote sha (if any)
$sha = $null
$fetch = gh api "repos/$owner/$repo/contents/$($path)?ref=$branch" 2>&1 | Out-String
try { $obj = $fetch | ConvertFrom-Json } catch { $obj = $null }
if ($obj -and $obj.sha) { $sha = $obj.sha }

$message = "update $path at $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# Build request body as JSON and write to temporary file (UTF-8 without BOM)
$body = @{ message = $message; content = $b64; branch = $branch }
if ($sha) { $body.sha = $sha }
$json = $body | ConvertTo-Json -Depth 6
$tmp = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.json')
[System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Output "DEBUG: request JSON written to $tmp ($(Get-Item $tmp).Length bytes)"

# Call API with --input for robust transmission and capture verbose output
$resp = gh api "/repos/$owner/$repo/contents/$path" -H "Accept: application/vndithub+json" -H "X-GitHub-Api-Version: 2026-03-10" --method PUT --input $tmp --verbose 2>&1 | Out-String
$exit = $LASTEXITCODE

# If server rejects due to missing sha, try to refetch sha and retry once
if ($exit -ne 0) {
    Write-Output "DEBUG: initial upload failed (exit $exit). Response: $resp"
    if ($resp -match '\"sha\" wasn''t supplied' -or $resp -match 'sha wasn''t supplied') {
        Write-Output 'DEBUG: server requires sha — refetching and retrying once.'
        $sha = $null
        for ($attempt=1; $attempt -le 5; $attempt++) {
            $fetch = gh api "repos/$owner/$repo/contents/$($path)?ref=$branch" 2>&1 | Out-String
            try { $obj = $fetch | ConvertFrom-Json } catch { $obj = $null }
            if ($obj -and $obj.sha -and ($obj.sha -match '^[0-9a-f]{40}$')) { $sha = $obj.sha; break }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
        if ($sha) {
            Write-Output "DEBUG: retry fetched sha = '$sha'"
            $body.sha = $sha
            $json = $body | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
            Write-Output 'DEBUG: retrying upload with sha'
            $resp = gh api "/repos/$owner/$repo/contents/$path" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2026-03-10" --method PUT --input $tmp --verbose 2>&1 | Out-String
            $exit = $LASTEXITCODE
        } else {
            Write-Error 'Failed to fetch sha for retry.'
        }
    }
}

# Cleanup temp file
try { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue } catch {}

Write-Output "=== gh output ==="
Write-Output $resp
if ($exit -ne 0) { Write-Error "gh api failed (exit $exit)"; exit $exit } else { Write-Output "Upload completed." }
