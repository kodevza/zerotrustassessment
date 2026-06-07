<#
.SYNOPSIS
    Creates a new table in the database.
#>

function New-EntraTable {
    [CmdletBinding()]
    param (
        # The connection to the database.
        [Parameter(Mandatory = $true)]
        [DuckDB.NET.Data.DuckDBConnection]
        $Database,

        # The name of the table to create.
        [Parameter(Mandatory = $true)]
        [string]
        $TableName,

        # The file path to import from
        [Parameter(Mandatory = $true)]
        [string]
        $FilePath
    )

    # Get schema configuration if available for this table
    $schemaConfig = Get-TableSchemaConfig -TableName $TableName

    # Build read_json parameters
    $maximumObjectSize = Get-PSFConfigValue -FullName 'ZeroTrustAssessment.Database.MaximumObjectSize' -Fallback 268435456
    $importBatchSize = Get-PSFConfigValue -FullName 'ZeroTrustAssessment.Database.ImportBatchSize' -Fallback 50
    $readJsonParams = @("maximum_object_size=$maximumObjectSize")

    if ($schemaConfig) {
        Write-PSFMessage "Using special schema configuration for table $TableName`: $($schemaConfig.reason)" -Level Debug -Tag DB

        if ($schemaConfig.use_union_by_name) {
            $readJsonParams += 'union_by_name=true'
        }

        if ($schemaConfig.sample_size) {
            $readJsonParams += "sample_size=$($schemaConfig.sample_size)"
        }

        if ($null -ne $schemaConfig.import_batch_size) {
            $importBatchSize = $schemaConfig.import_batch_size
        }
    } else {
        Write-PSFMessage "Using automatic schema inference for table $TableName" -Level Debug -Tag DB
        # Add union_by_name=true as default for better schema flexibility
        $readJsonParams += 'union_by_name=true'
    }

    $paramsString = $readJsonParams -join ', '

    try {
        Write-PSFMessage "Creating table $TableName with parameters: $paramsString" -Level Debug -Tag DB

        $tempImport = New-TempEntraTables -Database $Database -TableName $TableName -FilePath $FilePath -ReadJsonParams $paramsString -ImportBatchSize $importBatchSize
        $tempTables = @($tempImport.TempTables)

        if (-not $tempTables) {
            Stop-PSFFunction -Message "No temporary tables were created for $TableName" -EnableException $true -Category ObjectNotFound -Tag DB
        }

        $schemaSourceTableNames = @($tempImport.SchemaSourceTableNames)
        if (-not $schemaSourceTableNames) {
            Stop-PSFFunction -Message "No schema source tables were identified for $TableName" -EnableException $true -Category ObjectNotFound -Tag DB
        }

        Write-PSFMessage "Building table $TableName schema from temporary tables: $($schemaSourceTableNames -join ', ')" -Level Debug -Tag DB

        $emptyTableQueries = @($schemaSourceTableNames | ForEach-Object { "SELECT * FROM $_ WHERE false" })
        $sqlCreateFinalTable = "CREATE OR REPLACE TABLE $TableName AS $($emptyTableQueries -join ' UNION ALL BY NAME ');"
        Invoke-DatabaseQuery -Database $Database -Sql $sqlCreateFinalTable -NonQuery

        Write-PSFMessage "Building table $TableName data from temporary tables: $((@($tempTables).TableName) -join ', ')" -Level Debug -Tag DB

        foreach ($tempTable in $tempTables) {
            Write-PSFMessage "Importing temporary table $($tempTable.TableName) into $TableName" -Level Debug -Tag DB
            Invoke-DatabaseQuery -Database $Database -Sql "INSERT INTO $TableName BY NAME SELECT * FROM $($tempTable.TableName);" -NonQuery
            Invoke-DatabaseQuery -Database $Database -Sql "DROP TABLE $($tempTable.TableName);" -NonQuery
        }
    }
    catch {
        Write-PSFMessage "Error creating table $TableName`: $($_.Exception.Message)" -Level Error -Tag DB -ErrorRecord $_

        # If we get a schema inference error, suggest solutions
        if ($_.Exception.Message -like "*Could not convert*" -or $_.Exception.Message -like "*JSON transform error*") {
            Write-PSFMessage "This appears to be a schema inference issue. Consider adding $TableName to Get-TableSchemaConfig with appropriate settings." -Level Warning -Tag DB
        }

        throw
    }
}
