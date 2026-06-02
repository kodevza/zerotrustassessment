Describe "Add-ZtTestResultDetail" {
	BeforeAll {
		$here = $PSScriptRoot
		$srcRoot = Join-Path $here "../../src/powershell"
		$script:ModuleRoot = $srcRoot

		function Get-ZtTest {
			param(
				[string[]] $Tests,
				[switch] $Current
			)

			[PSCustomObject]@{
				TestId             = '90001'
				Title              = 'Object tag export test'
				Category           = 'Unit'
				RiskLevel          = 'Low'
				ImplementationCost = 'Low'
				UserImpact         = 'Low'
				Pillar             = 'Identity'
				SfiPillar          = $null
				MinimumLicense     = $null
				CompatibleLicense  = $null
			}
		}

		function Get-ZtTestMetadata {}
		function Get-ZtSkippedReason {}
		function Get-GraphObjectMarkdown { 'markdown' }
		function Get-ZtTestStatus {
			param(
				[bool] $Status,
				[string] $SkippedBecause,
				[string] $CustomStatus
			)

			if ($Status) { 'Passed' } else { 'Failed' }
		}
		function Write-ZtProgress {}
		function Write-PSFMessage {}

		. (Join-Path $srcRoot "private/core/Get-ZtiRelatedObject.ps1")
		. (Join-Path $srcRoot "private/core/Add-ZtTestResultDetail.ps1")
	}

	BeforeEach {
		$script:__ZtSession = @{
			TestResultDetail = [PSCustomObject]@{
				Value = @{}
			}
		}
	}

	It "stores related Graph objects with tags in the test result" {
		$graphObjects = @(
			[PSCustomObject]@{
				id          = 'app-1'
				displayName = 'Application 1'
				tags        = @('production', 'critical','source:x')
			}
			@{
				id          = 'app-2'
				displayName = 'Application 2'
				tags        = '["critical","external"]'
			}
			[PSCustomObject]@{
				id          = 'app-3'
				displayName = 'Application 3'
			}
		)

		Add-ZtTestResultDetail -TestId '90001' -Status $false -Result '%TestResult%' -GraphObjects $graphObjects -GraphObjectType ConditionalAccess

		$result = $script:__ZtSession.TestResultDetail.Value['90001']
		$result.RelatedObjects.Count | Should -Be 3
		$result.RelatedObjects[0].id | Should -Be 'app-1'
		$result.RelatedObjects[0].displayName | Should -Be 'Application 1'
		$result.RelatedObjects[0].userPrincipalName | Should -Be ''
		$result.RelatedObjects[0].tags | Should -Be @('production', 'critical', 'source:x')
		$result.RelatedObjects[1].id | Should -Be 'app-2'
		$result.RelatedObjects[1].displayName | Should -Be 'Application 2'
		$result.RelatedObjects[1].tags | Should -Be @('critical', 'external')
		$result.RelatedObjects[2].id | Should -Be 'app-3'
		$result.RelatedObjects[2].displayName | Should -Be 'Application 3'
		$result.RelatedObjects[2].tags.Count | Should -Be 0
	}

	It "writes RelatedObjects into the report JSON" {
		$graphObjects = @(
			[PSCustomObject]@{
				id          = 'sp-1'
				displayName = 'Service Principal 1'
				tags        = @('managed')
			}
		)

		Add-ZtTestResultDetail -TestId '90001' -Status $false -Result '%TestResult%' -GraphObjects $graphObjects -GraphObjectType ConditionalAccess

		$json = $script:__ZtSession.TestResultDetail.Value['90001'] | ConvertTo-Json -Depth 10
		$fromJson = $json | ConvertFrom-Json

		$fromJson.RelatedObjects.Count | Should -Be 1
		$fromJson.RelatedObjects[0].id | Should -Be 'sp-1'
		$fromJson.RelatedObjects[0].displayName | Should -Be 'Service Principal 1'
		$fromJson.RelatedObjects[0].tags | Should -Be @('managed')
	}

	It "stores related affected database objects when no GraphObjects are supplied" {
		$affectedObjects = @(
			[PSCustomObject]@{
				id          = 'app-1'
				displayName = 'Application 1'
				tags        = @('webApp', 'notApiConsumer')
			}
		)

		Add-ZtTestResultDetail -TestId '90001' -Status $false -Result 'database generated markdown' -AffectedObjects $affectedObjects

		$result = $script:__ZtSession.TestResultDetail.Value['90001']
		$result.RelatedObjects.Count | Should -Be 1
		$result.RelatedObjects[0].id | Should -Be 'app-1'
		$result.RelatedObjects[0].displayName | Should -Be 'Application 1'
		$result.RelatedObjects[0].tags | Should -Be @('webApp', 'notApiConsumer')
	}

	It "stores user principal names for related user objects" {
		$affectedObjects = @(
			[PSCustomObject]@{
				id                = 'user-1'
				displayName       = 'User 1'
				userPrincipalName = 'user1@contoso.com'
			}
			[PSCustomObject]@{
				userPrincipalName = 'user2@contoso.com'
			}
		)

		Add-ZtTestResultDetail -TestId '90001' -Status $false -Result 'database generated markdown' -AffectedObjects $affectedObjects

		$result = $script:__ZtSession.TestResultDetail.Value['90001']
		$result.RelatedObjects.Count | Should -Be 2
		$result.RelatedObjects[0].id | Should -Be 'user-1'
		$result.RelatedObjects[0].displayName | Should -Be 'User 1'
		$result.RelatedObjects[0].userPrincipalName | Should -Be 'user1@contoso.com'
		$result.RelatedObjects[1].id | Should -Be ''
		$result.RelatedObjects[1].displayName | Should -Be ''
		$result.RelatedObjects[1].userPrincipalName | Should -Be 'user2@contoso.com'
	}
}
