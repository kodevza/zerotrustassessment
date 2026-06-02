function Resolve-DuckDBNativeLibrary {
	[CmdletBinding()]
	param ()

	$architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
	if ($IsWindows) {
		$runtimeIdentifier = if ($architecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'win-arm64' } else { 'win-x64' }
		$nativeFileName = 'duckdb.dll'
	}
	elseif ($IsMacOS) {
		$runtimeIdentifier = 'osx'
		$nativeFileName = 'libduckdb.dylib'
	}
	elseif ($IsLinux) {
		$runtimeIdentifier = if ($architecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'linux-arm64' } else { 'linux-x64' }
		$nativeFileName = 'libduckdb.so'
	}
	else {
		throw "Unsupported platform for DuckDB native library resolution: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
	}

	$moduleLibDirectory = Join-Path $script:ModuleRoot 'lib'
	$nativeLibraryPath = Join-Path $moduleLibDirectory $nativeFileName
	if (Test-Path -Path $nativeLibraryPath -PathType Leaf) { return $nativeLibraryPath }

	$moduleRootInfo = [System.IO.DirectoryInfo]::new($script:ModuleRoot)
	$repoRoot = $moduleRootInfo.Parent.Parent.FullName
	$packagesConfigPath = Join-Path $repoRoot 'packages.config'
	if (-not (Test-Path -Path $packagesConfigPath -PathType Leaf)) {
		throw "DuckDB native library is missing from $moduleLibDirectory and packages.config was not found. Build or restore the module dependencies before connecting to DuckDB."
	}

	$packagesConfig = [xml]::new()
	$packagesConfig.Load($packagesConfigPath)
	$bindingsPackage = $packagesConfig.packages.package | Where-Object id -EQ 'DuckDB.NET.Bindings.Full' | Select-Object -First 1
	if (-not $bindingsPackage) {
		throw "DuckDB native library is missing from $moduleLibDirectory and packages.config does not include DuckDB.NET.Bindings.Full."
	}

	$packageDirectory = Join-Path (Join-Path $repoRoot 'build/packages') ("{0}.{1}" -f $bindingsPackage.id, $bindingsPackage.version)
	$restoredNativeLibraryPath = Join-Path (Join-Path (Join-Path $packageDirectory 'runtimes') $runtimeIdentifier) (Join-Path 'native' $nativeFileName)
	if (-not (Test-Path -Path $restoredNativeLibraryPath -PathType Leaf)) {
		throw "DuckDB native library is missing from $moduleLibDirectory and was not found in restored NuGet packages. Run build/powershell/Restore-NugetPackages.ps1 for packages.config, then retry."
	}

	$null = New-Item -ItemType Directory -Path $moduleLibDirectory -Force
	Copy-Item -Path $restoredNativeLibraryPath -Destination $nativeLibraryPath -Force

	return $nativeLibraryPath
}
