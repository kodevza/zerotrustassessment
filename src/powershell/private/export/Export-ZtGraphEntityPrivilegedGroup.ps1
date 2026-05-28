function Export-ZtGraphEntityPrivilegedGroup {
	<#
	.SYNOPSIS
		Exports Privileged Group Memberships for the export cache.

	.DESCRIPTION
		Exports Privileged Group Memberships for the export cache.

	.PARAMETER ExportPath
		The path where exported data (and the database) are stored.

	.PARAMETER InputName
		The name of the export to use as data input.

	.PARAMETER Name
		The name of the new export.

	.EXAMPLE
		PS C:\> Export-ZtGraphEntityPrivilegedGroup -Name RoleEligibilityScheduleRequestGroup -INputName RoleEligibilityScheduleRequest -ExportPath $path

		Exports Privileged Group Memberships for the export cache.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$ExportPath,

		[Parameter(Mandatory = $true)]
		[string]
		$InputName,

		[Parameter(Mandatory = $true)]
		[string]
		$Name
	)

	if (Get-ZtConfig -ExportPath $ExportPath -Property $Name) {
		Write-PSFMessage "Skipping {0} since it was downloaded previously" -StringValues $Name -Target $Name -Tag Export, redundant, skip
		Update-ZtProgressState -WorkerId $Name -WorkerName $Name -WorkerStatus 'Running' -WorkerDetail 'Skipped (cached)'
		return
	}

	$folderPath = Join-Path -Path $ExportPath -ChildPath $Name
	Clear-ZtFolder -Path $folderPath

	$readFolderPath = Join-Path -Path $ExportPath -ChildPath $InputName
	$files = Get-ChildItem -Path $readFolderPath -File

	function Clear-PrivilegedGroupInputPayload {
		[CmdletBinding()]
		param (
			$Results
		)

		if (-not $Results) {
			return
		}

		if ($Results -is [System.Collections.IDictionary]) {
			if ($Results.Contains('value')) {
				$Results.Remove('value')
			}
			return
		}

		$valueProperty = $Results.PSObject.Properties['value']
		if (-not $valueProperty) {
			return
		}

		try {
			$Results.PSObject.Properties.Remove('value')
		}
		catch {
			$valueProperty.Value = $null
		}
	}

	function New-PrivilegedGroupJsonWriter {
		[CmdletBinding()]
		param (
			[string]
			$FilePath
		)

		$encoding = [System.Text.UTF8Encoding]::new($false)
		$writer = [System.IO.StreamWriter]::new($FilePath, $false, $encoding)
		$writer.Write('{"value":[')
		return @{
			Writer   = $writer
			HasItems = $false
			FilePath  = $FilePath
			Closed    = $false
		}
	}

	function Write-PrivilegedGroupJsonItem {
		[CmdletBinding()]
		param (
			[hashtable]
			$WriterState,

			$InputObject
		)

		if ($WriterState.HasItems) {
			$WriterState.Writer.Write(',')
		}

		$WriterState.Writer.Write(($InputObject | ConvertTo-Json -Depth 100 -Compress))
		$WriterState.HasItems = $true
	}

	function Close-PrivilegedGroupJsonWriter {
		[CmdletBinding()]
		param (
			[hashtable]
			$WriterState
		)

		if (-not $WriterState -or $WriterState.Closed) {
			return
		}

		$WriterState.Writer.Write(']}')
		$WriterState.Writer.Dispose()
		$WriterState.Closed = $true
	}

	function Get-PrivilegedGroupMemorySnapshot {
		[CmdletBinding()]
		param()

		$process = [System.Diagnostics.Process]::GetCurrentProcess()
		return [ordered]@{
			workingSetBytes    = $process.WorkingSet64
			privateMemoryBytes = $process.PrivateMemorySize64
			gcMemoryBytes      = [GC]::GetTotalMemory($false)
		}
	}

	function Add-PrivilegedGroupMemorySnapshot {
		[CmdletBinding()]
		param (
			[hashtable]
			$Metric,

			[string]
			$Prefix
		)

		$snapshot = Get-PrivilegedGroupMemorySnapshot
		$Metric["${Prefix}WorkingSetBytes"] = $snapshot.workingSetBytes
		$Metric["${Prefix}PrivateMemoryBytes"] = $snapshot.privateMemoryBytes
		$Metric["${Prefix}GcMemoryBytes"] = $snapshot.gcMemoryBytes
	}

	function Update-PrivilegedGroupPeakMemory {
		[CmdletBinding()]
		param (
			[hashtable]
			$Metric
		)

		$snapshot = Get-PrivilegedGroupMemorySnapshot
		$Metric.peakWorkingSetBytes = [Math]::Max($Metric.peakWorkingSetBytes, $snapshot.workingSetBytes)
		$Metric.peakPrivateMemoryBytes = [Math]::Max($Metric.peakPrivateMemoryBytes, $snapshot.privateMemoryBytes)
		$Metric.peakGcMemoryBytes = [Math]::Max($Metric.peakGcMemoryBytes, $snapshot.gcMemoryBytes)
	}

	function Write-PrivilegedGroupMetric {
		[CmdletBinding()]
		param (
			[string]
			$Event,

			[hashtable]
			$Metric
		)

		$payload = [ordered]@{
			event                  = $Event
			name                   = $Metric.name
			inputName              = $Metric.inputName
			elapsed                = $Metric.stopwatch.Elapsed.ToString()
			inputFileCount         = $Metric.inputFileCount
			inputBytes             = $Metric.inputBytes
			outputFileCount        = $Metric.outputFileCount
			outputBytes            = $Metric.outputBytes
			roleAssignmentRows     = $Metric.roleAssignmentRows
			groupAssignmentRows    = $Metric.groupAssignmentRows
			groupMemberCalls       = $Metric.groupMemberCalls
			memberRows             = $Metric.memberRows
			emptyGroupPages        = $Metric.emptyGroupPages
			peakWorkingSetBytes    = $Metric.peakWorkingSetBytes
			peakPrivateMemoryBytes = $Metric.peakPrivateMemoryBytes
			peakGcMemoryBytes      = $Metric.peakGcMemoryBytes
		}

		foreach ($key in $Metric.Keys) {
			if ($key -like 'last*' -or $key -like 'start*' -or $key -like 'final*') {
				$payload[$key] = $Metric[$key]
			}
		}

		Write-PSFMessage -Level Verbose -Message ('PrivilegedGroupExportMetrics ' + ($payload | ConvertTo-Json -Depth 5 -Compress)) -Tag Export, Metrics, PrivilegedGroup
	}

	$exportMetric = @{
		name                   = $Name
		inputName              = $InputName
		stopwatch              = [System.Diagnostics.Stopwatch]::StartNew()
		inputFileCount         = 0
		inputBytes             = 0L
		outputFileCount        = 0
		outputBytes            = 0L
		roleAssignmentRows     = 0
		groupAssignmentRows    = 0
		groupMemberCalls       = 0
		memberRows             = 0
		emptyGroupPages        = 0
		peakWorkingSetBytes    = 0L
		peakPrivateMemoryBytes = 0L
		peakGcMemoryBytes      = 0L
	}
	Add-PrivilegedGroupMemorySnapshot -Metric $exportMetric -Prefix 'start'
	Update-PrivilegedGroupPeakMemory -Metric $exportMetric
	Write-PrivilegedGroupMetric -Event 'start' -Metric $exportMetric

	$pageIndex = 0
	foreach ($file in $files) {
		$roleAssignments = $null
		$writerState = $null
		$fileCompleted = $false
		$fileStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
		$fileMetric = @{
			lastInputFile             = $file.Name
			lastInputBytes            = $file.Length
			lastRoleAssignmentRows    = 0
			lastGroupAssignmentRows   = 0
			lastGroupMemberCalls      = 0
			lastMemberRows            = 0
			lastOutputFile            = $null
			lastOutputBytes           = 0L
			lastElapsed               = $null
		}
		try {
			$exportMetric.inputFileCount++
			$exportMetric.inputBytes += $file.Length
			$roleAssignments = Import-PSFJson -Path $file.FullName -Encoding UTF8NoBom

			foreach ($roleAssignment in $roleAssignments.value) {
				$exportMetric.roleAssignmentRows++
				$fileMetric.lastRoleAssignmentRows++
				if ($roleAssignment.principal.'@odata.type' -ne '#microsoft.graph.group') {
					continue
				}

				$exportMetric.groupAssignmentRows++
				$fileMetric.lastGroupAssignmentRows++

				# 5/10/2024 - Entra ID Role Enabled Security Groups do not currently support nesting so we don't need to get transitive members
				$groupId = $roleAssignment.principal.id
				$members = $null
				try {
					Update-ZtProgressState -WorkerId $Name -WorkerName $Name -WorkerStatus 'Running' -WorkerDetail "GET beta/groups/$groupId/members"
					$exportMetric.groupMemberCalls++
					$fileMetric.lastGroupMemberCalls++
					$members = Get-ZtGroupMember -GroupId $groupId -OutputType Hashtable
					foreach ($member in $members) {
						if (-not $writerState) {
							$filePath = Join-Path $folderPath "$Name-$pageIndex.json"
							$writerState = New-PrivilegedGroupJsonWriter -FilePath $filePath
							$fileMetric.lastOutputFile = [System.IO.Path]::GetFileName($filePath)
						}

						# Clone the hashtable, so we don't modify the hashed results from the membership resolution
						$cloneMember = $member.Clone()
						$cloneMember['privilegedGroupId'] = $groupId
						$cloneMember['roleDefinitionId'] = $roleAssignment.roleDefinitionId
						Write-PrivilegedGroupJsonItem -WriterState $writerState -InputObject $cloneMember
						$exportMetric.memberRows++
						$fileMetric.lastMemberRows++
					}
				}
				finally {
					$members = $null
				}
			}

			if ($writerState -and $writerState.HasItems) {
				Close-PrivilegedGroupJsonWriter -WriterState $writerState
				$fileCompleted = $true
				$exportMetric.outputFileCount++
				$fileInfo = Get-Item -Path $writerState.FilePath -ErrorAction SilentlyContinue
				if ($fileInfo) {
					$exportMetric.outputBytes += $fileInfo.Length
					$fileMetric.lastOutputBytes = $fileInfo.Length
				}
				$pageIndex++
			}
			else {
				$exportMetric.emptyGroupPages++
			}
		}
		finally {
			if ($writerState -and -not $writerState.Closed) {
				$writerState.Writer.Dispose()
			}
			if ($writerState -and -not $fileCompleted) {
				Remove-Item -Path $writerState.FilePath -Force -ErrorAction SilentlyContinue
			}
			Clear-PrivilegedGroupInputPayload -Results $roleAssignments
			$writerState = $null
			$roleAssignments = $null
			$fileStopwatch.Stop()
			$fileMetric.lastElapsed = $fileStopwatch.Elapsed.ToString()
			Add-PrivilegedGroupMemorySnapshot -Metric $fileMetric -Prefix 'last'
			foreach ($key in $fileMetric.Keys) {
				$exportMetric[$key] = $fileMetric[$key]
			}
			Update-PrivilegedGroupPeakMemory -Metric $exportMetric
			Write-PrivilegedGroupMetric -Event 'page' -Metric $exportMetric
		}
	}

	$exportMetric.stopwatch.Stop()
	Add-PrivilegedGroupMemorySnapshot -Metric $exportMetric -Prefix 'final'
	Update-PrivilegedGroupPeakMemory -Metric $exportMetric
	Write-PrivilegedGroupMetric -Event 'summary' -Metric $exportMetric

	Set-ZtConfig -ExportPath $ExportPath -Property $Name -Value $true
}
