$ErrorActionPreference = "Stop"

Start-Transcript ("{0}.log" -f $MyInvocation.MyCommand.Name) -Append

Import-Module Posh-ACME
Import-Module Posh-ACME.Deploy
Import-Module RDWebClientManagement
Set-PAServer LE_PROD #LE_STAGE

$MailFrom = "no-reply-systemalerts@yourdomain.com"
$MailTo = "infra-watchdog@yourdomain.com"
$SmtpServer = "relay.yourdomain.com"

$DaysToExpiration = 10

$Domain = "yourdomain.com"
$SANList = @("rds.{0}","rdp.{0}", "rdh.{0}", "irelay.{0}") -f $Domain -split "\s" 
$MachineHostName = "{0}.{1}" -f $env:COMPUTERNAME,$Domain

$FriendlyName = $MachineHostName

$CertNames = @() + $FriendlyName + $Domain + $SANList

$CFEncToken = "01010101010101010101010101010101"
$CFTokenSecString = $CFEncToken | ConvertTo-SecureString

$PfxEncPass = "01010101010101010101010101010101"
$PfxPassSecString = $PfxEncPass | ConvertTo-SecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR( $($PfxEncPass | ConvertTo-SecureString) )
$PfxPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

$DNSPluginArgs = @{ CFToken = $CFTokenSecString }

$InstalledCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$FriendlyName" } | Sort-Object -Descending NotAfter | Select-Object -First 1

if ($InstalledCert -eq $null) {
    
    $NewCert = New-PACertificate -Domain $CertNames -FriendlyName $FriendlyName	 -PfxPassSecure $PfxPassSecString -Contact $MailTo -Plugin Cloudflare -PluginArgs $DNSPluginArgs -DnsSleep 10 -Install -AcceptTOS -Verbose -Force

    if ($NewCert -ne $null ) {
        
        Set-IISCertificate -CertThumbprint $NewCert.Thumbprint -PfxFile $NewCert.PfxFile -PfxPass $PfxPassSecString -SiteName "Default Web Site" -Verbose -RemoveOldCert

        Set-RDSHCertificate -CertThumbprint $NewCert.Thumbprint -PfxFile $NewCert.PfxFile -PfxPass $PfxPassSecString -TerminalName "RDP-Tcp" -Verbose -RemoveOldCert

        Set-RDCertificate -Role RDGateway -ImportPath $NewCert.PfxFile -Password $PfxPassSecString -Force -Verbose

        Set-RDCertificate -Role RDWebAccess -ImportPath $NewCert.PfxFile -Password $PfxPassSecString -Force -Verbose

        Set-RDCertificate -Role RDPublishing -ImportPath $NewCert.PfxFile -Password $PfxPassSecString -Force -Verbose

        Set-RDCertificate -Role RDRedirector -ImportPath $NewCert.PfxFile -Password $PfxPassSecString -Force -Verbose

        Import-RDWebClientBrokerCert $NewCert.CertFile

        Copy-Item C:\Cloudflared\caPool.pem -Destination C:\Cloudflared\caPool.pem.bkup -Force -Verbose

        Copy-Item $NewCert.FullChainFile -Destination C:\Cloudflared\caPool.pem -Force -Verbose

        Get-Service -ComputerName $MachineHostName -Name TSGateway | Restart-Service -Verbose

        Get-Service -ComputerName $MachineHostName -Name Winmgmt | Restart-Service -Force -Verbose

        Get-Service -ComputerName $MachineHostName -Name "Cloudflared" | Restart-Service -Verbose

        Invoke-Command -ComputerName $MachineHostName -ScriptBlock { iisreset /RESTART}

        $Subject = "[{0}] {1} New LetsEncrypt Cert Installed: {2}" -f $env:COMPUTERNAME, $MyInvocation.MyCommand.Name, $FriendlyName
        $Body = "`nNew Cert Details:`n{0}" -f $($NewCert | fl * | Out-String)
        $NewInstalledCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$FriendlyName" } | Sort-Object -Descending NotAfter | Select-Object -First 1
        $Body += "`nNew Cert Install Details:`n{0}" -f $($NewInstalledCert | fl * | Out-String)
        Write-Host "$Subject`n$Body"
        Send-MailMessage -From $MailFrom -To $MailTo -SmtpServer $SmtpServer -Subject $Subject -Body $Body

    } else {
        
        $Subject = "[{0}] {1} WARNING - New LetsEncrypt Cert Install Failed: {2}" -f $env:COMPUTERNAME, $MyInvocation.MyCommand.Name, $FriendlyName
        $Body = "Error Details:`n{0}`nResult:`n{1}" -f $($Error[0] | Out-String), $NewCert
        Write-Host "$Subject`n$Body"
        Send-MailMessage -From $MailFrom -To $MailTo -SmtpServer $SmtpServer -Subject $Subject -Body $Body
    }

} else {
    
    if ( ($InstalledCert.NotAfter - (Get-Date)).Days -le $DaysToExpiration) {
        
        $Msg = "Cert {0} will expire in {1} days. Renewing..." -f $InstalledCert.FriendlyName, $DaysToExpiration
        Write-Host $Msg 

        $RenwedCert = Submit-Renewal -PluginArgs $DNSPluginArgs -Verbose -Force

        if ( $RenwedCert -ne $null ) {
            
            $InstalledCert | Remove-Item -Verbose

            Set-IISCertificate -CertThumbprint $RenwedCert.Thumbprint -PfxFile $RenwedCert.PfxFile -PfxPass $PfxPassSecString -SiteName "Default Web Site" -Verbose -RemoveOldCert

            Set-RDSHCertificate -CertThumbprint $RenwedCert.Thumbprint -PfxFile $RenwedCert.PfxFile -PfxPass $PfxPassSecString -TerminalName "RDP-Tcp" -Verbose -RemoveOldCert

            Set-RDCertificate -Role RDGateway -ImportPath $RenwedCert.PfxFile -Password $PfxPassSecString -Force -Verbose

            Set-RDCertificate -Role RDWebAccess -ImportPath $RenwedCert.PfxFile -Password $PfxPassSecString -Force -Verbose

            Set-RDCertificate -Role RDPublishing -ImportPath $RenwedCert.PfxFile -Password $PfxPassSecString -Force -Verbose

            Set-RDCertificate -Role RDRedirector -ImportPath $RenwedCert.PfxFile -Password $PfxPassSecString -Force -Verbose

            Import-RDWebClientBrokerCert $RenwedCert.CertFile

            Copy-Item C:\Cloudflared\caPool.pem -Destination C:\Cloudflared\caPool.pem.bkup -Force -Verbose

            Copy-Item $RenwedCert.FullChainFile -Destination C:\Cloudflared\caPool.pem -Force -Verbose

            Get-Service -ComputerName $MachineHostName -Name TSGateway | Restart-Service -Verbose

            Get-Service -ComputerName $MachineHostName -Name Winmgmt | Restart-Service -Force -Verbose

            Get-Service -ComputerName $MachineHostName -Name "Cloudflared" | Restart-Service -Verbose

            Invoke-Command -ComputerName $MachineHostName -ScriptBlock { iisreset /RESTART}

            $Subject = "[{0}] {1} Old LetsEncrypt Cert Renewed: {2}" -f $env:COMPUTERNAME, $MyInvocation.MyCommand.Name, ($InstalledCert.Subject -split "CN=")[1] -replace ",",""
            $Body = "`nRenwed Cert Details:`n{0}" -f $($RenwedCert | fl * | Out-String)
            $RenwedInstalledCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$FriendlyName" } | Sort-Object -Descending NotAfter | Select-Object -First 1
            $Body += "`nRenwed Cert Install Details:`n{0}" -f $($RenwedInstalledCert | fl * | Out-String)
            $Body += "Old Cert Install Details:`n{0}" -f $($InstalledCert | fl * | Out-String)
            Write-Host "$Subject`n$Body"
            Send-MailMessage -From $MailFrom -To $MailTo -SmtpServer $SmtpServer -Subject $Subject -Body $Body

        } else {
            
            $Subject = "[{0}] {1} WARNING - Old LetsEncrypt Cert Renew Failed: {2}" -f $env:COMPUTERNAME, $MyInvocation.MyCommand.Name, $FriendlyName
            $Body = "Error Details:`n{0}`nResult:`n{1}" -f $($Error[0] | Out-String), $RenwedCert
            Write-Host "$Subject`n$Body"
            Send-MailMessage -From $MailFrom -To $MailTo -SmtpServer $SmtpServer -Subject $Subject -Body $Body
        }
    }
}

Stop-Transcript

#------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
#error handling
#------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
trap {
		
	$Subject = "[{0}] {1} Error" -f $env:COMPUTERNAME, $MyInvocation.MyCommand.Name
    $Body = "Error Details:`n{0}" -f $($Error[0] | Out-String)
    Write-Host "$Subject`n$Body"
    Send-MailMessage -From $MailFrom -To $MailTo -SmtpServer $SmtpServer -Subject $Subject -Body $Body

    Stop-Transcript
    Exit
}