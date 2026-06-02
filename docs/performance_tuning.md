# Performance Tuning Tips

Large tenants can generate very large Microsoft Graph exports. The assessment uses DuckDB to import those exports into a local database before running checks, so performance depends on both Graph collection time and local database resources.

## Application flow

The assessment has three main phases:

1. ZTA queries Microsoft Graph and writes the exported data as JSON files.
2. ZTA imports those JSON files into a local DuckDB database.
      - If objects in those files exceed the `Nested Entra ID object limits`, split them.
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

For large tenants, use a machine with at least 32 GB of RAM and set the DuckDB memory limit to `16GB`. For very large tenants, use 64 GB or more RAM and set the DuckDB memory limit to `24GB` or `32GB`. Do not set the DuckDB limit to all available RAM; leave at least 40 percent free for the rest of the process.

Example:

```powershell
Set-PSFConfig -FullName 'ZeroTrustAssessment.Database.MemoryLimit' -Value '16GB'
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

## Nested Entra ID object limits

For assessment and reporting purposes, treat a group with 100,000 users.

## Troubleshooting slow runs

If an assessment run is slow or fails during import:

1. Confirm the machine is not swapping.
2. Increase `ZeroTrustAssessment.Database.MemoryLimit` only if there is enough physical RAM.
3. Increase `ZeroTrustAssessment.Database.MaxTempDirectorySize` and use a fast local SSD when large imports spill to disk.
4. Keep `ZeroTrustAssessment.Database.Threads` at `1` for large JSON imports unless you have tested higher values with enough memory headroom.
5. Reduce export or test throttle limits if Graph throttling or memory pressure appears in the logs.

Useful Microsoft references:

- [Microsoft Entra service limits](https://learn.microsoft.com/entra/identity/users/directory-service-limits-restrictions)
- [Performance recommendations for grouping, targeting, and filtering in large Intune environments](https://learn.microsoft.com/intune/intune-service/fundamentals/filters-performance-recommendations)
