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
# 9. Allocate IP range for Private Service Access (PSA)
# ────────────────────────────────────────────────────────────────
echo "Allocating IP range for Private Service Access (PSA)"
gcloud compute addresses create google-psa-range \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=16 \
    --network="$VPC" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 10. Connect VPC to Google services (for private Cloud SQL)
# ────────────────────────────────────────────────────────────────
echo "Connecting VPC to Google services for private Cloud SQL"
gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=google-psa-range \
    --network="$VPC" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 11. Create private Cloud SQL MySQL instance
# ────────────────────────────────────────────────────────────────
echo "Creating private Cloud SQL MySQL instance $DB"
gcloud beta sql instances create "$DB" \
    --database-version=MYSQL_8_0 \
    --tier=db-f1-micro \
    --region="$REGION" \
    --no-assign-ip \
    --allocated-ip-range-name=google-psa-range \
    --network="projects/$PROJECT_ID/global/networks/$VPC" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 12. Create database and set root password
# ────────────────────────────────────────────────────────────────
echo "Creating database 'accounts'"
gcloud sql databases create accounts --instance="$DB" --quiet

echo "Setting root password for Cloud SQL"
gcloud sql users set-password root \
  --host=% \
  --instance="$DB" \
  --password="$DB_PASSWORD" \
  --quiet

# ────────────────────────────────────────────────────────────────
# 13. Create private Memcached instance
# ────────────────────────────────────────────────────────────────
echo "Creating private Memcached instance $MEMCACHE"
gcloud memcache instances create "$MEMCACHE" \
    --region="$REGION" \
    --node-count=1 \
    --node-cpu=2 \
    --node-memory=2GB \
    --authorized-network="projects/$PROJECT_ID/global/networks/$VPC" \
    --quiet

# Extract db01 IP
echo "Extracting Cloud SQL private IP"
db01IP=$(gcloud sql instances describe $DB --project=vprofile-478802 --format="value(ipAddresses.ipAddress)")

echo "Cloud SQL Private IP: $db01IP"

# Intialize database.
echo "Login to bastion host and execute the following command to initialize the database:"
echo "wget https://raw.githubusercontent.com/hkhcoder/vprofile-project/refs/heads/gcp/src/main/resources/db_backup.sql"
echo "apt update && apt install mysql-client -y"
echo "mysql -h $db01IP -u root -p$DB_PASSWORD accounts < db_backup.sql"

# ============================================================