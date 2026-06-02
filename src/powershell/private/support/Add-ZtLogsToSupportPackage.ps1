function Add-ZtLogsToSupportPackage {
	<#
	.SYNOPSIS
		Adds the current assessment run logs to a PSFramework support package zip.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$SupportPackagePath,

		[Parameter(Mandatory = $true)]
		[string]
		$LogsPath
	)

	if (-not (Test-Path -LiteralPath $SupportPackagePath -PathType Leaf)) { return }
	if (-not (Test-Path -LiteralPath $LogsPath -PathType Container)) { return }

	$logFiles = @(Get-ChildItem -LiteralPath $LogsPath -File -Recurse -ErrorAction SilentlyContinue)
	if ($logFiles.Count -eq 0) { return }

	Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

	$logsRoot = [System.IO.Path]::GetFullPath($LogsPath).TrimEnd(
		[System.IO.Path]::DirectorySeparatorChar,
		[System.IO.Path]::AltDirectorySeparatorChar
	)
	$logsRootWithSeparator = $logsRoot + [System.IO.Path]::DirectorySeparatorChar
	$zip = [System.IO.Compression.ZipFile]::Open($SupportPackagePath, [System.IO.Compression.ZipArchiveMode]::Update)
	try {
		foreach ($file in $logFiles) {
			$fullFilePath = [System.IO.Path]::GetFullPath($file.FullName)
			if (-not $fullFilePath.StartsWith($logsRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
				continue
			}

			$relativePath = $fullFilePath.Substring($logsRootWithSeparator.Length).Replace('\', '/')
			$entryName = "zt-export-logs/$relativePath"

			$existingEntry = $zip.GetEntry($entryName)
			if ($existingEntry) {
				$existingEntry.Delete()
			}

			[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
				$zip,
				$file.FullName,
				$entryName,
				[System.IO.Compression.CompressionLevel]::Optimal
			) | Out-Null
		}
	}
	finally {
		$zip.Dispose()
	}
}
