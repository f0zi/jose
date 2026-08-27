[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
	[string]$VendorBranch = 'vendor',
	[string[]]$TargetBranch,
	[string]$VendorRemote = 'vendor',
	[string]$VendorRemoteBranch = 'main',

	[switch]$VendorPull,
	[switch]$Merge,

	[switch]$Stash,
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$Arguments,

		[switch]$MutatesRepository,

		[switch]$AllowFailure
	)

	$commandText = $Arguments -join ' '

	if ($MutatesRepository -and $WhatIfPreference) {
		Write-Host ("What if: git {0}" -f $commandText)
		return 0
	}

	Write-Host ("> git {0}" -f $commandText)
	& git @Arguments
	$exitCode = $LASTEXITCODE

	if (-not $AllowFailure -and $exitCode -ne 0) {
		throw ("git {0} failed with exit code {1}." -f $commandText, $exitCode)
	}

	return $exitCode
}

function Get-GitOutput {
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$Arguments,

		[switch]$AllowFailure
	)

	$output = & git @Arguments 2>&1
	$exitCode = $LASTEXITCODE

	if (-not $AllowFailure -and $exitCode -ne 0) {
		throw ("git {0} failed with exit code {1}: {2}" -f ($Arguments -join ' '), $exitCode, (($output | Out-String).Trim()))
	}

	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = @($output)
	}
}

function Test-BranchExists {
	param(
		[Parameter(Mandatory = $true)]
		[string]$BranchName
	)

	$result = Invoke-Git -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$BranchName") -AllowFailure

	return $result -eq 0
}

function Ensure-BranchExists {
	param(
		[Parameter(Mandatory = $true)]
		[string]$BranchName
	)

	if (-not (Test-BranchExists -BranchName $BranchName)) {
		throw ("Local branch '{0}' does not exist." -f $BranchName)
	}
}

function Ensure-RemoteExists {
	param(
		[Parameter(Mandatory = $true)]
		[string]$RemoteName
	)

	$result = Get-GitOutput -Arguments @('remote')
	if ($result.Output -notcontains $RemoteName) {
		throw ("Git remote '{0}' does not exist." -f $RemoteName)
	}
}

function Test-WorktreeClean {
	$result = Get-GitOutput -Arguments @('status', '--porcelain=v1')
	return $result.Output.Count -eq 0
}

function Get-CurrentBranch {
	$result = Get-GitOutput -Arguments @('branch', '--show-current')
	return (($result.Output | Select-Object -First 1) | Out-String).Trim()
}

function Checkout-Branch {
	param(
		[Parameter(Mandatory = $true)]
		[string]$BranchName
	)

	[void](Invoke-Git -Arguments @('checkout', $BranchName) -MutatesRepository)
}

function Update-BranchFromOrigin {
	param(
		[Parameter(Mandatory = $true)]
		[string]$BranchName
	)

	Checkout-Branch -BranchName $BranchName
	[void](Invoke-Git -Arguments @('pull', '--ff-only', 'origin', $BranchName) -MutatesRepository)
}

function Merge-Branch {
	param(
		[Parameter(Mandatory = $true)]
		[string]$TargetBranch,

		[Parameter(Mandatory = $true)]
		[string]$SourceBranch
	)

	Update-BranchFromOrigin -BranchName $TargetBranch

	if (Test-IsAncestor -PotentialAncestor $TargetBranch -BranchName $SourceBranch) {
		[void](Invoke-Git -Arguments @('merge', '--ff-only', $SourceBranch) -MutatesRepository)
		return
	}

	Write-Warning ("Fast-forward merge is not possible for '{0}' <- '{1}'. Falling back to a regular merge that may require conflict resolution." -f $TargetBranch, $SourceBranch)
	[void](Invoke-Git -Arguments @('merge', '--no-edit', $SourceBranch) -MutatesRepository)
}

function Test-IsAncestor {
	param(
		[Parameter(Mandatory = $true)]
		[string]$PotentialAncestor,

		[Parameter(Mandatory = $true)]
		[string]$BranchName
	)

	$result = Invoke-Git -Arguments @('merge-base', '--is-ancestor', $PotentialAncestor, $BranchName) -AllowFailure

	if ($result -eq 0) {
		return $true
	}

	if ($result -eq 1) {
		return $false
	}

	throw ("Failed to compare branch ancestry for '{0}' and '{1}'." -f $PotentialAncestor, $BranchName)
}

$runVendorPull = $VendorPull.IsPresent
$runMerge = $Merge.IsPresent

if (-not $runVendorPull -and -not $runMerge) {
	$runVendorPull = $true
	$runMerge = $true
}

$originalBranch = Get-CurrentBranch
$resolvedTargetBranches = if ($TargetBranch -and $TargetBranch.Count -gt 0) {
	$TargetBranch
}
else {
	@($originalBranch)
}

Ensure-BranchExists -BranchName $VendorBranch
foreach ($branchName in $resolvedTargetBranches) {
	Ensure-BranchExists -BranchName $branchName
}

$stashCreated = $false
$completedSuccessfully = $false

try {
	if (-not $Force) {
		if (-not (Test-WorktreeClean)) {
			if ($Stash) {
				[void](Invoke-Git -Arguments @('stash', 'push', '--include-untracked', '--message', 'vendor-pull.ps1 auto-stash') -MutatesRepository)
				if (-not $WhatIfPreference) {
					$stashCreated = $true
				}
			}
			elseif ($WhatIfPreference) {
				Write-Warning 'Working tree is not clean. A real run would stop here unless you also pass -Stash or -Force.'
			}
			else {
				throw 'Working tree is not clean. Commit, stash, or rerun with -Stash or -Force.'
			}
		}
	}

	if ($runVendorPull) {
		Ensure-RemoteExists -RemoteName $VendorRemote
		Checkout-Branch -BranchName $VendorBranch
		[void](Invoke-Git -Arguments @('pull', '--ff-only', $VendorRemote, $VendorRemoteBranch) -MutatesRepository)
		[void](Invoke-Git -Arguments @('push', 'origin', $VendorBranch) -MutatesRepository)
	}

	if ($runMerge) {
		$sourceBranch = $VendorBranch

		foreach ($targetBranchName in $resolvedTargetBranches) {
			if ($sourceBranch -ne $VendorBranch -and -not (Test-IsAncestor -PotentialAncestor $sourceBranch -BranchName $targetBranchName)) {
				$sourceBranch = $VendorBranch
			}

			Merge-Branch -TargetBranch $targetBranchName -SourceBranch $sourceBranch
			$sourceBranch = $targetBranchName
		}
	}

	$completedSuccessfully = $true
}
finally {
	$currentBranch = Get-CurrentBranch

	if ($completedSuccessfully) {
		if (-not $WhatIfPreference -and $originalBranch -and $currentBranch -ne $originalBranch) {
			Checkout-Branch -BranchName $originalBranch
		}

		if ($stashCreated -and -not $WhatIfPreference) {
			[void](Invoke-Git -Arguments @('stash', 'pop') -MutatesRepository)
		}
	}
	else {
		if ($currentBranch -and $currentBranch -ne $originalBranch) {
			Write-Warning ("Workflow stopped on branch '{0}'. Resolve the repository state there before switching away." -f $currentBranch)
		}

		if ($stashCreated) {
			Write-Warning 'Auto-stash was kept in the stash stack because the workflow did not complete.'
		}
	}
}
