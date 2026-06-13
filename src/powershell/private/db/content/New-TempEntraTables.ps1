<#
.SYNOPSIS
    Creates temporary Entra import tables, one table per JSON file batch.
#>

function New-TempEntraTables {
    [CmdletBinding()]
    param (
        # The connection to the database.
        [Parameter(Mandatory = $true)]
        [DuckDB.NET.Data.DuckDBConnection]
        $Database,

        # The final table name these temporary tables are created for.
        [Parameter(Mandatory = $true)]
        [string]
        $TableName,

        # The JSON files to import from. Wildcards are supported.
        [Parameter(Mandatory = $true)]
        [string]
        $FilePath,

        # The read_json parameter string.
        [Parameter(Mandatory = $true)]
        [string]
        $ReadJsonParams,

        # Number of JSON files to import into each temporary table. Set to 0 to import all files in one table.
        [int]
        $ImportBatchSize = (Get-PSFConfigValue -FullName 'ZeroTrustAssessment.Database.ImportBatchSize' -Fallback 50)
    )

    function Get-ZtSafeTempTableName {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]
            $Name,

            [Parameter(Mandatory = $true)]
            [int]
            $Index
        )

        $safeName = $Name -replace '[^a-zA-Z0-9_]', '_'
        if ($safeName -notmatch '^[a-zA-Z_]') {
            $safeName = "_$safeName"
        }

        "__zt_temp_{0}_{1:000000}" -f $safeName, $Index
    }

    function Get-ZtTableSchemaSignature {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [DuckDB.NET.Data.DuckDBConnection]
            $Database,

            [Parameter(Mandatory = $true)]
            [string]
            $TempTableName
        )

        $escapedTableName = $TempTableName.Replace("'", "''")
        $schemaRows = @(Invoke-DatabaseQuery -Database $Database -Sql "PRAGMA table_info('$escapedTableName');" -Ordered -AsCustomObject)

        ($schemaRows | Sort-Object -Property cid | ForEach-Object {
            "{0}:{1}:{2}" -f $_.name, $_.type, $_.notnull
        }) -join '|'
    }

    function ConvertTo-ZtDuckDbStringList {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string[]]
            $Value
        )

        $escapedValues = @($Value | ForEach-Object { "'$($_.Replace("'", "''"))'" })
        "[$($escapedValues -join ', ')]"
    }

    $files = @(Get-ChildItem -Path $FilePath -File -ErrorAction Stop | Sort-Object -Property FullName)
    if (-not $files) {
        Stop-PSFFunction -Message "No JSON files found for table $TableName using path $FilePath" -EnableException $true -Category ObjectNotFound -Tag DB
    }

    $tempTables = [System.Collections.Generic.List[object]]::new()
    $referenceSchema = $null
    $schemaSignatures = [System.Collections.Generic.HashSet[string]]::new()
    $schemaSourceTableNames = [System.Collections.Generic.List[string]]::new()
    $differentSchemaTables = [System.Collections.Generic.List[string]]::new()

    $effectiveBatchSize = $ImportBatchSize
    if ($effectiveBatchSize -le 0) { $effectiveBatchSize = $files.Count }

    $batchNumber = 0
    for ($i = 0; $i -lt $files.Count; $i += $effectiveBatchSize) {
        $batchNumber++
        $batchFiles = @($files[$i..([math]::Min($i + $effectiveBatchSize - 1, $files.Count - 1))])
        $tempTableName = Get-ZtSafeTempTableName -Name $TableName -Index $batchNumber
        $duckDbFileList = ConvertTo-ZtDuckDbStringList -Value @($batchFiles.FullName)
        Write-PSFMessage "Preparing temporary table $tempTableName for $($batchFiles.Count) files with read_json parameters: $ReadJsonParams" -Level Debug -Tag DB
        $sqlTable = "CREATE OR REPLACE TEMP TABLE $tempTableName AS SELECT d.* FROM (SELECT unnest(value) as d FROM read_json($duckDbFileList, $ReadJsonParams)) source;"

        try {
            Write-PSFMessage "Creating temporary table $tempTableName from $($batchFiles.Count) files" -Level Debug -Tag DB
            Invoke-DatabaseQuery -Database $Database -Sql $sqlTable -NonQuery

            $schemaSignature = Get-ZtTableSchemaSignature -Database $Database -TempTableName $tempTableName
            if ($schemaSignatures.Add($schemaSignature)) {
                $schemaSourceTableNames.Add($tempTableName)
            }

            if (-not $referenceSchema) {
                $referenceSchema = $schemaSignature
            }
            elseif ($schemaSignature -ne $referenceSchema) {
                $differentSchemaTables.Add($tempTableName)
            }

            $tempTables.Add([PSCustomObject]@{
                TableName       = $tempTableName
                FilePath        = @($batchFiles.FullName)
                FileCount       = $batchFiles.Count
                SchemaSignature = $schemaSignature
            })
        }
        catch {
            Write-PSFMessage "Error creating temporary table $tempTableName for $($batchFiles.Count) files: $($_.Exception.Message)" -Level Error -Tag DB -ErrorRecord $_
            throw
        }
    }

    if ($differentSchemaTables.Count -gt 0) {
        Write-PSFMessage "Temporary tables with schema different from the first file for $TableName`: $($differentSchemaTables -join ', ')" -Level Warning -Tag DB
    }

    [PSCustomObject]@{
        TableName                   = $TableName
        TempTables                  = @($tempTables)
        SchemaSourceTableNames      = @($schemaSourceTableNames)
        DifferentSchemaTableNames   = @($differentSchemaTables)
        DifferentSchemaTableCount   = $differentSchemaTables.Count
    }
}
