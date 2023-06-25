#Created by Kody Salak
#Certhub Certificate Fetcher/Importer that is somewhat automated
#Grabs certificate and key from CertHub, converts it to a PKCS12, and imports to the Personal Certificate Store in Windows.
#Version 1.0

#This script assumes ZERO liability for services that it may affect.
#Please add more error handling if you're using in production.

#Run this in an admin powershell window. It will not add to the correct store/fail if you don't.

#This script assumes that you are using C:\_Apps\certbot\tempcerts to hold all files
#This script also assumes you unzipped the Windows OpenSSL binary to C:\_Apps\certbot\OpenSSL\

# Set variables according to the environment
$CertificateAPIKey = "<certificate API key>"
$KeyAPIKey = "<key API key>"
$Server = "<certhubserver:port>"
$CertHubCertName = "<display name of certificate in certhub>"
$KeyName = "<display name of key in certhub>"
$CertificateAPIURL = "api/v1/download/certificates/$CertHubCertName"
$KeyAPIURL = "api/v1/download/privatekeys/$KeyName"
$TempCerts = "C:\_Apps\certbot\tempcerts"
$CertPath = "$TempCerts\certchain.crt"
$KeyPath = "$TempCerts\key.key"
$PKCS12Path = "$TempCerts\output.pfx"
$PKCS12Password = "Password"
$EncryptedPassword = ConvertTo-SecureString -String $PKCS12Password -Force -AsPlainText
$CurrentCertExpireTime = (Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object {$_.Subject -Like "*subdomain.domain.com"}).NotAfter
$CurrentTime = Get-Date


If ($CurrentCertExpireTime -lt $CurrentTime) {
    Write-Host "Certificate Expired, re-registering"
    ## Script
    # Make folder if it doesn't exist
    if (!(Test-Path -Path $TempCerts -PathType Container)) {
        New-Item -ItemType Directory -Path $TempCerts | Out-Null
    }

    #Get Certs from CertHub
    Try {
        Invoke-WebRequest -Uri "https://$Server/$CertificateAPIURL" -Method GET -Headers @{"apiKey" = "$CertificateAPIKey"} -OutFile "$TempCerts\certchain.crt"
    } Catch {
        Write-Host "ERROR: FAILED TO GET CERTIFICATE: $($_)"
    }

    Try {
        Invoke-WebRequest -Uri "https://$Server/$KeyAPIURL" -Method GET -Headers @{"apiKey" = "$KeyAPIKey"} -OutFile "$TempCerts\key.key"
    } Catch {
        Write-Host "ERROR: FAILED TO GET CERTIFICATE: $($_)"
    }

    # Convert the certificate and private key into a PKCS12 file
    & "C:\_Apps\certbot\OpenSSL\openssl.exe" PKCS12 -export -out $PKCS12Path -inkey $KeyPath -in $CertPath -passout "pass:$PKCS12Password"
    # Import the PKCS12 file into the Local Machine Personal certificate store
    Import-PfxCertificate -FilePath $PKCS12Path -Password $EncryptedPassword -CertStoreLocation "cert:\LocalMachine\My"
} Else {
    Write-Host "Certificate is still valid."
    Exit
}
