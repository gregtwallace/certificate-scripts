# Created by Kody Salak (@KodySalak)
# Certhub Certificate Fetcher/Importer that is somewhat automated
# Grabs certificate and key from CertHub, converts it to a PKCS12, and imports to the System Personal Certificate Store in Windows.
# Version 1.1

# This script assumes ZERO liability for services that it may affect.
# Please add more error handling if you're using in production.

# Run this in an admin powershell window. It will not add to the correct store/fail if you don't.
#Requires -RunAsAdministrator

# Variables for script
$CertificateAPIKey = "<certificate API key>"
$KeyAPIKey = "<key API key>"
$Server = "<certhubserver:port>"
$CertHubCertName = "<display name of certificate in certhub>"
$KeyName = "<display name of key in certhub>"
$CertSubject = "<cert subject, e.g. testing.mytld.com>"

# May need/want to edit
$TempCerts = "C:\Windows\temp\tempcerts"
$OpenSSLLocation = "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
$PKCS12Password = "Password"

# Shouldn't need to edit
$EncryptedPassword = ConvertTo-SecureString -String $PKCS12Password -Force -AsPlainText
$CertificateAPIURL = "legocerthub/api/v1/download/certificates/$CertHubCertName"
$KeyAPIURL = "legocerthub/api/v1/download/privatekeys/$KeyName"
$CurrentCertExpireTime = (Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object {$_.Subject -Like "*$CertSubject"}).NotAfter
$CurrentTime = Get-Date
$CertPath = "$TempCerts\certchain.crt"
$KeyPath = "$TempCerts\key.key"
$PKCS12Path = "$TempCerts\output.pfx"

# Main
If ($CurrentCertExpireTime -gt $CurrentTime) {
    Write-Host "Certificate Expired, re-registering"
    # Make folder if it doesn't exist
    If (!(Get-ChildItem $TempCerts -ErrorAction SilentlyContinue)) {
    Write-Host "Creating Temp Directory"
        Try {
            $OutNull = New-Item $TempCerts -ItemType Directory
        } Catch {
            Write-Host "Failed to make directory!"
            Write-Host "Error: $_"
            Exit
        }
    } Else {
        Write-Host "$($TempCerts) exists."
    }
    # Get certs from CertHub
    Try {
        Invoke-WebRequest -Uri "https://$Server/$CertificateAPIURL" -Method GET -Headers @{"apiKey" = "$CertificateAPIKey"} -OutFile "$TempCerts\certchain.crt"
    } Catch {
        Write-Host "ERROR: FAILED TO GET CERTIFICATE: $($_)"
    }
    # Get key from CertHub
    Try {
        Invoke-WebRequest -Uri "https://$Server/$KeyAPIURL" -Method GET -Headers @{"apiKey" = "$KeyAPIKey"} -OutFile "$TempCerts\key.key"
    } Catch {
        Write-Host "ERROR: FAILED TO GET KEY: $($_)"
    }

    # Convert the certificate and private key into a PKCS12 file
    & $OpenSSLLocation pkcs12 -export -out $PKCS12Path -inkey $KeyPath -in $CertPath -passout "pass:$PKCS12Password"
    
    # Import the PKCS12 file into the Local Machine Personal certificate store
    Import-PfxCertificate -FilePath $PKCS12Path -Password $EncryptedPassword -CertStoreLocation "cert:\LocalMachine\My"
    
    # Remove the temp directory
    Remove-Item -Recurse -Force $TempCerts
} Else {
    Write-Host "Certificate is still valid."
    Exit
}
