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

	$pageIndex = 0
	foreach ($file in $files) {
		$roleAssignments = $null
		$writerState = $null
		$fileCompleted = $false
		try {
			$roleAssignments = Import-PSFJson -Path $file.FullName -Encoding UTF8NoBom

			foreach ($roleAssignment in $roleAssignments.value) {
				if ($roleAssignment.principal.'@odata.type' -ne '#microsoft.graph.group') {
					continue
				}

				# 5/10/2024 - Entra ID Role Enabled Security Groups do not currently support nesting so we don't need to get transitive members
				$groupId = $roleAssignment.principal.id
				$members = $null
				try {
					Update-ZtProgressState -WorkerId $Name -WorkerName $Name -WorkerStatus 'Running' -WorkerDetail "GET beta/groups/$groupId/members"
					$members = Get-ZtGroupMember -GroupId $groupId -OutputType Hashtable
					foreach ($member in $members) {
						if (-not $writerState) {
							$filePath = Join-Path $folderPath "$Name-$pageIndex.json"
							$writerState = New-PrivilegedGroupJsonWriter -FilePath $filePath
						}

						# Clone the hashtable, so we don't modify the hashed results from the membership resolution
						$cloneMember = $member.Clone()
						$cloneMember['privilegedGroupId'] = $groupId
						$cloneMember['roleDefinitionId'] = $roleAssignment.roleDefinitionId
						Write-PrivilegedGroupJsonItem -WriterState $writerState -InputObject $cloneMember
					}
				}
				finally {
					$members = $null
				}
			}

			if ($writerState -and $writerState.HasItems) {
				Close-PrivilegedGroupJsonWriter -WriterState $writerState
				$fileCompleted = $true
				$pageIndex++
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
		}
	}

	Set-ZtConfig -ExportPath $ExportPath -Property $Name -Value $true
}
