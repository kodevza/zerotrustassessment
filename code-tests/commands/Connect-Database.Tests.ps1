Describe "Connect-Database" {
	BeforeAll {
		$here = $PSScriptRoot
		$script:srcRoot = (Resolve-Path (Join-Path $here "../../src/powershell")).Path

		$moduleName = 'ZeroTrustAssessment'
		if (-not (Get-Module -Name $moduleName -ErrorAction SilentlyContinue)) {
			Import-Module (Join-Path $script:srcRoot "ZeroTrustAssessment.psd1") -Global 3>$null
			Import-Module (Join-Path $script:srcRoot "ZeroTrustAssessment.psm1") -Global -Force 3>$null
		}
	}

	It "Applies configured DuckDB memory settings to in-memory connections" {
		$previousMemoryLimit = Get-PSFConfigValue -FullName 'ZeroTrustAssessment.Database.MemoryLimit' -Fallback '8GB'
		$previousThreads = Get-PSFConfigValue -FullName 'ZeroTrustAssessment.Database.Threads' -Fallback 1

		Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.MemoryLimit' -Value '1GB'
		Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.Threads' -Value 2

		$database = $null
		try {
			$database = Connect-Database -Transient

			$settings = Invoke-DatabaseQuery -Database $database -Sql "select name, value from duckdb_settings() where name in ('memory_limit', 'threads');"
			$settingsByName = @{}
			foreach ($setting in $settings) {
				$settingsByName[$setting.name] = $setting.value
			}

			$settingsByName['memory_limit'] | Should -Be '953.6 MiB'
			$settingsByName['threads'] | Should -Be '2'
		}
		finally {
			if ($database) { $database.Dispose() }
			Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.MemoryLimit' -Value $previousMemoryLimit
			Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.Threads' -Value $previousThreads
		}
	}

	It "Restores the current platform DuckDB native library from restored NuGet packages" {
		$nativeFileName = if ($IsWindows) {
			'duckdb.dll'
		}
		elseif ($IsMacOS) {
			'libduckdb.dylib'
		}
		else {
			'libduckdb.so'
		}

		$nativeLibraryPath = Join-Path (Join-Path $script:srcRoot 'lib') $nativeFileName
		$backupPath = $null

		if (Test-Path -Path $nativeLibraryPath -PathType Leaf) {
			$backupPath = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}.{1}.bak" -f $nativeFileName, [guid]::NewGuid())
			Move-Item -Path $nativeLibraryPath -Destination $backupPath -Force
		}

		$database = $null
		try {
			$database = Connect-Database -Transient

			Test-Path -Path $nativeLibraryPath -PathType Leaf | Should -BeTrue
		}
		finally {
			if ($database) { $database.Dispose() }
			if ($backupPath) {
				Move-Item -Path $backupPath -Destination $nativeLibraryPath -Force
			}
		}
	}
}
