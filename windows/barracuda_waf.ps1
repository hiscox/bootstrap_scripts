[CmdletBinding()]
param(
  [string]$ipaddresses,
  [string]$licenses,
  [String]$sku,
  [String]$password,
  [String]$secret
)
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

function Set-TrustAllCertsPolicy {
  if ([System.Net.ServicePointManager]::CertificatePolicy.ToString() -eq "TrustAllCertsPolicy") {
    Write-Verbose "Current policy is already set to TrustAllCertsPolicy"
  }
  else {
    add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(
    ServicePoint srvPoint, X509Certificate certificate,
    WebRequest request, int certificateProblem) {
    return true;
  }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
  }
}

function Wait-Waf([string]$ip) {
  $tries = 0
  $test = Test-NetConnection -ComputerName $ip -Port 8443
  while ($tries -lt 10 -and $test.TcpTestSucceeded -eq $false) {
    $test = Test-NetConnection -ComputerName $ip -Port 8443
    $tries++
    Start-Sleep -Seconds 30
  }
  if ($test.TcpTestSucceeded -eq $false) {
    throw "Timeout waiting for $ip to be available"
  }
}

function Install-License($ipaddresses, $licenses, $sku) {
  for ($i = 0; $i -lt $ipaddresses.Count; $i++) {
    $ip = $ipaddresses[$i]
    $url = "http://$ip" + ":8000"
    if ($sku -eq "byol") {
      $license = $licenses[$i]
      $postParams = @{
        token                 = $license
        system_default_domain = "azure.hiscox.com"
      }
      Invoke-RestMethod "$url/token" -Method Post -ContentType "application/x-www-form-urlencoded" -Body $postParams
    }
    $waitResult = Invoke-RestMethod $url
    while ($waitResult.Contains("Please wait while the system starts up")) {
      Start-Sleep -Seconds 30
      $waitResult = Invoke-RestMethod $url
    }
    $eulasign = @{
      name_sign     = "user"
      email_sign    = "user@hiscox.com"
      company_sign  = "Hiscox"
      eula_hash_val = "ed4480205f84cde3e6bdce0c987348d1d90de9db"
      action        = "save_signed_eula"
    }
    Invoke-RestMethod $url -Method Post -Body $eulasign
  }
}

function Set-Hostname($ipaddresses, $password) {
  for ($i = 0; $i -lt $ipaddresses.Count; $i++) {
    $ip = $ipaddresses[$i]
    $secureUrl = "https://$ip" + ":8443"
    $apiendpoint = $secureUrl + "/restapi/v3"
    $login = @{ username = "admin"; password = $password } | ConvertTo-Json
    $token = Invoke-RestMethod -Method Post -Uri "$apiendpoint/login" -ContentType "application/json" -Body $login -Verbose
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:" -f $token.token)))
    $headers = @{
      Authorization = "Basic $base64AuthInfo";
      accept        = "application/json"
    }
    $body = @{ "hostname" = "barracuda${i}"; "domain" = "azure.hiscox.com" } | ConvertTo-Json
    Invoke-RestMethod -Method Put -Uri "$apiendpoint/system" -ContentType "application/json" -Headers $headers -Body $body -Verbose -MaximumRedirection 0 -ErrorAction SilentlyContinue
  }
}

function Create-Cluster($ipaddresses, $password, $secret) {
  for ($i = 0; $i -lt $ipaddresses.Count; $i++) {
    $ip = $ipaddresses[$i]
    $secureUrl = "https://$ip" + ":8443"
    $apiendpoint = $secureUrl + "/restapi/v3"
    $login = @{ username = "admin"; password = $password } | ConvertTo-Json
    $token = Invoke-RestMethod -Method Post -Uri "$apiendpoint/login" -ContentType "application/json" -Body $login -Verbose
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:" -f $token.token)))
    $headers = @{
      Authorization = "Basic $base64AuthInfo";
      accept        = "application/json"
    }
    $body = @{ "cluster-name" = "cluster"; "cluster-shared-secret" = $secret } | ConvertTo-Json
    try {
      Invoke-RestMethod -Method Put -Uri "$apiendpoint/cluster" -ContentType "application/json" -Headers $headers -Body $body -Verbose -MaximumRedirection 0 -ErrorAction SilentlyContinue
    }
    catch {
      throw $_.Exception.Response
    }
    if ($i -gt 0) {
      Start-Sleep -Seconds 120
      $join = @{ "ip-address" = $ipaddresses[0] } | ConvertTo-Json
      try {
        Invoke-RestMethod -Method Post -Uri "$apiendpoint/cluster/nodes" -ContentType "application/json" -Headers $headers -Body $join -Verbose
      }
      catch {
        throw $_.Exception.Response
      }
    }
  }
}

$ipaddressesarray = [Text.Encoding]::UTF8.GetString([convert]::FromBase64String($ipaddresses)) | ConvertFrom-Json
$licensesarray = [Text.Encoding]::UTF8.GetString([convert]::FromBase64String($licenses)) | ConvertFrom-Json

Set-TrustAllCertsPolicy
Install-License -ipaddresses $ipaddressesarray -licenses $licensesarray -sku $sku
foreach ($ip in $ipaddressesarray) {
  Wait-Waf -ip $ip
}
Set-Hostname -ipaddresses $ipaddressesarray -password $password
Create-Cluster -ipaddresses $ipaddressesarray -password $password -secret $secret