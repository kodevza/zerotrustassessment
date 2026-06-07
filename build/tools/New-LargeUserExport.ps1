<#
.SYNOPSIS
    Generates large Entra user export page files from an existing User-0.json sample.

.DESCRIPTION
    Creates Graph-style user export JSON files with the same top-level shape as the
    input file. The script cycles through the users in the input file as templates
    and updates identity fields so each generated user is unique.

.PARAMETER InputJsonPath
    Path to the source User-0.json file.

.PARAMETER OutputDirectory
    Directory where generated User-N.json files will be written.

.PARAMETER FileCount
    Number of output files to generate. Defaults to 1000.

.PARAMETER ElementsPerFile
    Number of users in each output file. Defaults to 999.

.PARAMETER Domain
    Domain used for generated userPrincipalName values.

.PARAMETER Force
    Overwrite existing User-N.json files in the output directory.

.EXAMPLE
    ./build/tools/New-LargeUserExport.ps1

.EXAMPLE
    ./build/tools/New-LargeUserExport.ps1 -OutputDirectory ./ZeroTrustReport99/zt-export/User-large -Force
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $InputJsonPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../ZeroTrustReport99/zt-export/User/User-0.json'),

    [Parameter()]
    [string] $OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath '../../ZeroTrustReport99/zt-export/User-generated'),

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $FileCount = 2000,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ElementsPerFile = 999,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Domain = 'generated.example.com',

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-JsonLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    return $Value | ConvertTo-Json -Compress
}

function Set-JsonStringProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $JsonValue
    )

    $escapedName = [regex]::Escape($Name)
    $pattern = "(?m)(`"$escapedName`"\s*:\s*)(null|`"([^`"\\]|\\.)*`")"
    $evaluator = {
        param($match)
        return "$($match.Groups[1].Value)$JsonValue"
    }

    return [regex]::Replace($Json, $pattern, [System.Text.RegularExpressions.MatchEvaluator] $evaluator)
}

function New-GeneratedUserJsonTemplate {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TemplateJson
    )

    $json = $TemplateJson
    $json = Set-JsonStringProperty -Json $json -Name 'id' -JsonValue (ConvertTo-JsonLiteral '__ZT_USER_ID__')
    $json = Set-JsonStringProperty -Json $json -Name 'displayName' -JsonValue (ConvertTo-JsonLiteral '__ZT_DISPLAY_NAME__')
    $json = Set-JsonStringProperty -Json $json -Name 'mailNickname' -JsonValue (ConvertTo-JsonLiteral '__ZT_MAIL_NICKNAME__')
    $json = Set-JsonStringProperty -Json $json -Name 'userPrincipalName' -JsonValue (ConvertTo-JsonLiteral '__ZT_USER_PRINCIPAL_NAME__')
    $json = Set-JsonStringProperty -Json $json -Name 'mail' -JsonValue (ConvertTo-JsonLiteral '__ZT_USER_PRINCIPAL_NAME__')
    $json = Set-JsonStringProperty -Json $json -Name 'givenName' -JsonValue (ConvertTo-JsonLiteral 'Generated')
    $json = Set-JsonStringProperty -Json $json -Name 'surname' -JsonValue (ConvertTo-JsonLiteral '__ZT_SURNAME__')
    $json = Set-JsonStringProperty -Json $json -Name 'employeeId' -JsonValue (ConvertTo-JsonLiteral '__ZT_EMPLOYEE_ID__')
    $json = Set-JsonStringProperty -Json $json -Name 'securityIdentifier' -JsonValue (ConvertTo-JsonLiteral '__ZT_SECURITY_IDENTIFIER__')
    $json = Set-JsonStringProperty -Json $json -Name 'issuerAssignedId' -JsonValue (ConvertTo-JsonLiteral '__ZT_USER_PRINCIPAL_NAME__')
    $json = Set-JsonStringProperty -Json $json -Name 'issuer' -JsonValue (ConvertTo-JsonLiteral '__ZT_DOMAIN__')

    return $json
}

function New-GeneratedUserJson {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TemplateJson,

        [Parameter(Mandatory = $true)]
        [int] $Index,

        [Parameter(Mandatory = $true)]
        [string] $Domain
    )

    $number = '{0:D6}' -f $Index
    $mailNickname = "generated-user-$number"
    $userPrincipalName = "$mailNickname@$Domain"
    $displayName = "Generated User $number"
    $userId = [guid]::NewGuid().ToString()
    $securityIdentifier = "S-1-12-1-$Index-$($Index + 1000000)-$($Index + 2000000)-$($Index + 3000000)"

    return $TemplateJson.
        Replace('__ZT_USER_ID__', $userId).
        Replace('__ZT_DISPLAY_NAME__', $displayName).
        Replace('__ZT_MAIL_NICKNAME__', $mailNickname).
        Replace('__ZT_USER_PRINCIPAL_NAME__', $userPrincipalName).
        Replace('__ZT_SURNAME__', "User $number").
        Replace('__ZT_EMPLOYEE_ID__', $number).
        Replace('__ZT_SECURITY_IDENTIFIER__', $securityIdentifier).
        Replace('__ZT_DOMAIN__', $Domain)
}

$resolvedInputPath = (Resolve-Path -Path $InputJsonPath).Path
$resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)

$source = Get-Content -Path $resolvedInputPath -Raw | ConvertFrom-Json -Depth 100
if (-not ($source.PSObject.Properties.Name -contains 'value') -or -not $source.value -or $source.value.Count -eq 0) {
    throw "Input JSON must contain a non-empty 'value' array: $resolvedInputPath"
}

if (-not (Test-Path -Path $resolvedOutputDirectory -PathType Container)) {
    New-Item -Path $resolvedOutputDirectory -ItemType Directory -Force | Out-Null
}

$context = $source.'@odata.context'
$templates = @($source.value | ForEach-Object {
        New-GeneratedUserJsonTemplate -TemplateJson ($_ | ConvertTo-Json -Depth 100 -Compress)
    })
$totalUsers = $FileCount * $ElementsPerFile
$writtenUsers = 0

Write-Host "Generating $FileCount files with $ElementsPerFile users each ($totalUsers total users)."
Write-Host "Input:  $resolvedInputPath"
Write-Host "Output: $resolvedOutputDirectory"

for ($fileIndex = 0; $fileIndex -lt $FileCount; $fileIndex++) {
    $outputPath = Join-Path -Path $resolvedOutputDirectory -ChildPath "User-$fileIndex.json"
    if ((Test-Path -Path $outputPath -PathType Leaf) -and -not $Force) {
        throw "Output file already exists: $outputPath. Use -Force to overwrite existing files."
    }

    $writer = [System.IO.StreamWriter]::new($outputPath, $false, [System.Text.Encoding]::UTF8)
    try {
        $writer.Write('{')
        $writer.Write('"@odata.context":')
        $writer.Write(($context | ConvertTo-Json -Compress))
        $writer.Write(',"value":[')

        for ($elementIndex = 0; $elementIndex -lt $ElementsPerFile; $elementIndex++) {
            if ($elementIndex -gt 0) {
                $writer.Write(',')
            }

            $globalIndex = ($fileIndex * $ElementsPerFile) + $elementIndex + 1
            $templateJson = $templates[($globalIndex - 1) % $templates.Count]
            $writer.Write((New-GeneratedUserJson -TemplateJson $templateJson -Index $globalIndex -Domain $Domain))
            $writtenUsers++
        }

        $writer.Write(']}')
    }
    finally {
        $writer.Dispose()
    }

    Write-Progress -Activity 'Generating user export files' -Status "Wrote User-$fileIndex.json" -PercentComplete ((($fileIndex + 1) / $FileCount) * 100)
}

Write-Progress -Activity 'Generating user export files' -Completed
Write-Host "Done. Wrote $FileCount files and $writtenUsers users."
