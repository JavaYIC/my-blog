param(
  [Parameter(Mandatory = $true)]
  [string]$NotePath,

  [string]$VaultPath = "",

  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BlogRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $BlogRoot ".publish-logs"
$StagingDir = Join-Path $BlogRoot ".publish-staging"
$StagingAttachmentsDir = Join-Path $StagingDir "attachments"
$PromptPath = Join-Path $PSScriptRoot "prompts\publish-obsidian-post.md"
$ResultPath = Join-Path $StagingDir "result.json"
$FinalMessagePath = Join-Path $StagingDir "codex-final.md"

function Write-Step {
  param([string]$Message)
  Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Resolve-ExistingPath {
  param([string]$Path)
  return (Resolve-Path -LiteralPath $Path).Path
}

function Find-Tool {
  param(
    [string]$Name,
    [string]$FallbackPattern
  )

  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }

  if ($FallbackPattern) {
    $match = Get-ChildItem -Path $FallbackPattern -Recurse -File -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName
    if ($match) {
      return $match
    }
  }

  throw "Cannot find required tool: $Name"
}

function Assert-CleanGit {
  Push-Location $BlogRoot
  try {
    $status = git status --porcelain
    if ($status) {
      throw "Blog repository is not clean. Commit, push, or revert existing changes before publishing.`n$status"
    }
  }
  finally {
    Pop-Location
  }
}

function Copy-ReferencedImages {
  param(
    [string]$Markdown,
    [string]$ResolvedVaultPath,
    [string]$ResolvedNotePath
  )

  $noteDir = Split-Path -Parent $ResolvedNotePath
  $attachmentDir = Join-Path $ResolvedVaultPath "attachment"
  $matches = [regex]::Matches($Markdown, '!\[\[([^\]\|#]+)(?:[|#][^\]]*)?\]\]')
  $copied = New-Object System.Collections.Generic.List[string]

  foreach ($match in $matches) {
    $fileName = $match.Groups[1].Value.Trim()
    if (-not $fileName) {
      continue
    }

    $candidates = @(
      (Join-Path $attachmentDir $fileName),
      (Join-Path $noteDir $fileName),
      (Join-Path $ResolvedVaultPath $fileName)
    )

    $source = $null
    foreach ($candidate in $candidates) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $source = (Resolve-Path -LiteralPath $candidate).Path
        break
      }
    }

    if (-not $source) {
      throw "Referenced image not found: $fileName"
    }

    $target = Join-Path $StagingAttachmentsDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $target -Force
    $copied.Add($target) | Out-Null
  }

  return $copied
}

function Invoke-HugoBuild {
  param([string]$HugoExe)

  Push-Location $BlogRoot
  try {
    & $HugoExe --printI18nWarnings --printPathWarnings
    if ($LASTEXITCODE -ne 0) {
      throw "Hugo build failed."
    }
  }
  finally {
    Pop-Location
  }
}

function Play-DoneSound {
  try {
    [System.Media.SystemSounds]::Asterisk.Play()
  }
  catch {
    # Sound is best-effort only.
  }
}

New-Item -ItemType Directory -Force -Path $LogDir, $StagingDir, $StagingAttachmentsDir | Out-Null
$LogPath = Join-Path $LogDir ("publish-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $LogPath -Force | Out-Null

try {
  Write-Step "Preparing publish job..."
  $ResolvedNotePath = Resolve-ExistingPath $NotePath
  if (-not $VaultPath) {
    throw "VaultPath is required. Pass -VaultPath from Obsidian or set it in the Shell Commands configuration."
  }
  $ResolvedVaultPath = Resolve-ExistingPath $VaultPath

  if (-not $ResolvedNotePath.StartsWith($ResolvedVaultPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The note is not inside the configured Obsidian vault: $ResolvedVaultPath"
  }

  Assert-CleanGit

  Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $StagingDir, $StagingAttachmentsDir | Out-Null

  $markdown = Get-Content -LiteralPath $ResolvedNotePath -Raw -Encoding UTF8
  $stagedNote = Join-Path $StagingDir "source.md"
  Set-Content -LiteralPath $stagedNote -Value $markdown -Encoding UTF8
  $copiedImages = Copy-ReferencedImages -Markdown $markdown -ResolvedVaultPath $ResolvedVaultPath -ResolvedNotePath $ResolvedNotePath

  $CodexExe = Find-Tool -Name "codex" -FallbackPattern "$env:LOCALAPPDATA\Microsoft\WindowsApps"
  $HugoExe = Find-Tool -Name "hugo" -FallbackPattern "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hugo.Hugo.Extended_Microsoft.Winget.Source_8wekyb3d8bbwe"

  $promptTemplate = Get-Content -LiteralPath $PromptPath -Raw -Encoding UTF8
  $publishDate = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"
  $dryRunText = if ($DryRun) { "Dry run is enabled. Create files for inspection, but the wrapper will not commit or push." } else { "Dry run is disabled. Prepare the post for publishing." }
  $imageList = if ($copiedImages.Count -gt 0) { ($copiedImages -join "`n") } else { "(no images copied)" }

  $prompt = @(
    $promptTemplate,
    "",
    "Publish job inputs:",
    "",
    "- Blog root: $BlogRoot",
    "- Staged note: $stagedNote",
    "- Staged attachments directory: $StagingAttachmentsDir",
    "- Original Obsidian note path: $ResolvedNotePath",
    "- Obsidian vault path: $ResolvedVaultPath",
    "- Publish date: $publishDate",
    "- Mode: $dryRunText",
    "",
    "Copied attachment files:",
    "",
    $imageList
  ) -join "`n"

  Write-Step "Running Codex conversion..."
  Push-Location $BlogRoot
  try {
    & $CodexExe exec --cd $BlogRoot --sandbox workspace-write --ask-for-approval never --output-last-message $FinalMessagePath $prompt
    if ($LASTEXITCODE -ne 0) {
      throw "Codex conversion failed."
    }
  }
  finally {
    Pop-Location
  }

  if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
    throw "Codex did not write .publish-staging/result.json"
  }

  $result = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($result.status -ne "ready") {
    throw "Codex blocked publishing: $($result.reason)"
  }

  Write-Step "Running Hugo build..."
  Invoke-HugoBuild -HugoExe $HugoExe

  if ($DryRun) {
    Write-Step "Dry run complete. No commit or push was performed."
    Play-DoneSound
    exit 0
  }

  Write-Step "Committing and pushing..."
  Push-Location $BlogRoot
  try {
    git add -- content/posts
    $gitStatus = git status --porcelain
    if (-not $gitStatus) {
      throw "No publish changes were created."
    }

    $title = if ($result.title) { [string]$result.title } else { "Obsidian post" }
    git commit -m "Publish post: $title"
    if ($LASTEXITCODE -ne 0) {
      throw "Git commit failed."
    }

    git push origin main
    if ($LASTEXITCODE -ne 0) {
      throw "Git push failed."
    }
  }
  finally {
    Pop-Location
  }

  Write-Step "Published successfully: $($result.title)"
  Write-Step "Log: $LogPath"
  Play-DoneSound
}
catch {
  Write-Error $_
  Write-Step "Publish failed. Log: $LogPath"
  try {
    [System.Media.SystemSounds]::Hand.Play()
  }
  catch {}
  exit 1
}
finally {
  Stop-Transcript | Out-Null
}
