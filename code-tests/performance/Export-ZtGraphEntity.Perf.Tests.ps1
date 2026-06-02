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

    [int]
    $MembersPerGroup = 1,

    [int]
    $MemorySampleInterval = 1000,

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
    if ($MembersPerGroup -lt 1) {
        throw "MembersPerGroup must be greater than zero."
    }
    if ($MemorySampleInterval -lt 1) {
        throw "MemorySampleInterval must be greater than zero."
    }

    $resolvedObjectCount = if ($ObjectCount -gt 0) { $ObjectCount } elseif ($Full -or $env:ZTA_RUN_FULL_PERF -eq '1') { 1700000 } else { 10000 }
    if ($resolvedObjectCount -ge 1700000 -and $env:ZTA_RUN_FULL_PERF -ne '1') {
        throw "The full Export-ZtGraphEntity performance run requires ZTA_RUN_FULL_PERF=1."
    }

    Import-Module Pester -Global 3>$null

    $container = New-PesterContainer -Path $PSCommandPath -Data @{
        ObjectCount       = $resolvedObjectCount
        PageSize          = $PageSize
        MembersPerGroup   = $MembersPerGroup
        MemorySampleInterval = $MemorySampleInterval
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

        $roleAssignmentModelPath = Join-Path $srcRoot "assets/export-model/RoleAssignment-model.json"
        $roleAssignmentModel = Get-Content -Path $roleAssignmentModelPath -Raw | ConvertFrom-Json -AsHashtable
        $script:roleAssignmentTemplate = $roleAssignmentModel.value[0]
        if (-not $script:roleAssignmentTemplate) {
            throw "RoleAssignment model template not found at $roleAssignmentModelPath."
        }

        $roleAssignmentScheduleInstanceModelPath = Join-Path $srcRoot "assets/export-model/RoleAssignmentScheduleInstance-model.json"
        $roleAssignmentScheduleInstanceModel = Get-Content -Path $roleAssignmentScheduleInstanceModelPath -Raw | ConvertFrom-Json -AsHashtable
        $script:roleAssignmentScheduleInstanceTemplate = $roleAssignmentScheduleInstanceModel.value[0]
        if (-not $script:roleAssignmentScheduleInstanceTemplate) {
            throw "RoleAssignmentScheduleInstance model template not found at $roleAssignmentScheduleInstanceModelPath."
        }

        $roleAssignmentGroupModelPath = Join-Path $srcRoot "assets/export-model/RoleAssignmentGroup-model.json"
        $roleAssignmentGroupModel = Get-Content -Path $roleAssignmentGroupModelPath -Raw | ConvertFrom-Json -AsHashtable
        $script:roleAssignmentGroupMemberTemplate = $roleAssignmentGroupModel.value[0]
        if (-not $script:roleAssignmentGroupMemberTemplate) {
            throw "RoleAssignmentGroup model template not found at $roleAssignmentGroupModelPath."
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
        $script:privilegedGroupPerf = @{}

        function Copy-ZtPerfHashtable {
            param (
                [hashtable]
                $InputObject
            )

            $copy = @{}
            foreach ($key in $InputObject.Keys) {
                if ($InputObject[$key] -is [hashtable]) {
                    $copy[$key] = $InputObject[$key].Clone()
                }
                else {
                    $copy[$key] = $InputObject[$key]
                }
            }
            return $copy
        }

        function Get-ZtPerfMemorySnapshot {
            $process = [System.Diagnostics.Process]::GetCurrentProcess()
            return [ordered]@{
                Timestamp          = [DateTimeOffset]::UtcNow.ToString('o')
                WorkingSetBytes    = $process.WorkingSet64
                PrivateMemoryBytes = $process.PrivateMemorySize64
                GcMemoryBytes      = [GC]::GetTotalMemory($false)
            }
        }

        function Set-ZtPerfMemoryMetric {
            param (
                [System.Collections.IDictionary]
                $Metric,

                [string]
                $Prefix,

                [System.Collections.IDictionary]
                $Snapshot
            )

            $Metric["${Prefix}Timestamp"] = $Snapshot.Timestamp
            $Metric["${Prefix}WorkingSetBytes"] = $Snapshot.WorkingSetBytes
            $Metric["${Prefix}PrivateMemoryBytes"] = $Snapshot.PrivateMemoryBytes
            $Metric["${Prefix}GcMemoryBytes"] = $Snapshot.GcMemoryBytes
        }

        function Update-ZtPerfPeakMemory {
            param (
                [System.Collections.IDictionary]
                $Metric
            )

            $snapshot = Get-ZtPerfMemorySnapshot
            $Metric['LiveSampleCount'] = [int]$Metric['LiveSampleCount'] + 1
            $Metric['PeakWorkingSetBytes'] = [Math]::Max($Metric['PeakWorkingSetBytes'], $snapshot.WorkingSetBytes)
            $Metric['PeakPrivateMemoryBytes'] = [Math]::Max($Metric['PeakPrivateMemoryBytes'], $snapshot.PrivateMemoryBytes)
            $Metric['PeakGcMemoryBytes'] = [Math]::Max($Metric['PeakGcMemoryBytes'], $snapshot.GcMemoryBytes)
        }

        function Get-ZtPerfFolderStats {
            param (
                [string]
                $Path
            )

            if (-not (Test-Path -Path $Path)) {
                return [ordered]@{
                    FileCount = 0
                    Bytes     = 0
                }
            }

            $files = Get-ChildItem -Path $Path -Filter '*.json' -File
            return [ordered]@{
                FileCount = @($files).Count
                Bytes     = [int64](($files | Measure-Object -Property Length -Sum).Sum)
            }
        }

        function Add-ZtPerfDerivedMetrics {
            param (
                [System.Collections.IDictionary]
                $Metric
            )

            $Metric['InputBytesPerObject'] = if ($Metric.ObjectCount -gt 0) { [math]::Round($Metric.InputBytes / [double]$Metric.ObjectCount, 2) } else { 0 }
            $Metric['OutputBytesPerMemberRow'] = if ($Metric.ExpectedOutputMemberRows -gt 0) { [math]::Round($Metric.OutputBytes / [double]$Metric.ExpectedOutputMemberRows, 2) } else { 0 }
            $Metric['InputBytesPerFile'] = if ($Metric.InputFileCount -gt 0) { [math]::Round($Metric.InputBytes / [double]$Metric.InputFileCount, 2) } else { 0 }
            $Metric['OutputBytesPerFile'] = if ($Metric.JsonFileCount -gt 0) { [math]::Round($Metric.OutputBytes / [double]$Metric.JsonFileCount, 2) } else { 0 }

            $Metric['InputGenerationWorkingSetDeltaBytes'] = $Metric.AfterInputGenerationWorkingSetBytes - $Metric.StartWorkingSetBytes
            $Metric['InputGenerationPrivateMemoryDeltaBytes'] = $Metric.AfterInputGenerationPrivateMemoryBytes - $Metric.StartPrivateMemoryBytes
            $Metric['InputGenerationGcMemoryDeltaBytes'] = $Metric.AfterInputGenerationGcMemoryBytes - $Metric.StartGcMemoryBytes

            $Metric['ExportWorkingSetDeltaBytes'] = $Metric.AfterExportWorkingSetBytes - $Metric.BeforeExportWorkingSetBytes
            $Metric['ExportPrivateMemoryDeltaBytes'] = $Metric.AfterExportPrivateMemoryBytes - $Metric.BeforeExportPrivateMemoryBytes
            $Metric['ExportGcMemoryDeltaBytes'] = $Metric.AfterExportGcMemoryBytes - $Metric.BeforeExportGcMemoryBytes

            $Metric['RetainedWorkingSetDeltaBytes'] = $Metric.AfterExportCollectWorkingSetBytes - $Metric.BeforeExportWorkingSetBytes
            $Metric['RetainedPrivateMemoryDeltaBytes'] = $Metric.AfterExportCollectPrivateMemoryBytes - $Metric.BeforeExportPrivateMemoryBytes
            $Metric['RetainedGcMemoryDeltaBytes'] = $Metric.AfterExportCollectGcMemoryBytes - $Metric.BeforeExportGcMemoryBytes

            $Metric['PeakWorkingSetOverBeforeExportBytes'] = $Metric.PeakWorkingSetBytes - $Metric.BeforeExportWorkingSetBytes
            $Metric['PeakPrivateMemoryOverBeforeExportBytes'] = $Metric.PeakPrivateMemoryBytes - $Metric.BeforeExportPrivateMemoryBytes
            $Metric['PeakGcMemoryOverBeforeExportBytes'] = $Metric.PeakGcMemoryBytes - $Metric.BeforeExportGcMemoryBytes
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

        function New-ZtPerfRoleAssignment {
            param (
                [int]
                $Index,

                [hashtable]
                $Template
            )

            $item = Copy-ZtPerfHashtable -InputObject $Template
            $groupId = [Guid]::NewGuid().ToString()
            $roleDefinitionId = [Guid]::NewGuid().ToString()

            $item['id'] = [Guid]::NewGuid().ToString()
            $item['principalId'] = $groupId
            $item['roleDefinitionId'] = $roleDefinitionId
            if ($item.ContainsKey('assignmentType')) {
                $item['assignmentType'] = 'Assigned'
            }
            if ($item.ContainsKey('memberType')) {
                $item['memberType'] = 'Direct'
            }
            if ($item.ContainsKey('status')) {
                $item['status'] = 'Provisioned'
            }

            $item['principal']['@odata.type'] = '#microsoft.graph.group'
            $item['principal']['id'] = $groupId
            $item['principal']['displayName'] = "ZT Perf Privileged Group {0:D7}" -f $Index
            return $item
        }

        function New-ZtPerfGroupMember {
            param (
                [guid]
                $GroupId,

                [int]
                $MemberIndex
            )

            $member = Copy-ZtPerfHashtable -InputObject $script:roleAssignmentGroupMemberTemplate
            $member['@odata.type'] = '#microsoft.graph.user'
            $member['id'] = [Guid]::NewGuid().ToString()
            $member['displayName'] = "ZT Perf Member $GroupId $MemberIndex"
            $member['userPrincipalName'] = "zt-perf-$GroupId-$MemberIndex@example.invalid"
            $member.Remove('privilegedGroupId')
            $member.Remove('roleDefinitionId')
            return $member
        }

        function New-ZtPerfRoleAssignmentInput {
            param (
                [string]
                $InputName,

                [hashtable]
                $Template
            )

            $folderPath = Join-Path -Path $script:exportPath -ChildPath $InputName
            Clear-ZtFolder -Path $folderPath

            $pageIndex = 0
            for ($offset = 0; $offset -lt $ObjectCount; $offset += $PageSize) {
                $remaining = $ObjectCount - $offset
                $count = [Math]::Min($PageSize, $remaining)
                $items = [object[]]::new($count)
                for ($index = 0; $index -lt $count; $index++) {
                    $items[$index] = New-ZtPerfRoleAssignment -Index ($offset + $index) -Template $Template
                }

                $filePath = Join-Path -Path $folderPath -ChildPath "$InputName-$pageIndex.json"
                @{ value = @($items) } | Export-PSFJson -Path $filePath -Depth 100 -Encoding UTF8NoBom
                $pageIndex++
            }
        }

        function Invoke-ZtPerfPrivilegedGroupExport {
            param (
                [string]
                $InputName,

                [string]
                $Name,

                [hashtable]
                $Template
            )

            $metric = [ordered]@{
                ObjectCount               = $ObjectCount
                PageSize                  = $PageSize
                MembersPerGroup           = $MembersPerGroup
                ExpectedPageCount         = [int][Math]::Ceiling($ObjectCount / [double]$PageSize)
                ExpectedOutputMemberRows  = $ObjectCount * $MembersPerGroup
                GroupMemberCallCount      = 0
                ReturnedMemberCount       = 0
                LiveSampleCount           = 0
                InputFileCount            = 0
                InputBytes                = 0
                JsonFileCount             = 0
                OutputBytes               = 0
                ExportRootPath            = $script:exportPath
                InputPath                 = Join-Path -Path $script:exportPath -ChildPath $InputName
                OutputPath                = Join-Path -Path $script:exportPath -ChildPath $Name
                InputGenerationElapsed    = $null
                ExportElapsed             = $null
                TotalElapsed              = $null
                PeakWorkingSetBytes       = 0
                PeakPrivateMemoryBytes    = 0
                PeakGcMemoryBytes         = 0
            }

            $totalElapsed = [System.Diagnostics.Stopwatch]::StartNew()

            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect()

            Set-ZtPerfMemoryMetric -Metric $metric -Prefix 'Start' -Snapshot (Get-ZtPerfMemorySnapshot)

            $inputGenerationElapsed = Measure-Command {
                New-ZtPerfRoleAssignmentInput -InputName $InputName -Template $Template
            }
            $metric.InputGenerationElapsed = $inputGenerationElapsed.ToString()
            $inputStats = Get-ZtPerfFolderStats -Path $metric.InputPath
            $metric.InputFileCount = $inputStats.FileCount
            $metric.InputBytes = $inputStats.Bytes
            Set-ZtPerfMemoryMetric -Metric $metric -Prefix 'AfterInputGeneration' -Snapshot (Get-ZtPerfMemorySnapshot)

            $script:groupMemberCallCount = 0
            $script:returnedMemberCount = 0
            $script:currentPerfMetric = $metric

            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect()
            Set-ZtPerfMemoryMetric -Metric $metric -Prefix 'BeforeExport' -Snapshot (Get-ZtPerfMemorySnapshot)
            Update-ZtPerfPeakMemory -Metric $metric

            $elapsed = Measure-Command {
                Export-ZtGraphEntityPrivilegedGroup -InputName $InputName -Name $Name -ExportPath $script:exportPath
            }

            $metric.ExportElapsed = $elapsed.ToString()
            $metric.GroupMemberCallCount = $script:groupMemberCallCount
            $metric.ReturnedMemberCount = $script:returnedMemberCount
            Set-ZtPerfMemoryMetric -Metric $metric -Prefix 'AfterExport' -Snapshot (Get-ZtPerfMemorySnapshot)

            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect()
            Set-ZtPerfMemoryMetric -Metric $metric -Prefix 'AfterExportCollect' -Snapshot (Get-ZtPerfMemorySnapshot)

            $outputStats = Get-ZtPerfFolderStats -Path $metric.OutputPath
            $metric.JsonFileCount = $outputStats.FileCount
            $metric.OutputBytes = $outputStats.Bytes

            $totalElapsed.Stop()
            $metric.TotalElapsed = $totalElapsed.Elapsed.ToString()
            Add-ZtPerfDerivedMetrics -Metric $metric
            $script:currentPerfMetric = $null

            $script:privilegedGroupPerf[$Name] = $metric
            [pscustomobject]$metric | Format-List | Out-Host

            $metric.GroupMemberCallCount | Should -Be $ObjectCount
            $metric.ReturnedMemberCount | Should -Be $metric.ExpectedOutputMemberRows
            $metric.InputFileCount | Should -Be $metric.ExpectedPageCount
            $metric.JsonFileCount | Should -Be $metric.ExpectedPageCount
            $metric.OutputBytes | Should -BeGreaterThan 0
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
        Mock -ModuleName ZeroTrustAssessment Get-ZtGroupMember {
            $script:groupMemberCallCount++
            if ($script:currentPerfMetric -and ($script:groupMemberCallCount % $MemorySampleInterval -eq 0)) {
                Update-ZtPerfPeakMemory -Metric $script:currentPerfMetric
            }

            $members = [object[]]::new($MembersPerGroup)
            for ($memberIndex = 0; $memberIndex -lt $MembersPerGroup; $memberIndex++) {
                $members[$memberIndex] = New-ZtPerfGroupMember -GroupId $GroupId -MemberIndex $memberIndex
            }
            $script:returnedMemberCount += $MembersPerGroup
            return @($members)
        }
    }

    It "exports generated Application pages through the real paging and file-writing loop" -Skip {
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

    It "exports generated RoleAssignmentGroup memberships from simulated group role assignments" {
        Invoke-ZtPerfPrivilegedGroupExport `
            -InputName 'RoleAssignment' `
            -Name 'RoleAssignmentGroup' `
            -Template $script:roleAssignmentTemplate
    }

    It "exports generated RoleAssignmentScheduleInstanceGroup memberships from simulated group schedule instances" {
        Invoke-ZtPerfPrivilegedGroupExport `
            -InputName 'RoleAssignmentScheduleInstance' `
            -Name 'RoleAssignmentScheduleInstanceGroup' `
            -Template $script:roleAssignmentScheduleInstanceTemplate
    }
}
