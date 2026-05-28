Describe "Export-ZtGraphEntity" {
    # Regression tests for the Add-GraphProperty guard:
    #
    #   Fix: Guard in Add-GraphProperty skips the batch call when Graph returns an empty page.
    #     if (-not $Results) { return }
    #
    #   Without this guard, passing @() to Invoke-ZtGraphBatchRequest -ArgumentList caused:
    #     "Cannot bind argument to parameter 'ArgumentList' because it is an empty array."

    BeforeAll {
        $srcRoot = Join-Path $PSScriptRoot "../../src/powershell"
        if (-not (Get-Module ZeroTrustAssessment -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psd1") -Global 3>$null
            Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psm1") -Global -Force 3>$null
        }
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
            function global:Get-MgContext {}
        }
    }

    Context "Add-GraphProperty — guard skips batch when page is empty" {
        BeforeAll {
            $script:exportPath = Join-Path ([System.IO.Path]::GetTempPath()) "zt-test-graphentity-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:exportPath -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:exportPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {
            Mock -ModuleName ZeroTrustAssessment Get-ZtConfig            { return $false }
            Mock -ModuleName ZeroTrustAssessment Set-ZtConfig            {}
            Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState  {}
            Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue      { return 1073741824 }
        }

        It "Does not throw when Graph API returns an empty page" {
            # Invoke-ZtRetry returns { "value": [] } — same as the customer tenant.
            # The guard must return early without calling Invoke-ZtGraphBatchRequest.
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return @{ value = @() } }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {
                throw "Guard missing — called with empty ArgumentList"
            }

            {
                Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                    -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                    -ExportPath $script:exportPath
            } | Should -Not -Throw
        }

        It "Invoke-ZtGraphBatchRequest is not called when the page is empty" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return @{ value = @() } }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {}

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                -ExportPath $script:exportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphBatchRequest -Times 0 -Exactly
        }

        It "Does not throw when Invoke-ZtRetry returns null" {
            # $null is distinct from @() — guard must handle both without calling Invoke-ZtGraphBatchRequest.
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return $null }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {
                throw "Guard missing — called with null Results"
            }

            {
                Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                    -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                    -ExportPath $script:exportPath
            } | Should -Not -Throw
        }

        It "Invoke-ZtGraphBatchRequest is not called when Invoke-ZtRetry returns null" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return $null }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {}

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                -ExportPath $script:exportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphBatchRequest -Times 0 -Exactly
        }

        It "Invoke-ZtGraphBatchRequest is called once when the page has items" {
            # Verifies the guard does not suppress normal (non-empty) pages and correctly
            # skips the batch call on an empty second page.
            # The first page must include '@odata.nextLink' so the do-while loop makes a
            # second call; without it the loop breaks immediately and the second branch
            # of the mock is never reached.
            $script:call = 0
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                $script:call++
                if ($script:call -eq 1) {
                    return @{
                        value             = @(@{ id = 'sp-1'; displayName = 'TestSP' })
                        '@odata.nextLink' = 'https://graph.microsoft.com/beta/servicePrincipals?$skiptoken=abc'
                    }
                }
                return @{ value = @() }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest { return @() }

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                -ExportPath $script:exportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphBatchRequest -Times 1 -Exactly
        }

        It "Releases exported page values after writing the page" {
            $script:page = @{
                value = @(
                    @{ id = 'sp-1'; displayName = 'TestSP1' },
                    @{ id = 'sp-2'; displayName = 'TestSP2' }
                )
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return $script:page }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {}

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' `
                -ExportPath $script:exportPath

            $script:page.ContainsKey('value') | Should -BeFalse
        }

        It "Restarts the entity export when Graph reports an expired directory page token" {
            $script:requestedUris = @()
            $script:call = 0

            Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue {
                if ($FullName -eq 'ZeroTrustAssessment.Export.Graph.DirectoryPageTokenMaxRestarts') {
                    return 1
                }
                return 1073741824
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { & $ScriptBlock }
            Mock -ModuleName ZeroTrustAssessment Invoke-MgGraphRequest {
                $script:call++
                $script:requestedUris += $Uri

                if ($script:call -eq 1) {
                    return @{
                        value             = @(@{ id = 'stale-page-1'; displayName = 'Stale page' })
                        '@odata.nextLink' = 'beta/servicePrincipals?$skiptoken=expired'
                    }
                }

                if ($script:call -eq 2) {
                    return @{
                        error = @{
                            code    = 'DirectoryPageTokenNotFoundException'
                            message = 'The directory page token was not found.'
                        }
                    }
                }

                if ($script:call -eq 3) {
                    return @{
                        value             = @(@{ id = 'fresh-page-1'; displayName = 'Fresh page' })
                        '@odata.nextLink' = 'beta/servicePrincipals?$skiptoken=fresh'
                    }
                }

                return @{
                    value = @(@{ id = 'fresh-page-2'; displayName = 'Fresh second page' })
                }
            }

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' `
                -ExportPath $script:exportPath

            $script:requestedUris | Should -Be @(
                'beta/servicePrincipals?$top=999'
                'beta/servicePrincipals?$skiptoken=expired'
                'beta/servicePrincipals?$top=999'
                'beta/servicePrincipals?$skiptoken=fresh'
            )

            $outputFiles = @(Get-ChildItem -Path (Join-Path $script:exportPath 'ServicePrincipal') -Filter '*.json' -File | Sort-Object Name)
            $outputFiles | Should -HaveCount 2

            $firstPage = Get-Content -Path $outputFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
            $secondPage = Get-Content -Path $outputFiles[1].FullName -Raw | ConvertFrom-Json -AsHashtable
            $firstPage.value[0].id | Should -Be 'fresh-page-1'
            $secondPage.value[0].id | Should -Be 'fresh-page-2'
        }
    }

    Context "Privileged group export — streams member output" {
        BeforeAll {
            $script:privilegedGroupExportPath = Join-Path ([System.IO.Path]::GetTempPath()) "zt-test-privilegedgroup-$(Get-Random)"
            $script:roleAssignmentPath = Join-Path $script:privilegedGroupExportPath 'RoleAssignment'
            New-Item -ItemType Directory -Path $script:roleAssignmentPath -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:privilegedGroupExportPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {
            Mock -ModuleName ZeroTrustAssessment Get-ZtConfig           { return $false }
            Mock -ModuleName ZeroTrustAssessment Set-ZtConfig           {}
            Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState {}
            Mock -ModuleName ZeroTrustAssessment Write-PSFMessage       {}

            $groupId = [Guid]::NewGuid().ToString()
            @{
                value = @(
                    @{
                        id               = 'assignment-1'
                        roleDefinitionId = 'role-1'
                        principal        = @{
                            '@odata.type' = '#microsoft.graph.group'
                            id            = $groupId
                            displayName   = 'Privileged Group'
                        }
                    }
                )
            } | Export-PSFJson -Path (Join-Path $script:roleAssignmentPath 'RoleAssignment-0.json') -Depth 100 -Encoding UTF8NoBom
        }

        It "Exports valid member JSON without materializing the result page" {
            Mock -ModuleName ZeroTrustAssessment Get-ZtGroupMember {
                return @(
                    @{
                        '@odata.type'      = '#microsoft.graph.user'
                        id                 = 'user-1'
                        displayName        = 'Privileged User'
                        userPrincipalName  = 'privileged.user@example.invalid'
                    }
                )
            }

            Export-ZtGraphEntityPrivilegedGroup `
                -InputName 'RoleAssignment' `
                -Name 'RoleAssignmentGroup' `
                -ExportPath $script:privilegedGroupExportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Get-ZtGroupMember -Times 1 -Exactly

            $outputFile = Get-ChildItem -Path (Join-Path $script:privilegedGroupExportPath 'RoleAssignmentGroup') -Filter '*.json' -File | Select-Object -First 1
            $outputFile | Should -Not -BeNullOrEmpty

            $output = Get-Content -Path $outputFile.FullName -Raw | ConvertFrom-Json -AsHashtable
            $output.value | Should -HaveCount 1
            $output.value[0].id | Should -Be 'user-1'
            $output.value[0].privilegedGroupId | Should -Not -BeNullOrEmpty
            $output.value[0].roleDefinitionId | Should -Be 'role-1'

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Write-PSFMessage -Times 3 -Exactly -ParameterFilter {
                $Message -like 'PrivilegedGroupExportMetrics *'
            }
        }
    }

    Context "QueryStringAppend — tag filter is applied to application queries" {
        BeforeAll {
            $script:exportPath = Join-Path ([System.IO.Path]::GetTempPath()) "zt-test-graphentity-tag-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:exportPath -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:exportPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {
            $script:requestedUris = @()

            Mock -ModuleName ZeroTrustAssessment Get-ZtConfig            { return $false }
            Mock -ModuleName ZeroTrustAssessment Set-ZtConfig            {}
            Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState  {}
            Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue      { return 1073741824 }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry          { & $ScriptBlock }
            Mock -ModuleName ZeroTrustAssessment Invoke-MgGraphRequest   {
                $script:requestedUris += $Uri
                return @{ value = @() }
            }
        }

        It "Queries applications with the tag filter appended to the default query string" {
            Export-ZtGraphEntity -Name 'Application' -Uri 'beta/applications' `
                -QueryString '$top=999' `
                -QueryStringAppend '$filter=tags/any(t:startswith(t, ''NetworkAccess''))' `
                -ExportPath $script:exportPath

            $script:requestedUris | Should -HaveCount 1
            $script:requestedUris[0] | Should -Be "beta/applications?`$top=999&`$filter=tags/any(t:startswith(t, 'NetworkAccess'))"
        }
    }
}
