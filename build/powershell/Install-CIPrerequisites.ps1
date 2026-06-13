[CmdletBinding()]
param (
	[string]
	$Repository = 'PSGallery'
)

function Invoke-ZtInstallWithRetry {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[scriptblock]
		$ScriptBlock,

		[string]
		$OperationName = 'Install prerequisites',

		[int]
		$MaxAttempts = 5,

		[int[]]
		$DelaySeconds = @(10, 30, 60, 120)
	)

	for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
		try {
			& $ScriptBlock
			return
		}
		catch {
			if ($attempt -ge $MaxAttempts) {
				throw
			}

			$delay = if (($attempt - 1) -lt $DelaySeconds.Count) {
				$DelaySeconds[$attempt - 1]
			}
			else {
				$DelaySeconds[-1]
			}

			Write-Warning ("{0} failed on attempt {1}/{2}: {3}. Retrying in {4} seconds." -f $OperationName, $attempt, $MaxAttempts, $_.Exception.Message, $delay)
			Start-Sleep -Seconds $delay
		}
	}
}

$modules = @(
	"Pester" # Test Framework, runs the tests
	"PSScriptAnalyzer" # PowerShell Best Practices analyzer, will be used in tests
	'Refactor' # Used to update the metadata for individual test commands
	"Metadata" # Used to update psd1 files instead of the broken Update-ModuleManifest command
)

# Automatically add missing dependencies
$data = Import-PowerShellDataFile -Path "$PSScriptRoot\..\..\src\powershell\ZeroTrustAssessment.psd1"
foreach ($dependency in $data.RequiredModules) {
	if ($dependency -is [string]) {
		if ($modules -contains $dependency) {
			continue
		}
		$modules += $dependency
	}
	else {
		if ($modules -contains $dependency.ModuleName) {
			continue
		}
		$modules += $dependency.ModuleName
	}
}

$modules = @($modules | Sort-Object -Unique)
$missingModules = @($modules | Where-Object { -not (Get-Module -Name $_ -ListAvailable) })

if (-not $missingModules) {
	Write-Host "All prerequisite modules are already available."
	return
}

$installPSResource = Get-Command -Name Install-PSResource -ErrorAction SilentlyContinue
if ($installPSResource) {
	Invoke-ZtInstallWithRetry -OperationName 'Install-PSResource prerequisite installation' -ScriptBlock {
		Install-PSResource -Name $missingModules -Repository $Repository -Scope CurrentUser -TrustRepository -AcceptLicense -Quiet -ErrorAction Stop
	}
	return
}

$installModule = Get-Command -Name Install-Module -ErrorAction SilentlyContinue
if ($installModule) {
	Invoke-ZtInstallWithRetry -OperationName 'Install-Module prerequisite installation' -ScriptBlock {
		Install-Module -Name $missingModules -Repository $Repository -Scope CurrentUser -Force -SkipPublisherCheck -AcceptLicense -ErrorAction Stop
	}
	return
}

throw "Neither Install-PSResource nor Install-Module is available. Install Microsoft.PowerShell.PSResourceGet or PowerShellGet first."
