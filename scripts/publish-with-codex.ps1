param(
  [Parameter(Mandatory = $true)]
  [string]$NotePath,

  [string]$VaultPath = "",

  [switch]$DryRun,

  [switch]$AllowCodexProcessing
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
$CodexOutputPath = Join-Path $StagingDir "codex-output.log"
$HugoOutputPath = Join-Path $StagingDir "hugo-output.log"
$GitOutputPath = Join-Path $StagingDir "git-output.log"
$StepLogPath = $null

function Write-Step {
  param([string]$Message)
  $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
  if ($script:StepLogPath) {
    Add-Content -LiteralPath $script:StepLogPath -Value $line -Encoding UTF8
  }
  else {
    Write-Host $line
  }
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
  param(
    [string]$HugoExe,
    [string]$OutputPath
  )

  Push-Location $BlogRoot
  $previousErrorActionPreference = $null
  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $HugoExe --printI18nWarnings --printPathWarnings *> $OutputPath
    $hugoExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($hugoExitCode -ne 0) {
      throw "Hugo build failed. See: $OutputPath"
    }
  }
  finally {
    if ($previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    Pop-Location
  }
}

function Copy-StagedImagesToPost {
  param(
    [object]$Result,
    [object[]]$CopiedImages
  )

  $postPath = Join-Path $BlogRoot ([string]$Result.postPath)
  if (-not (Test-Path -LiteralPath $postPath -PathType Leaf)) {
    throw "Published post file was not created: $postPath"
  }

  $postDir = Split-Path -Parent $postPath
  foreach ($image in $CopiedImages) {
    $target = Join-Path $postDir (Split-Path -Leaf ([string]$image))
    Copy-Item -LiteralPath ([string]$image) -Destination $target -Force
  }
}

function Get-PublishedPostTitle {
  param([object]$Result)

  $postPath = Join-Path $BlogRoot ([string]$Result.postPath)
  if (Test-Path -LiteralPath $postPath -PathType Leaf) {
    $postMarkdown = Get-Content -LiteralPath $postPath -Raw -Encoding UTF8
    $match = [regex]::Match($postMarkdown, '(?m)^title:\s*"?([^"\r\n]+)"?\s*$')
    if ($match.Success) {
      return $match.Groups[1].Value.Trim()
    }
  }

  if ($Result.title) {
    return [string]$Result.title
  }

  return "Obsidian post"
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
$StepLogPath = Join-Path $LogDir ("publish-{0}-steps.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
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

  if (-not $AllowCodexProcessing) {
    throw "Refusing to send note content to Codex. Re-run with -AllowCodexProcessing when this command is bound to an explicit publish button."
  }

  Assert-CleanGit

  Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $StagingDir, $StagingAttachmentsDir | Out-Null

  $markdown = Get-Content -LiteralPath $ResolvedNotePath -Raw -Encoding UTF8
  $stagedNote = Join-Path $StagingDir "source.md"
  Set-Content -LiteralPath $stagedNote -Value $markdown -Encoding UTF8
  $copiedImages = @(Copy-ReferencedImages -Markdown $markdown -ResolvedVaultPath $ResolvedVaultPath -ResolvedNotePath $ResolvedNotePath)

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
  $previousErrorActionPreference = $null
  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    "" | & $CodexExe exec --cd $BlogRoot --sandbox workspace-write --output-last-message $FinalMessagePath $prompt *> $CodexOutputPath
    $codexExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($codexExitCode -ne 0) {
      throw "Codex conversion failed. See: $CodexOutputPath"
    }
  }
  finally {
    if ($previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    Pop-Location
  }

  if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
    throw "Codex did not write .publish-staging/result.json"
  }

  $result = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($result.status -ne "ready") {
    throw "Codex blocked publishing: $($result.reason)"
  }
  $publishedTitle = Get-PublishedPostTitle -Result $result

  Write-Step "Copying images into post bundle..."
  Copy-StagedImagesToPost -Result $result -CopiedImages $copiedImages

  Write-Step "Running Hugo build..."
  Invoke-HugoBuild -HugoExe $HugoExe -OutputPath $HugoOutputPath

  if ($DryRun) {
    Write-Host "Dry run complete: $publishedTitle"
    Play-DoneSound
    exit 0
  }

  Write-Step "Committing and pushing..."
  Push-Location $BlogRoot
  $previousErrorActionPreference = $null
  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    git add -- content/posts *> $GitOutputPath
    $gitStatus = git status --porcelain
    if (-not $gitStatus) {
      throw "No publish changes were created."
    }

    git commit -m "Publish post: $publishedTitle" *>> $GitOutputPath
    $commitExitCode = $LASTEXITCODE
    if ($commitExitCode -ne 0) {
      throw "Git commit failed. See: $GitOutputPath"
    }

    git push origin main *>> $GitOutputPath
    $pushExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($pushExitCode -ne 0) {
      throw "Git push failed. See: $GitOutputPath"
    }
  }
  finally {
    if ($previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    Pop-Location
  }

  Write-Step "Published successfully: $publishedTitle"
  Write-Step "Log: $LogPath"
  Write-Host "发布成功：$publishedTitle"
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
