# Ensure we're AAD joined: https://stackoverflow.com/questions/70743129/terraform-azure-vm-extension-does-not-join-vm-to-azure-active-directory-for-azur/70759538.
New-Item -path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent\AADJPrivate' -Force | Out-Null

# Teams media optimisations: https://docs.microsoft.com/en-us/azure/virtual-desktop/teams-on-avd
New-Item -path 'HKLM:\Software\Policies\Microsoft' -Name 'Teams' -Force | Out-Null
New-ItemProperty -path 'HKLM:\SOFTWARE\Microsoft\Teams' -Name 'IsWVDEnvironment' -PropertyType DWord -value '1' -Force | Out-Null

# AVD and Kerberos: https://docs.microsoft.com/en-us/azure/virtual-desktop/create-profile-container-azure-ad#configure-the-session-hosts
New-ItemProperty -path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' -Name 'CloudKerberosTicketRetrievalEnabled' -PropertyType DWord -value '1' -Force | Out-Null
New-Item -path 'HKLM:\Software\Policies\Microsoft' -Name 'AzureADAccount' -Force | Out-Null
New-ItemProperty -path 'HKLM:\Software\Policies\Microsoft\AzureADAccount' -Name 'LoadCredKeyFromProfile' -PropertyType DWord -value '1' -Force | Out-Null

# Shortpath: https://docs.microsoft.com/en-us/azure/virtual-desktop/shortpath-public
New-ItemProperty -path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name 'ICEControl' -PropertyType DWord -value '2' -Force | Out-Null

<#
# If required, certificates to deploy.
$certs = [PSCustomObject]@(
    # Sample root
    [PSCustomObject]@{
        string = '<your-base64-string>'
        store = 'Root'
    }
    # Sample code signing
    [PSCustomObject]@{
        string = '<your-base64-string>'
        store = 'TrustedPublisher'
    }
)
foreach ($cert in $certs) {
    $importCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]([System.Convert]::FromBase64String($cert.string))
    $importStore = New-Object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::($cert.store), [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $importStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);
    $importStore.Add($importCert);
    $importStore.Close();
}
#>

# Force the update of Microsoft Store apps.
Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" | Invoke-CimMethod -MethodName UpdateScanMethod