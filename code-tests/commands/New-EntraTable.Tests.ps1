Describe "New-EntraTable" {
    BeforeAll {
        $here = $PSScriptRoot
        $script:srcRoot = (Resolve-Path (Join-Path $here "../../src/powershell")).Path

        $moduleName = 'ZeroTrustAssessment'
        if (-not (Get-Module -Name $moduleName -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $script:srcRoot "ZeroTrustAssessment.psd1") -Global 3>$null
            Import-Module (Join-Path $script:srcRoot "ZeroTrustAssessment.psm1") -Global -Force 3>$null
        }

        function script:New-TestCollectionFile {
            param (
                [Parameter(Mandatory = $true)]
                [string]
                $Path,

                [Parameter(Mandatory = $true)]
                [hashtable[]]
                $Rows
            )

            @{ value = $Rows } | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
        }
    }

    BeforeEach {
        $script:testRoot = Join-Path $TestDrive "entra-table-import"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null

        New-TestCollectionFile -Path (Join-Path $script:testRoot "ZtCollection-0.json") -Rows @(
            @{ id = '1'; displayName = 'First' }
        )
        New-TestCollectionFile -Path (Join-Path $script:testRoot "ZtCollection-1.json") -Rows @(
            @{ id = '2'; displayName = 'Second' }
        )
        New-TestCollectionFile -Path (Join-Path $script:testRoot "ZtCollection-2.json") -Rows @(
            @{ id = '3'; displayName = 'Third'; department = 'Engineering' }
        )
        New-TestCollectionFile -Path (Join-Path $script:testRoot "ZtCollection-3.json") -Rows @(
            @{ id = '4'; displayName = 'Fourth' }
        )
        New-TestCollectionFile -Path (Join-Path $script:testRoot "ZtCollection-4.json") -Rows @(
            @{ id = '5'; displayName = 'Fiveth';  department= 'Sales' }
        )
        New-TestCollectionFile -Path (Join-Path $script:testRoot "ZtCollection-5.json") -Rows @(
            @{ id = '6'; displayName = 'Sixth'; jobTitle = 'Analyst' }
        )

        $script:database = Connect-Database -Transient
    }

    AfterEach {
        if ($script:database) {
            Disconnect-Database -Database $script:database -ErrorAction SilentlyContinue
            $script:database = $null
        }
    }

    It "creates temporary tables in file batches and tracks only distinct batch schemas" {
        $result = New-TempEntraTables `
            -Database $script:database `
            -TableName 'ZtCollection' `
            -FilePath (Join-Path $script:testRoot "ZtCollection-*.json") `
            -ReadJsonParams 'maximum_object_size=268435456, union_by_name=true' `
            -ImportBatchSize 2

        $result.TempTables | Should -HaveCount 3
        $result.TempTables[0].FileCount | Should -Be 2
        $result.TempTables[1].FileCount | Should -Be 2
        $result.TempTables[2].FileCount | Should -Be 2
        $result.SchemaSourceTableNames | Should -HaveCount 3
        $result.SchemaSourceTableNames[0] | Should -Be '__zt_temp_ZtCollection_000001'
        $result.SchemaSourceTableNames[1] | Should -Be '__zt_temp_ZtCollection_000002'
        $result.SchemaSourceTableNames[2] | Should -Be '__zt_temp_ZtCollection_000003'
        $result.DifferentSchemaTableNames | Should -HaveCount 2
        $result.DifferentSchemaTableNames[0] | Should -Be '__zt_temp_ZtCollection_000002'
        $result.DifferentSchemaTableNames[1] | Should -Be '__zt_temp_ZtCollection_000003'
        $result.DifferentSchemaTableCount | Should -Be 2
    }

    It "logs the schema and data temporary tables used to build the final table" {
        Mock -ModuleName ZeroTrustAssessment Write-PSFMessage {}

        New-EntraTable `
            -Database $script:database `
            -TableName 'ZtCollection' `
            -FilePath (Join-Path $script:testRoot "ZtCollection-*.json")

        Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Write-PSFMessage -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'Building table ZtCollection schema from temporary tables: __zt_temp_ZtCollection_000001' -and
            $Level -eq 'Debug' -and
            $Tag -eq 'DB'
        }

        Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Write-PSFMessage -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'Building table ZtCollection data from temporary tables: __zt_temp_ZtCollection_000001' -and
            $Level -eq 'Debug' -and
            $Tag -eq 'DB'
        }

        $row = Invoke-DatabaseQuery -Database $script:database -Sql 'select count(*) as count from ZtCollection;' -AsCustomObject | Select-Object -First 1
        $row.count | Should -Be 6

        $columns = Invoke-DatabaseQuery -Database $script:database -Sql "PRAGMA table_info('ZtCollection');" -AsCustomObject
        @($columns.name) | Should -Contain 'department'
        @($columns.name) | Should -Contain 'jobTitle'
    }
}
