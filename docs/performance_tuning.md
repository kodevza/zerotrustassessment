# Performance Tuning Tips

Large tenants can generate very large Microsoft Graph exports. The assessment uses DuckDB to import those exports into a local database before running checks, so performance depends on both Graph collection time and local database resources.

## Application flow

The assessment has three main phases:

1. ZTA queries Microsoft Graph and writes the exported data as JSON files.
2. ZTA imports those JSON files into a local DuckDB database.
3. ZTA runs assessment tests against the DuckDB database and generates the report.
      - During the assessment tests, ZTA can also query Microsoft Graph and Azure Resource APIs for checks that require live service data.

When `-Resume` is used, previously exported JSON files are reused. Graph export tasks are skipped when their export markers already exist, but the DuckDB database is rebuilt from the existing JSON files before tests run.

## DuckDB impact

The main tradeoff is resource planning. DuckDB needs memory while reading Graph JSON files, building tables, and executing queries. If the configured memory limit is reached, file-backed assessment runs can spill temporary work to disk. That is safer than exhausting process memory, but it is slower and requires enough free disk space.

Current database defaults are:

| Setting | Default | Purpose |
|---------|---------|---------|
| `ZeroTrustAssessment.Database.MemoryLimit` | `8GB` | DuckDB memory limit for imports and queries. |
| `ZeroTrustAssessment.Database.Threads` | `1` | DuckDB worker threads. Kept low by default to reduce peak memory during large JSON imports. |
| `ZeroTrustAssessment.Database.MaxTempDirectorySize` | `64GB` | Maximum size of the DuckDB temporary spill directory for file-backed databases. |
| `ZeroTrustAssessment.Database.MaximumObjectSize` | `268435456` | Maximum JSON object size for DuckDB `read_json` imports, in bytes. The default is 256 MB. |

## Recommended memory setup

Start with the default `8GB` DuckDB memory limit when running on a workstation with at least 16 GB of RAM. This keeps enough memory available for PowerShell, Microsoft Graph modules, report generation, and the operating system.

Example:

```powershell
Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.MemoryLimit' -Value '8GB'
Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.MaxTempDirectorySize' -Value '128GB'
Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.Threads' -Value 1
```

Use a fast local SSD for the assessment path.

## Export and test parallelism

The assessment also has PowerShell-level throttle settings:

```powershell
Set-PSFConfig -FullName 'ZeroTrustAssessment.ThrottleLimit.Export' -Value 5
Set-PSFConfig -FullName 'ZeroTrustAssessment.ThrottleLimit.Tests' -Value 5
```

Increasing these values can reduce runtime on well-provisioned machines, but it also increases memory pressure and Microsoft Graph request concurrency. If the run starts swapping, produces throttling errors, or becomes slower after increasing throttle limits, reduce the values again.
