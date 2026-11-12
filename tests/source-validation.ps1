# Run in Windows PowerShell 5.1 in CI for the authoritative language parser.
# On PowerShell 7, also reject syntax nodes/operators introduced after 5.1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem (Join-Path $repo 'scripts'), (Join-Path $repo 'tests') -Filter '*.ps1' -File)
foreach ($file in $files) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {
        throw "$($file.Name): UTF-8 BOM is required for Windows PowerShell 5.1."
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    if ($text -match '(?<!\r)\n|\r(?!\n)') { throw "$($file.Name): CRLF is required." }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "$($file.Name): $($parseErrors | Out-String)" }
    $newNodes = @($ast.FindAll({ param($node)
        $node.GetType().Name -in @('TernaryExpressionAst', 'PipelineChainAst') -or
        ($node.PSObject.Properties['NullConditional'] -and $node.NullConditional)
    }, $true))
    $newOperators = @($tokens | Where-Object {
        $_.Kind.ToString() -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr')
    })
    if ($newNodes.Count -gt 0 -or $newOperators.Count -gt 0) { throw "$($file.Name): syntax newer than PowerShell 5.1 found." }
    Write-Host "PASS $($file.Name): BOM, CRLF, syntax"
}
foreach ($file in Get-ChildItem -LiteralPath $repo -Filter '*.bat' -File) {
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text -match '(?<!\r)\n|\r(?!\n)') { throw "$($file.Name): CRLF is required." }
    Write-Host "PASS $($file.Name): CRLF"
}
Write-Host "$($files.Count) PowerShell sources checked on $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))."
