<#
.SYNOPSIS
    Tests the current New-EntraTable implementation with the generated User collection.

.DESCRIPTION
    Imports the current ZeroTrustAssessment module from src/powershell, creates a
    temporary DuckDB database, calls New-EntraTable with the generated User JSON
    wildcard path, and validates the imported row count.

.PARAMETER UserCollectionPath
    Directory containing generated User-*.json files.

.PARAMETER DatabasePath
    Temporary DuckDB database path used for the test.

.PARAMETER ExpectedRows
    Expected number of imported rows. Defaults to 999000.

.PARAMETER KeepDatabase
    Keep the generated DuckDB database after the test.

.EXAMPLE
    ./build/tools/Test-NewEntraTableUserGenerated.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string] $UserCollectionPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../ZeroTrustReport99/zt-export/User-generated'),

    [Parameter()]
    [string] $DatabasePath = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'zta-user-new-entra-table-current.db'),

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ExpectedRows = 999000,

    [Parameter()]
    [switch] $KeepDatabase
)

$ErrorActionPreference = 'Stop'

Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.ImportBatchSize' -Value 20

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
$srcRoot = Join-Path -Path $repoRoot -ChildPath 'src/powershell'
$resolvedUserCollectionPath = (Resolve-Path -Path $UserCollectionPath).Path
$userFilePath = Join-Path -Path $resolvedUserCollectionPath -ChildPath 'User-*.json'
$resolvedDatabasePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DatabasePath)

$userFiles = @(Get-ChildItem -Path $resolvedUserCollectionPath -Filter 'User-*.json' -File)
if ($userFiles.Count -eq 0) {
    throw "No User-*.json files found in $resolvedUserCollectionPath"
}

Write-Host "Importing module from: $srcRoot"
Import-Module (Join-Path -Path $srcRoot -ChildPath 'ZeroTrustAssessment.psd1') -Global 3>$null
Import-Module (Join-Path -Path $srcRoot -ChildPath 'ZeroTrustAssessment.psm1') -Global -Force 3>$null

Set-StrictMode -Version Latest

Remove-Item -Path $resolvedDatabasePath, "$resolvedDatabasePath.tmp" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "User files: $($userFiles.Count)"
Write-Host "User path:  $userFilePath"
Write-Host "Database:   $resolvedDatabasePath"

$database = $null
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $database = Connect-Database -Path $resolvedDatabasePath -Transient

    # This intentionally uses the current New-EntraTable signature: one wildcard string.
    New-EntraTable -Database $database -TableName 'User' -FilePath $userFilePath

    $row = Invoke-DatabaseQuery -Database $database -Sql 'select count(*) as count from User;' | Select-Object -First 1
    $sample = Invoke-DatabaseQuery -Database $database -Sql 'select userPrincipalName from User order by userPrincipalName limit 1;' | Select-Object -First 1

    Write-Host "Rows:      $($row.count)"
    Write-Host "First UPN: $($sample.userPrincipalName)"

    if ([int]$row.count -ne $ExpectedRows) {
        throw "Expected $ExpectedRows rows, got $($row.count)."
    }
}
finally {
    $stopwatch.Stop()

    if ($database) {
        Disconnect-Database -Database $database -ErrorAction SilentlyContinue
    }

    Write-Host "Duration:  $($stopwatch.Elapsed)"

    if (-not $KeepDatabase) {
        Remove-Item -Path $resolvedDatabasePath, "$resolvedDatabasePath.tmp" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'New-EntraTable generated User collection test passed.'
