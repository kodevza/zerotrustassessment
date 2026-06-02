param(
    [string] $InputPath = "ZeroTrustReport99/zt-export/ZeroTrustAssessmentReport.json",
    [string] $OutputPath = "ZeroTrustReport99/zt-export/ZeroTrustAssessmentTests.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file not found: $InputPath"
}

$report = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $report.Tests) {
    throw "The input file does not contain a 'Tests' array: $InputPath"
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$columns = @(
    "TestStatus",
    "TestResult",
    "TestCategory",
    "TestPillar",
    "TestAppliesTo",
    # "SkippedReason",
    "TestTags",
    # "TestTitle",
    # "TestMinimumLicense",
    "TestSfiPillar",
    "TestImpact",
    "TestRisk"
)

$rows = foreach ($test in $report.Tests) {
    $row = [ordered]@{}

    foreach ($column in $columns) {
        $value = $test.$column

        if ($null -eq $value) {
            $value = ""
        }
        elseif ($value -is [array]) {
            $value = ($value | ForEach-Object { $_ }) -join "; "
        }

        $row[$column] = $value
    }

    [pscustomobject]$row
}

$rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "CSV exported to: $OutputPath"
