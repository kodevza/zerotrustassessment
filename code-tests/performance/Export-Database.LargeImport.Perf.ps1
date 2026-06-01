<#
.SYNOPSIS
    Opt-in large DuckDB import harness for Export-Database internals.

.DESCRIPTION
    Generates Graph-style JSON files for one table and imports them through the
    same Import-EntraTable/New-EntraTable path used by Export-Database.

    This script is intentionally outside code-tests/commands and requires
    ZTA_RUN_LARGE_DB_IMPORT=1 for runs larger than 1GB.

.EXAMPLE
    pwsh -NoLogo -NoProfile -File code-tests/performance/Export-Database.LargeImport.Perf.ps1 -TargetGB 1

.EXAMPLE
    ZTA_RUN_LARGE_DB_IMPORT=1 pwsh -NoLogo -NoProfile -File code-tests/performance/Export-Database.LargeImport.Perf.ps1 -TargetGB 40 -KeepOutput

.EXAMPLE
    pwsh -NoLogo -NoProfile -File code-tests/performance/Export-Database.LargeImport.Perf.ps1 -TargetGB 40 -PreflightOnly
#>
[CmdletBinding()]
param (
    [ValidateRange(1, 1024)]
    [int]
    $TargetGB = 40,

    [ValidateRange(16, 256)]
    [int]
    $PageMB = 128,

    [string]
    $WorkPath = (Join-Path ([System.IO.Path]::GetTempPath()) "zta-large-db-import"),

    [double]
    $RequiredFreeMultiplier = 2.2,

    [switch]
    $PreflightOnly,

    [switch]
    $KeepOutput
)

$ErrorActionPreference = 'Stop'

function Get-AvailableBytes {
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Path
    )

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    $drive = [System.IO.DriveInfo]::new($root)
    $drive.AvailableFreeSpace
}

function Format-Bytes {
    param (
        [Parameter(Mandatory = $true)]
        [long]
        $Bytes
    )

    if ($Bytes -ge 1TB) { return ('{0:n2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:n2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:n2} MB' -f ($Bytes / 1MB)) }
    return "$Bytes B"
}

function New-LargeServicePrincipalExport {
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $ExportPath,

        [Parameter(Mandatory = $true)]
        [long]
        $TargetBytes,

        [Parameter(Mandatory = $true)]
        [long]
        $PageBytes
    )

    $tablePath = Join-Path $ExportPath 'ServicePrincipal'
    $null = New-Item -ItemType Directory -Path $tablePath -Force

    $fileIndex = 0
    $totalBytes = 0L
    while ($totalBytes -lt $TargetBytes) {
        $filePath = Join-Path $tablePath ("ServicePrincipal-{0}.json" -f $fileIndex)
        $writer = [System.IO.StreamWriter]::new($filePath, $false, [System.Text.UTF8Encoding]::new($false), 1048576)
        try {
            $writer.Write('{"value":[')
            $isFirst = $true
            while (($writer.BaseStream.Length -lt $PageBytes) -and (($totalBytes + $writer.BaseStream.Length) -lt $TargetBytes)) {
                if (-not $isFirst) { $writer.Write(',') }
                $isFirst = $false

                $id = [guid]::NewGuid().ToString()
                $blob = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
                $writer.Write(('{0}"id":"{1}","appId":"{1}","displayName":"Synthetic SP {2}","servicePrincipalType":"Application","accountEnabled":true,"tags":["WindowsAzureActiveDirectoryIntegratedApp"],"customSecurityAttributes":{{"load":{{"blob":"{3}"}}}}{4}' -f '{', $id, $fileIndex, $blob, '}'))
            }
            $writer.Write(']}')
        }
        finally {
            $writer.Dispose()
        }

        $fileSize = (Get-Item $filePath).Length
        $totalBytes += $fileSize
        Write-Host ("Generated {0} ({1}); total {2}" -f $filePath, (Format-Bytes $fileSize), (Format-Bytes $totalBytes))
        $fileIndex++
    }
}

$targetBytes = [int64]$TargetGB * 1GB
$pageBytes = [int64]$PageMB * 1MB
$requiredBytes = [int64]($targetBytes * $RequiredFreeMultiplier)

$null = New-Item -ItemType Directory -Path $WorkPath -Force
$availableBytes = Get-AvailableBytes -Path $WorkPath

Write-Host ("Work path: {0}" -f (Resolve-Path $WorkPath))
Write-Host ("Target JSON size: {0}" -f (Format-Bytes $targetBytes))
Write-Host ("Available free space: {0}" -f (Format-Bytes $availableBytes))
Write-Host ("Required free space: {0} ({1}x target)" -f (Format-Bytes $requiredBytes), $RequiredFreeMultiplier)

if ($availableBytes -lt $requiredBytes) {
    throw "Not enough free space for the large import test. Choose a larger -WorkPath or lower -TargetGB."
}

if ($PreflightOnly) {
    Write-Host 'Preflight passed.'
    return
}

if ($TargetGB -gt 1 -and $env:ZTA_RUN_LARGE_DB_IMPORT -ne '1') {
    throw "Set ZTA_RUN_LARGE_DB_IMPORT=1 to run imports larger than 1GB."
}

$runPath = Join-Path $WorkPath ("run-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
$exportPath = Join-Path $runPath 'zt-export'
$dbPath = Join-Path $exportPath 'db/zt.db'

try {
    $null = New-Item -ItemType Directory -Path $exportPath -Force
    New-LargeServicePrincipalExport -ExportPath $exportPath -TargetBytes $targetBytes -PageBytes $pageBytes

    $srcRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../src/powershell')).Path
    if (-not (Get-Module ZeroTrustAssessment -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $srcRoot 'ZeroTrustAssessment.psd1') -Global 3>$null
        Import-Module (Join-Path $srcRoot 'ZeroTrustAssessment.psm1') -Global -Force 3>$null
    }

    $dbFolder = Split-Path $dbPath -Parent
    $null = New-Item -ItemType Directory -Path $dbFolder -Force
    $database = Connect-Database -Path $dbPath -Transient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Import-EntraTable -Database $database -ExportPath $exportPath -TableName 'ServicePrincipal'
        $row = Invoke-DatabaseQuery -Database $database -Sql 'select count(*) as count from ServicePrincipal;' | Select-Object -First 1
    }
    finally {
        $sw.Stop()
        if ($database) { Disconnect-Database -Database $database -ErrorAction SilentlyContinue }
    }

    Write-Host ("Imported rows: {0}" -f $row.count)
    Write-Host ("Import duration: {0}" -f $sw.Elapsed)
    Write-Host ("Database size: {0}" -f (Format-Bytes ((Get-Item $dbPath).Length)))
}
finally {
    if (-not $KeepOutput -and (Test-Path $runPath)) {
        Remove-Item $runPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
