function Get-ZtiRelatedObject {
	[CmdletBinding()]
	param(
		[Object[]] $InputObject
	)

	$seen = @{}

	foreach ($item in @($InputObject)) {
		if (-not $item) {
			continue
		}

		$id = $null
		$displayName = $null
		$userPrincipalName = $null
		$rawTags = $null

		foreach ($propertyName in 'id', 'displayName', 'userPrincipalName', 'tags') {
			$value = $null

			if ($item -is [System.Collections.IDictionary]) {
				foreach ($key in $item.Keys) {
					if ($key -ieq $propertyName) {
						$value = $item[$key]
						break
					}
				}
			}
			elseif ($item.PSObject.Properties[$propertyName]) {
				$value = $item.$propertyName
			}

			switch ($propertyName) {
				'id' { $id = $value }
				'displayName' { $displayName = $value }
				'userPrincipalName' { $userPrincipalName = $value }
				'tags' { $rawTags = $value }
			}
		}

		if (-not $rawTags) {
			$tags = @()
		}
		else {
			if ($rawTags -is [string] -and $rawTags.TrimStart().StartsWith('[')) {
				try {
					$rawTags = $rawTags | ConvertFrom-Json
				}
				catch {
					# Leave it as the original string when it is not valid JSON.
				}
			}

			$tags = @(
				@($rawTags) |
					Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
					ForEach-Object { [string] $_ } |
					Select-Object -Unique
			)
		}

		if ([string]::IsNullOrWhiteSpace($id) -and [string]::IsNullOrWhiteSpace($displayName) -and [string]::IsNullOrWhiteSpace($userPrincipalName) -and $tags.Count -eq 0) {
			continue
		}

		$dedupeKey = if (-not [string]::IsNullOrWhiteSpace($id)) {
			"id:$id"
		}
		elseif (-not [string]::IsNullOrWhiteSpace($userPrincipalName)) {
			"userPrincipalName:$userPrincipalName"
		}
		else {
			"name:$displayName|tags:$($tags -join ',')"
		}

		if ($seen.ContainsKey($dedupeKey)) {
			continue
		}

		$seen[$dedupeKey] = $true

		[ordered]@{
			id                = [string] $id
			displayName       = [string] $displayName
			userPrincipalName = [string] $userPrincipalName
			tags              = @($tags)
		}
	}
}
