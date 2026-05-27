<#
.SYNOPSIS
    Opt-in performance harness for Export-ZtGraphEntity.

.DESCRIPTION
    This file intentionally lives outside code-tests/commands so code-tests/pester.ps1
    does not run it by default. All Graph calls are mocked.

.EXAMPLE
    # Smoke run with 10k generated Application objects.
    pwsh -NoLogo -NoProfile -File code-tests/performance/Export-ZtGraphEntity.Perf.Tests.ps1

.EXAMPLE
    # Full run with 1.7M generated Application objects. This is guarded for CI.
    ZTA_RUN_FULL_PERF=1 pwsh -NoLogo -NoProfile -File code-tests/performance/Export-ZtGraphEntity.Perf.Tests.ps1 -Full

.EXAMPLE
    # Keep generated JSON files for inspection.
    pwsh -NoLogo -NoProfile -File code-tests/performance/Export-ZtGraphEntity.Perf.Tests.ps1 -KeepOutput
#>
[CmdletBinding()]
param (
    [int]
    $ObjectCount = 0,

    [int]
    $PageSize = 999,

    [switch]
    $Full,

    [switch]
    $KeepOutput,

    [switch]
    $RunPesterInternal
)

$ErrorActionPreference = 'Stop'

if (-not $RunPesterInternal) {
    if ($PageSize -lt 1) {
        throw "PageSize must be greater than zero."
    }

    $resolvedObjectCount = if ($ObjectCount -gt 0) { $ObjectCount } elseif ($Full -or $env:ZTA_RUN_FULL_PERF -eq '1') { 1700000 } else { 10000 }
    if ($resolvedObjectCount -ge 1700000 -and $env:ZTA_RUN_FULL_PERF -ne '1') {
        throw "The full Export-ZtGraphEntity performance run requires ZTA_RUN_FULL_PERF=1."
    }

    Import-Module Pester -Global 3>$null

    $container = New-PesterContainer -Path $PSCommandPath -Data @{
        ObjectCount       = $resolvedObjectCount
        PageSize          = $PageSize
        KeepOutput        = $KeepOutput.IsPresent
        RunPesterInternal = $true
    }

    $config = [PesterConfiguration]::Default
    $config.Run.Container = $container
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $false

    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0) {
        exit 1
    }
    exit 0
}

Describe "Export-ZtGraphEntity performance harness" {
    BeforeAll {
        $srcRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../src/powershell")).Path
        if (-not (Get-Module ZeroTrustAssessment -ErrorAction SilentlyContinue)) {
            try {
                Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psd1") -Global 3>$null
            }
            catch {
                Write-Verbose "Continuing after manifest import warning: $($_.Exception.Message)"
            }
            Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psm1") -Global -Force 3>$null
        }
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
            function global:Get-MgContext {}
        }

        $modelPath = Join-Path $srcRoot "assets/export-model/Application-model.json"
        $model = Get-Content -Path $modelPath -Raw | ConvertFrom-Json -AsHashtable
        $script:applicationTemplate = $model.value[0]
        if (-not $script:applicationTemplate) {
            throw "Application model template not found at $modelPath."
        }

        $templateJson = $script:applicationTemplate | ConvertTo-Json -Depth 100 -Compress
        $script:targetObjectBytes = 10KB
        $script:payloadLength = [Math]::Max(0, $script:targetObjectBytes - $templateJson.Length - 256)
        $script:payload = 'x' * $script:payloadLength

        $script:exportPath = Join-Path ([System.IO.Path]::GetTempPath()) "zt-perf-graphentity-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:exportPath -Force | Out-Null

        $script:perf = [ordered]@{
            ObjectCount               = $ObjectCount
            PageSize                  = $PageSize
            ExpectedPageCount         = [int][Math]::Ceiling($ObjectCount / [double]$PageSize)
            ActualPageCount           = 0
            JsonFileCount             = 0
            OutputBytes               = 0
            OutputPath                = $script:exportPath
            ApproxObjectJsonBytes     = 0
            Elapsed                   = $null
            WorkingSetBeforeBytes     = 0
            WorkingSetAfterBytes      = 0
            PeakWorkingSetBytes       = 0
            PrivateMemoryBeforeBytes  = 0
            PrivateMemoryAfterBytes   = 0
            PeakPrivateMemoryBytes    = 0
            GcMemoryBeforeBytes       = 0
            GcMemoryAfterBytes        = 0
            GcMemoryAfterCollectBytes = 0
        }

        function New-ZtPerfApplication {
            param (
                [int]
                $Index
            )

            $item = @{}
            foreach ($key in $script:applicationTemplate.Keys) {
                $item[$key] = $script:applicationTemplate[$key]
            }

            $guid = [Guid]::NewGuid().ToString()
            $appGuid = [Guid]::NewGuid().ToString()
            $item['id'] = $guid
            $item['appId'] = $appGuid
            $item['displayName'] = "ZT Perf Application {0:D7}" -f $Index
            $item['createdDateTime'] = [DateTimeOffset]::UtcNow.AddSeconds(-1 * $Index).ToString('o')
            $item['ztPerfPayload'] = $script:payload
            return $item
        }

        function New-ZtPerfGraphPage {
            param (
                [int]
                $Offset
            )

            $remaining = $ObjectCount - $Offset
            $count = [Math]::Min($PageSize, $remaining)
            $items = [object[]]::new($count)
            for ($index = 0; $index -lt $count; $index++) {
                $items[$index] = New-ZtPerfApplication -Index ($Offset + $index)
            }

            if ($script:perf.ApproxObjectJsonBytes -eq 0 -and $count -gt 0) {
                $script:perf.ApproxObjectJsonBytes = ($items[0] | ConvertTo-Json -Depth 100 -Compress).Length
            }

            $page = @{
                '@odata.context' = 'https://graph.microsoft.com/beta/$metadata#applications'
                value            = @($items)
            }

            $nextOffset = $Offset + $count
            if ($nextOffset -lt $ObjectCount) {
                $page['@odata.nextLink'] = "beta/applications?`$skiptoken=$nextOffset"
            }

            $script:perf.ActualPageCount++
            $process = [System.Diagnostics.Process]::GetCurrentProcess()
            $script:perf.PeakWorkingSetBytes = [Math]::Max($script:perf.PeakWorkingSetBytes, $process.WorkingSet64)
            $script:perf.PeakPrivateMemoryBytes = [Math]::Max($script:perf.PeakPrivateMemoryBytes, $process.PrivateMemorySize64)
            return $page
        }
    }

    AfterAll {
        if (-not $script:exportPath) {
            return
        }

        if (-not $KeepOutput) {
            Remove-Item $script:exportPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "Kept performance output at: $script:exportPath"
        }
    }

    BeforeEach {
        $script:nextOffset = 0

        Mock -ModuleName ZeroTrustAssessment Get-ZtConfig { return $false }
        Mock -ModuleName ZeroTrustAssessment Set-ZtConfig {}
        Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState {}
        Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue { return 1073741824 }
        Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { & $ScriptBlock }
        Mock -ModuleName ZeroTrustAssessment Invoke-MgGraphRequest {
            $page = New-ZtPerfGraphPage -Offset $script:nextOffset
            $script:nextOffset += $PageSize
            return $page
        }
    }

    It "exports generated Application pages through the real paging and file-writing loop" {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()

        $processBefore = [System.Diagnostics.Process]::GetCurrentProcess()
        $script:perf.WorkingSetBeforeBytes = $processBefore.WorkingSet64
        $script:perf.PrivateMemoryBeforeBytes = $processBefore.PrivateMemorySize64
        $script:perf.PeakWorkingSetBytes = $processBefore.WorkingSet64
        $script:perf.PeakPrivateMemoryBytes = $processBefore.PrivateMemorySize64
        $script:perf.GcMemoryBeforeBytes = [GC]::GetTotalMemory($false)

        $elapsed = Measure-Command {
            Export-ZtGraphEntity -Name 'Application' -Uri 'beta/applications' -QueryString '$top=999' -ExportPath $script:exportPath
        }

        $processAfter = [System.Diagnostics.Process]::GetCurrentProcess()
        $script:perf.Elapsed = $elapsed.ToString()
        $script:perf.WorkingSetAfterBytes = $processAfter.WorkingSet64
        $script:perf.PrivateMemoryAfterBytes = $processAfter.PrivateMemorySize64
        $script:perf.PeakWorkingSetBytes = [Math]::Max($script:perf.PeakWorkingSetBytes, $processAfter.WorkingSet64)
        $script:perf.PeakPrivateMemoryBytes = [Math]::Max($script:perf.PeakPrivateMemoryBytes, $processAfter.PrivateMemorySize64)
        $script:perf.GcMemoryAfterBytes = [GC]::GetTotalMemory($false)

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        $script:perf.GcMemoryAfterCollectBytes = [GC]::GetTotalMemory($false)

        $outputFiles = Get-ChildItem -Path (Join-Path $script:exportPath 'Application') -Filter '*.json' -File
        $script:perf.JsonFileCount = @($outputFiles).Count
        $script:perf.OutputBytes = ($outputFiles | Measure-Object -Property Length -Sum).Sum

        [pscustomobject]$script:perf | Format-List | Out-Host

        $script:perf.ActualPageCount | Should -Be $script:perf.ExpectedPageCount
        $script:perf.JsonFileCount | Should -Be $script:perf.ExpectedPageCount
        $script:perf.OutputBytes | Should -BeGreaterThan 0
    }
}
