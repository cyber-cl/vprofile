#!/bin/bash
set -e

# ============================================================
#    VPROFILE BACKEND ON GCP 
# ============================================================

# ────────────────────────────────
# 1. STUDENT CONFIGURATION SECTION (ONLY EDIT HERE)
# ────────────────────────────────
PROJECT_ID="<GCPprojectName>"          # Your GCP project ID
REGION="us-central1"                   # Region for all resources
ZONE="${REGION}-a"                     # Zone (derived from region)

APP_NAME="vprofile"                    # Application name
DOMAIN="<YourDomainName>"              # Your real domain for SSL
SUBDOMAIN="vprogcp"                    # Final public URL: vprogcp.hkhinfotek.xyz

MY_IP="0.0.0.0/0"                      # Auto-detect current public IP for bastion access
SSH_KEY="<EnterYourSSHPublicKey>"      # Your SSH public key for bastion access
DB_PASSWORD="GcpVproSqlAdmin9040"      # Cloud SQL root password
# ────────────────────────────────
# 2. CLEAN & CONSISTENT NAMING (DO NOT CHANGE)
# ────────────────────────────────
VPC="vprofile-vpc"

PUB_SUBNET_01="public-01"
PUB_SUBNET_02="public-02"
PRIV_SUBNET_01="private-01"
PRIV_SUBNET_02="private-02"

ROUTER="vprofile-router"
NAT="vprofile-nat"

BASTION="bastion"
DB="vprofile-db"
MEMCACHE="vprofile-memcache"
GOLDEN="vprofile-golden"
SNAPSHOT="vprofile-snapshot"
IMAGE="vprofile-image"

TEMPLATE="vprofile-template"
MIG="vprofile-mig"
HEALTH_CHECK="vprofile-hc"
BACKEND="vprofile-backend"
URL_MAP="vprofile-urlmap"
HTTP_PROXY="vprofile-http-proxy"
HTTPS_PROXY="vprofile-https-proxy"
LB_IP="vprofile-lb-ip"

HTTP_LB="vprofile-http-lb"
HTTPS_LB="vprofile-https-lb"

PRIVATE_ZONE="vprofile-private"
PRIVATE_DNS="vprofile.local"

TAG_BASTION="bastion"
TAG_APP="app"

# ────────────────────────────────────────────────────────────────
# 32. Create Google-managed wildcard SSL certificate
# ────────────────────────────────────────────────────────────────
gcloud certificate-manager certificates create cert-"$SUBDOMAIN" \
    --domains="*.$DOMAIN" \
    --dns-authorizations=auth-"$SUBDOMAIN" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 33. Create certificate map and entry
# ────────────────────────────────────────────────────────────────
gcloud certificate-manager maps create map-"$SUBDOMAIN" --quiet

gcloud certificate-manager maps entries create entry-"$SUBDOMAIN" \
    --map=map-"$SUBDOMAIN" \
    --hostname="*.$DOMAIN" \
    --certificates=cert-"$SUBDOMAIN" \
    --quiet

sleep 360  # Wait for certificate provisioning (may take several minutes)
# Check the status of the certificate
echo "Checking certificate status (this may take a few minutes)..."
gcloud certificate-manager certificates describe cert-"$SUBDOMAIN" \
    --format="table( \
        name, \
        managed.state:label=CERT_STATE, \
        managed.authorizationAttemptInfo[0].state:label=AUTH_STATE, \
        managed.authorizationAttemptInfo[0].domain:label=AUTHORIZED_DOMAIN \
    )"

read -r "Once the certificate status is ACTIVE, press Enter to continue..."
# ────────────────────────────────────────────────────────────────
# 34. Attach certificate map to HTTPS proxy
# ────────────────────────────────────────────────────────────────
gcloud compute target-https-proxies create "$HTTPS_PROXY" \
    --url-map="$URL_MAP" \
    --certificate-map=map-"$SUBDOMAIN" \
    --quiet
    
# ────────────────────────────────────────────────────────────────
# 35. Create final HTTPS and HTTP forwarding rules
# ────────────────────────────────────────────────────────────────
gcloud compute forwarding-rules create "$HTTPS_LB" \
    --global \
    --target-https-proxy="$HTTPS_PROXY" \
    --ports=443 \
    --address="$LB_IP" \
    --quiet

gcloud compute forwarding-rules create "$HTTP_LB" \
    --global \
    --target-http-proxy="$HTTP_PROXY" \
    --ports=80 \
    --address="$LB_IP" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 36. Get final load balancer IP
# ────────────────────────────────────────────────────────────────
LB_IP_ADDR=$(gcloud compute addresses describe "$LB_IP" --global --format="value(address)")

echo "Load Balancer is set up with the following details:"
echo "---------------------------------------------------"
echo "Domain Name: *.$DOMAIN"
echo "Load Balancer IP Address: $LB_IP_ADDR"
echo "You can create a DNS A record pointing your domain to this IP address."
echo "---------------------------------------------------"
echo "VProfile backend deployment completed successfully!"