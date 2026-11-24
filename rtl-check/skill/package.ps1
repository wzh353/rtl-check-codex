#requires -Version 7.2

[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$toolkit = Split-Path -Parent $PSScriptRoot
$workspace = Split-Path -Parent $toolkit
$name = 'rtl-check-repair'
$source = Join-Path $PSScriptRoot $name
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$runtimeDirectories = @('lib', 'examples', 'tests', 'mcp')
$runtimePaths = $runtimeDirectories | ForEach-Object { Join-Path $toolkit $_ }
foreach ($inputDirectory in (@($source) + $runtimePaths)) {
    $relative = [IO.Path]::GetRelativePath($inputDirectory, $output)
    if (-not [IO.Path]::IsPathRooted($relative) -and $relative -notmatch '^\.\.(?:[/\\]|$)') {
        throw 'Output must be outside packaged source directories.'
    }
}
$bundle = Join-Path $output $name
$archive = Join-Path $output "$name.zip"
if ((Test-Path -LiteralPath $bundle) -or (Test-Path -LiteralPath $archive)) {
    throw 'The output already contains an RTL skill package. Use a new output directory.'
}
$utf8 = [Text.UTF8Encoding]::new($false, $true)
foreach ($metadata in @('SKILL.md', 'agents/openai.yaml')) {
    $null = $utf8.GetString([IO.File]::ReadAllBytes((Join-Path $source $metadata)))
}

function Copy-RtlSkillTree([string]$From, [string]$To) {
    $null = [IO.Directory]::CreateDirectory($To)
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        if ($item.Name -in @('.git', '.codex', '.codex-attachments', 'node_modules', 'tmp', '__pycache__') -or
            $item.Name -like '.rtlcheck*') { continue }
        # All three CLI entry points use this directory name, including with a custom OutDir.
        if ($item.PSIsContainer -and $item.Name -match '^\d{8}-\d{6}-[a-f0-9]{8}$') { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The installable skill cannot contain linked payload files: $($item.FullName)"
        }
        $destination = Join-Path $To $item.Name
        if ($item.PSIsContainer) { Copy-RtlSkillTree $item.FullName $destination }
        else { [IO.File]::Copy($item.FullName, $destination) }
    }
}

Copy-RtlSkillTree $source $bundle
$payload = Join-Path $bundle 'scripts/rtl-check'
$null = [IO.Directory]::CreateDirectory($payload)
foreach ($file in @('rtl-check.ps1', 'rtl-batch.ps1', 'rtl-evaluate.ps1', 'repair-response.schema.json')) {
    [IO.File]::Copy((Join-Path $toolkit $file), (Join-Path $payload $file))
}
foreach ($directory in $runtimeDirectories) {
    Copy-RtlSkillTree (Join-Path $toolkit $directory) (Join-Path $payload $directory)
}

$guide = [IO.File]::ReadAllText((Join-Path $workspace 'documents/RTL 检查与 Codex 自动修复.md'))
$localMcp = '(?m)^本工作区的 \[Codex 项目配置\]\([^\r\n]*'
$portableMcp = '独立工程可以通过以下命令为单次会话连接 MCP。把 `$toolkitRoot` 换成 Skill 中 `scripts/rtl-check` 的绝对路径。'
$guide = [regex]::Replace($guide, $localMcp, $portableMcp)
$guide = $guide.Replace('../rtl-check/', '../scripts/rtl-check/').Replace('D:/Modelsim/win64', 'C:/EDA/ModelSim/win64')
$guide = $guide.Replace('从项目根目录运行', '从 Skill 的 `scripts/` 目录运行')
$references = Join-Path $bundle 'references'
$null = [IO.Directory]::CreateDirectory($references)
[IO.File]::WriteAllText((Join-Path $references 'project-guide.md'), $guide)

[IO.Compression.ZipFile]::CreateFromDirectory($bundle, $archive, [IO.Compression.CompressionLevel]::Optimal, $true)
[ordered]@{
    skillDirectory = $bundle
    archive = $archive
    archiveSha256 = (Get-FileHash -LiteralPath $archive).Hash
} | ConvertTo-Json -Compress
