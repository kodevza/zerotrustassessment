Describe "Export large data regressions" {
    BeforeAll {
        $srcRoot = Join-Path $PSScriptRoot "../../src/powershell"
        if (-not (Get-Module ZeroTrustAssessment -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psd1") -Global 3>$null
            Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psm1") -Global -Force 3>$null
        }
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
            function global:Get-MgContext {}
        }

        $script:testTempPath = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    }

    Context "Graph entity export" {
        BeforeEach {
            $script:graphExportPath = Join-Path $script:testTempPath "zt-test-graphentity-large-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:graphExportPath -Force | Out-Null

            Mock -ModuleName ZeroTrustAssessment Get-ZtConfig           { return $false }
            Mock -ModuleName ZeroTrustAssessment Set-ZtConfig           {}
            Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState {}
            Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue     { return 1073741824 }
        }

        AfterEach {
            Remove-Item $script:graphExportPath -Recurse -Force -ErrorAction SilentlyContinue
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
                -ExportPath $script:graphExportPath

            $script:page.ContainsKey('value') | Should -BeFalse
        }

    }

    Context "Privileged group export" {
        BeforeEach {
            $script:privilegedGroupExportPath = Join-Path $script:testTempPath "zt-test-privilegedgroup-$(Get-Random)"
            $script:roleAssignmentPath = Join-Path $script:privilegedGroupExportPath 'RoleAssignment'
            New-Item -ItemType Directory -Path $script:roleAssignmentPath -Force | Out-Null

            Mock -ModuleName ZeroTrustAssessment Get-ZtConfig           { return $false }
            Mock -ModuleName ZeroTrustAssessment Set-ZtConfig           {}
            Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState {}

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

        AfterEach {
            Remove-Item $script:privilegedGroupExportPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Exports valid member JSON without materializing the result page" {
            Mock -ModuleName ZeroTrustAssessment Get-ZtGroupMember {
                return @(
                    @{
                        '@odata.type'     = '#microsoft.graph.user'
                        id                = 'user-1'
                        displayName       = 'Privileged User'
                        userPrincipalName = 'privileged.user@example.invalid'
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
        }
    }

    Context "Database import" {
        It "Should create the target table directly without materializing a duplicate temp table" {
            $script:databaseSql = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue {
                if ($FullName -eq 'ZeroTrustAssessment.Database.MaximumObjectSize') { return 268435456 }
                return $Fallback
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-DatabaseQuery {
                $script:databaseSql.Add($Sql)
            }

            $dbPath = Join-Path $script:testTempPath "zt-large-import-shape-$(Get-Random).db"
            $db = Connect-Database -Path $dbPath -Transient
            try {
                New-EntraTable -Database $db -TableName 'ServicePrincipal' -FilePath '/tmp/ServicePrincipal/ServicePrincipal*.json'

                $importSql = @($script:databaseSql | Where-Object { $_ -match 'CREATE OR REPLACE TABLE ServicePrincipal' })
                $script:databaseSql | Where-Object { $_ -match 'tempServicePrincipal' } | Should -BeNullOrEmpty
                $importSql | Should -HaveCount 1
                $importSql[0] | Should -Match 'CREATE OR REPLACE TABLE ServicePrincipal AS SELECT d\.\* FROM \(SELECT unnest\(value\) as d FROM read_json'
                $importSql[0] | Should -Match 'maximum_object_size=268435456'
            }
            finally {
                if ($db) { Disconnect-Database -Database $db -ErrorAction SilentlyContinue }
                if (Test-Path $dbPath) { Remove-Item $dbPath -Force -ErrorAction SilentlyContinue }
            }
        }

        It "Should configure file-backed DuckDB connections to spill large operations to disk" {
            $dbPath = Join-Path $script:testTempPath "zt-large-import-spill-$(Get-Random).db"
            $db = $null
            try {
                $db = Connect-Database -Path $dbPath -Transient

                $settings = Invoke-DatabaseQuery -Database $db -Sql "select name, value from duckdb_settings() where name in ('memory_limit', 'temp_directory', 'max_temp_directory_size', 'preserve_insertion_order', 'threads');"
                $settingsByName = @{}
                foreach ($setting in $settings) {
                    $settingsByName[$setting.name] = $setting.value
                }

                $settingsByName['memory_limit'] | Should -Be '7.4 GiB'
                $settingsByName['temp_directory'] | Should -Be "$dbPath.tmp"
                $settingsByName['max_temp_directory_size'] | Should -Be '59.6 GiB'
                $settingsByName['preserve_insertion_order'] | Should -Be 'false'
                $settingsByName['threads'] | Should -Be '1'
                Test-Path "$dbPath.tmp" | Should -BeTrue
            }
            finally {
                if ($db) { Disconnect-Database -Database $db -ErrorAction SilentlyContinue }
                if (Test-Path $dbPath) { Remove-Item $dbPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path "$dbPath.tmp") { Remove-Item "$dbPath.tmp" -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
