# Created by Kody Salak (@KodySalak)
# Certhub Certificate Fetcher/Importer that is somewhat automated
# Grabs certificate and key from CertHub, converts it to a PKCS12, and imports to the System Personal Certificate Store in Windows.
# Version 2.0

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
$CurrentCertExpireTime = (Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Subject -Like "*$CertSubject"} | Sort-Object -Property NotAfter -Descending | Select-Object -First 1).NotAfter
$CertPath = "$TempCerts\certchain.crt"
$KeyPath = "$TempCerts\key.key"
$PKCS12Path = "$TempCerts\output.pfx"

###
# Exit Func for errors (also removes temp folder)
function Exit-Failed {
    Remove-Item -Recurse -Force $TempCerts
    Exit 1
}

# Main
# Make temp folder, if it doesn't exist
If (!(Get-ChildItem $TempCerts -ErrorAction SilentlyContinue)) {
    Write-Host "Creating Temp Directory"
    Try {
        $null = New-Item $TempCerts -ItemType Directory
    }
    Catch {
        Write-Host "Failed to make directory!"
        Write-Host "Error: $_"
        Exit 1
    }
}
Else {
    Write-Host "$($TempCerts) exists."
}

# Download current LeGo certificate
Try {
    Invoke-WebRequest -Uri "https://$Server/$CertificateAPIURL" -Method GET -Headers @{"apiKey" = "$CertificateAPIKey" } -OutFile "$TempCerts\certchain.crt"
}
Catch {
    Write-Host "ERROR: FAILED TO GET CERTIFICATE: $($_)"
    Exit-Failed
}

# cert object for LeGo cert
$legoCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 "$TempCerts\certchain.crt"

# If LeGo cert has longer validity (or doesn't exist on host yet), update
If ($CurrentCertExpireTime -lt $legoCert.NotAfter -Or [string]::IsNullOrWhiteSpace($CurrentCertExpireTime)) {
    Write-Host "Newer certificate available, updating"

    # Get key from CertHub
    Try {
        Invoke-WebRequest -Uri "https://$Server/$KeyAPIURL" -Method GET -Headers @{"apiKey" = "$KeyAPIKey" } -OutFile "$TempCerts\key.key"
    }
    Catch {
        Write-Host "ERROR: FAILED TO GET KEY: $($_)"
        Exit-Failed
    }

    # Convert the certificate and private key into a PKCS12 file
    & $OpenSSLLocation pkcs12 -export -out $PKCS12Path -inkey $KeyPath -in $CertPath -passout "pass:$PKCS12Password"
    
    # Import the PKCS12 file into the Local Machine Personal certificate store
    Import-PfxCertificate -FilePath $PKCS12Path -Password $EncryptedPassword -CertStoreLocation "cert:\LocalMachine\My"
    
    # Success
    Write-Host "Certificate updated."
}
Else {
    Write-Host "Certificate is still most recent."
}

# Remove temp folder
Remove-Item -Recurse -Force $TempCerts
