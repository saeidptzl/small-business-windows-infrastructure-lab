# Shared helpers for the lab scripts (Windows PowerShell 5.1 compatible).

function Import-LabConfig {
    Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'config\LabConfig.psd1')
}

$script:LabSecretCache = $null

function Get-LabSecret {
    <#
      Returns a lab secret as a SecureString.
      * Automated runs: the host passes a JSON object on standard input (never on the command line).
      * Manual runs: you are prompted, input is masked.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Prompt = $Name
    )
    if ($null -eq $script:LabSecretCache) {
        $script:LabSecretCache = @{}
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw -and $raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                foreach ($p in $obj.PSObject.Properties) { $script:LabSecretCache[$p.Name] = [string]$p.Value }
            }
        }
    }
    if ($script:LabSecretCache.ContainsKey($Name)) {
        return (ConvertTo-SecureString -String $script:LabSecretCache[$Name] -AsPlainText -Force)
    }
    return (Read-Host -Prompt $Prompt -AsSecureString)
}

function Write-LabStep {
    param([Parameter(Mandatory)][string]$Message)
    Write-Output ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Start-LabTranscript {
    <# Writes a transcript to C:\LabEvidence\logs so every run leaves evidence on the VM. #>
    param([Parameter(Mandatory)][string]$Name)
    $dir = 'C:\LabEvidence\logs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir ('{0}_{1}_{2}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $env:COMPUTERNAME, $Name)
    Start-Transcript -Path $file | Out-Null
    return $file
}

function New-LabResult {
    <# One row of a test table: what we expected, what we saw, PASS/FAIL. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Observed,
        [Parameter(Mandatory)][bool]$Passed
    )
    [pscustomobject]@{
        Id       = $Id
        Check    = $Check
        Expected = $Expected
        Observed = $Observed
        Result   = $(if ($Passed) { 'PASS' } else { 'FAIL' })
    }
}

function Wait-LabADReady {
    <# After a DC (re)starts, Active Directory Web Services needs a few minutes: wait for it. #>
    param([int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        try {
            $d = Get-ADDomain -ErrorAction Stop
            Write-Output "Active Directory is ready: $($d.DNSRoot) (domain mode $($d.DomainMode))"
            return
        }
        catch {
            if ((Get-Date) -gt $deadline) { throw "Active Directory not ready after $TimeoutSec s: $_" }
            Start-Sleep -Seconds 10
        }
    }
}

function Test-LabUncAccess {
    <# Tries to list a UNC path; returns 'OK', 'ACCESS DENIED', or the error text. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        Get-ChildItem -LiteralPath $Path -ErrorAction Stop | Out-Null
        return 'OK'
    }
    catch [System.UnauthorizedAccessException] {
        return 'ACCESS DENIED'
    }
    catch {
        if ($_.Exception.Message -match 'denied') { return 'ACCESS DENIED' }
        return ('ERROR: ' + $_.Exception.Message.Trim())
    }
}

Export-ModuleMember -Function Import-LabConfig, Get-LabSecret, Write-LabStep, Start-LabTranscript, New-LabResult, Wait-LabADReady, Test-LabUncAccess
