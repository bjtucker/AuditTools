#Script to help install/setup AuditTools
$ModulePaths = @($env:PSModulePath -split ';')
$ExpectedUserModulePath = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath WindowsPowerShell\Modules
$Destination = $ModulePaths | Where-Object { $_ -eq $ExpectedUserModulePath }
if (-not $Destination) {
  $Destination = $ModulePaths | Select-Object -Index 0
}
if (-not (Test-Path ($Destination + "\AuditTools\"))) {
  New-Item -Path ($Destination + "\AuditTools\") -ItemType Directory -Force | Out-Null
  $DownloadUrl = "https://raw.githubusercontent.com/ScriptAutomate/AuditTools/master/AuditTools.psm1"
  Write-Host "Downloading AuditTools from $DownloadURL"
  $client = (New-Object Net.WebClient)
  $client.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
  $client.DownloadFile($DownloadUrl, $Destination + "\AuditTools\AuditTools.psm1")
  
  $executionPolicy = (Get-ExecutionPolicy)
  $executionRestricted = ($executionPolicy -eq "Restricted")
  if ($executionRestricted) {
    Write-Warning @"
Your execution policy is $executionPolicy, this means you will not be able import or use any scripts -- including modules.
To fix this, change your execution policy to something like RemoteSigned.

    PS> Set-ExecutionPolicy RemoteSigned

For more information, execute:

    PS> Get-Help about_execution_policies

"@
  }

  if (!$executionRestricted) {
    # Ensure AuditTools is imported from the location it was just installed to
    Import-Module -Name $Destination\AuditTools
    Get-Command -Module AuditTools
  }
}

Write-Host "AuditTools is installed and ready to use" -Foreground Green
Write-Host @"
For more details, visit: 
https://github.com/ScriptAutomate/AuditTools
"@
