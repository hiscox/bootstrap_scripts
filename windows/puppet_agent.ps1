[CmdletBinding()]
param(
  [string]$proxy,
  [string]$dns_suffix,
  [Parameter(Mandatory = $true)]
  [string]$puppet_master,
  [string]$puppet_environment = "production",
  [string]$puppet_autosign_key,
  [string]$puppet_agent_url = "https://downloads.puppetlabs.com/windows/puppet5/puppet-agent-x64-latest.msi"
)
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

& netsh.exe Advfirewall set allprofiles state off

$client = New-Object System.Net.WebClient
if ($proxy) {
  $client.Proxy = New-Object System.Net.WebProxy($proxy)
}
$client.DownloadFile($puppet_agent_url, "C:\puppet-agent.msi")
$certName = $env:COMPUTERNAME + ".${dns_suffix}"
$certName = $certName.ToLower() #Puppet cert names must be lower case
$installargs = "/i C:\puppet-agent.msi /quiet /norestart PUPPET_MASTER_SERVER=${puppet_master} PUPPET_AGENT_ENVIRONMENT=${puppet_environment} PUPPET_AGENT_CERTNAME=$certName PUPPET_AGENT_STARTUP_MODE=Manual";
Start-Process "msiexec.exe" -ArgumentList $installargs -Wait

$csrFile = 'C:\ProgramData\PuppetLabs\puppet\etc\csr_attributes.yaml'
$content = @"
custom_attributes:
  challengePassword: '${puppet_autosign_key}'
extension_requests:
  pp_role: '${puppet_role}'
"@
Set-Content $csrFile $content -Encoding UTF8

Set-Service puppet -StartupType Automatic

$puppet_path = "C:\Program Files\Puppet Labs\Puppet\bin\puppet.bat"
& $puppet_path agent --test --waitforcert 60
Start-Service puppet