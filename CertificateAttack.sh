#!/bin/bash

# Check if required tools are installed
if ! command -v ldeep &> /dev/null || ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null || ! command -v kinit &> /dev/null; then
  echo "Required tools (ldeep, jq, openssl, kinit) are not installed. Installing them now"
  echo "Installing Ldeep"
  sudo pip3 install python-dev-tools
  sudo apt-get install -y libkrb5-dev krb5-config gcc
  sudo pip3 install ldeep 
  echo "Installing jq"
  sudo apt install -y jq
  echo "installing openssl" 
  sudo apt install -y openssl
  echo "krb5-pkinit"
  sudo apt install -y krb5-pkinit
  
  exit 1
fi

# Function to print usage
usage() {
  echo "Usage: $0 -u <ldap_user> -p <ldap_password> -d <ldap_domain> -h <ldap_host> -c <client_cert_path> -K <client_key_path> -P <principal>"
  exit 1
}

# Parse command-line arguments
while getopts "u:p:d:h:c:K:P:" opt; do
  case $opt in
    u) LDAP_USER="$OPTARG" ;;
    p) LDAP_PASSWORD="$OPTARG" ;;
    d) LDAP_DOMAIN="$OPTARG" ;;
    h) LDAP_HOST="$OPTARG" ;;
    c) CLIENT_CERT="$OPTARG" ;;
    K) CLIENT_KEY="$OPTARG" ;;
    P) PRINCIPAL="$OPTARG" ;;
    *) usage ;;
  esac
done

# Validate required arguments
if [ -z "$LDAP_USER" ] || [ -z "$LDAP_PASSWORD" ] || [ -z "$LDAP_DOMAIN" ] || [ -z "$LDAP_HOST" ] || [ -z "$CLIENT_CERT" ] || [ -z "$CLIENT_KEY" ] || [ -z "$PRINCIPAL" ]; then
  usage
fi

# Define other variables
BASE_DN="CN=Public Key Services,CN=Services,CN=Configuration,DC=$(echo $LDAP_DOMAIN | sed 's/\./,DC=/g')"
LDAP_QUERY="(objectClass=pKIEnrollmentService)"
CERT_FILE="cert.base64"
DER_FILE="cert.der"
PEM_FILE="cert.pem"
KRB5_CONF="/etc/krb5.conf"
KERBEROS_REALM="$LDAP_DOMAIN"

# Construct the LDAP query command
LDAP_COMMAND="ldeep ldap -s ldaps://$LDAP_HOST -u $LDAP_USER -p $LDAP_PASSWORD -d $LDAP_DOMAIN -b '$BASE_DN' search '$LDAP_QUERY' cACertificate"

# Print the LDAP query command
echo "LDAP command: $LDAP_COMMAND"

# Perform the LDAP query and extract the certificate
echo "Performing LDAP query to retrieve the certificate..."
CERT_DATA=$(eval $LDAP_COMMAND | jq -r '.[0].cACertificate[0]')

if [ -z "$CERT_DATA" ]; then
  echo "Failed to retrieve the certificate or the certificate is empty."
  exit 1
fi

echo "$CERT_DATA" > $CERT_FILE

# Decode the Base64-encoded string to a DER file
echo "Decoding the Base64-encoded certificate to DER format..."
base64 -d $CERT_FILE > $DER_FILE

# Convert the DER file to PEM format
echo "Converting the certificate to PEM format..."
openssl x509 -inform der -in $DER_FILE -out $PEM_FILE

# Verify that the PEM file was created successfully
if [ ! -s $PEM_FILE ]; then
  echo "Failed to convert the certificate to PEM format."
  exit 1
fi

# Extract domain name from LDAP_DOMAIN
DOMAIN_NAME=$(echo $LDAP_DOMAIN | tr '[:upper:]' '[:lower:]')

# Update the krb5.conf file
# Update the krb5.conf file
echo "Updating krb5.conf file..."

cat <<EOL | sudo tee $KRB5_CONF > /dev/null
[libdefaults]
    default_realm = $KERBEROS_REALM
    dns_lookup_kdc = false
    dns_lookup_realm = false

# The following krb5.conf variables are only for MIT Kerberos.
    kdc_timesync = 1
    ccache_type = 4
    forwardable = true
    proxiable = true
    rdns = false

# The following libdefaults parameters are only for Heimdal Kerberos.

[realms]
    $KERBEROS_REALM = {
        kdc = $LDAP_HOST
        admin_server = $LDAP_HOST
        pkinit_anchors = $PWD/$PEM_FILE
        pkinit_eku_checking = kpServerAuth
        pkinit_kdc_hostname = $LDAP_HOST
        pkinit_identities = $PWD/$CLIENT_CERT,$PWD/$CLIENT_KEY
    }

[domain_realm]
    .$DOMAIN_NAME = $KERBEROS_REALM
    $DOMAIN_NAME = $KERBEROS_REALM
EOL

# Print updated krb5.conf for debugging
echo "Updated krb5.conf:"
cat $KRB5_CONF


# Perform kinit with the provided principal
echo "Performing kinit with the provided principal..."
sudo kinit  $PRINCIPAL
sudo klist
echo "Script execution completed."
