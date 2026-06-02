[CmdletBinding()]
param (
	[string]
	$Repository = 'PSGallery'
)

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
	Install-PSResource -Name $missingModules -Repository $Repository -Scope CurrentUser -TrustRepository -AcceptLicense -Quiet -ErrorAction Stop
	return
}

$installModule = Get-Command -Name Install-Module -ErrorAction SilentlyContinue
if ($installModule) {
	Install-Module -Name $missingModules -Repository $Repository -Scope CurrentUser -Force -SkipPublisherCheck -AcceptLicense -ErrorAction Stop
	return
}

throw "Neither Install-PSResource nor Install-Module is available. Install Microsoft.PowerShell.PSResourceGet or PowerShellGet first."
