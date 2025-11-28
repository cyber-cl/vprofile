#!/bin/bash
set -e

# ============================================================
#    VPC ON GCP – FULLY AUTOMATED & PRODUCTION READY
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

# ============================================================
#                    DEPLOYMENT BEGINS
# ============================================================

echo "Starting VProfile deployment in project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" --quiet

# ────────────────────────────────────────────────────────────────
# Enable all required GCP APIs
# ────────────────────────────────────────────────────────────────
echo "Enabling required GCP APIs"
gcloud services enable \
    compute.googleapis.com \
    dns.googleapis.com \
    sqladmin.googleapis.com \
    sql-component.googleapis.com \
    memcache.googleapis.com \
    certificatemanager.googleapis.com \
    servicenetworking.googleapis.com \
    --quiet

# ────────────────────────────────────────────────────────────────
# 1. Create custom VPC
# ────────────────────────────────────────────────────────────────
echo "Creating custom VPC network $VPC"
gcloud compute networks create "$VPC" \
    --subnet-mode=custom \
    --quiet

# ────────────────────────────────────────────────────────────────
# 2. Create public and private subnets
# ────────────────────────────────────────────────────────────────
echo "Creating public subnet $PUB_SUBNET_01"
gcloud compute networks subnets create "$PUB_SUBNET_01" \
    --network="$VPC" \
    --region="$REGION" \
    --range=172.20.1.0/24 \
    --quiet

echo "Creating public subnet $PUB_SUBNET_02"
gcloud compute networks subnets create "$PUB_SUBNET_02" \
    --network="$VPC" \
    --region="$REGION" \
    --range=172.20.2.0/24 \
    --quiet

echo "Creating private subnet $PRIV_SUBNET_01"
gcloud compute networks subnets create "$PRIV_SUBNET_01" \
    --network="$VPC" \
    --region="$REGION" \
    --range=172.20.3.0/24 \
    --quiet

echo "Creating private subnet $PRIV_SUBNET_02"
gcloud compute networks subnets create "$PRIV_SUBNET_02" \
    --network="$VPC" \
    --region="$REGION" \
    --range=172.20.4.0/24 \
    --quiet

# ────────────────────────────────────────────────────────────────
# 3. Create Cloud Router and Cloud NAT (for private subnet outbound)
# ────────────────────────────────────────────────────────────────
echo "Creating Cloud Router $ROUTER"
gcloud compute routers create "$ROUTER" \
    --network="$VPC" \
    --region="$REGION" \
    --quiet

echo "Creating Cloud NAT $NAT"
gcloud compute routers nats create "$NAT" \
    --router="$ROUTER" \
    --region="$REGION" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --enable-logging \
    --quiet

# ────────────────────────────────────────────────────────────────
# 4. Firewall: Allow SSH from your IP to bastion
# ────────────────────────────────────────────────────────────────
echo "Creating firewall rule allow-ssh-internet for bastion SSH"
gcloud compute firewall-rules create allow-ssh-internet \
    --network="$VPC" \
    --allow=tcp:22 \
    --source-ranges="$MY_IP" \
    --target-tags="$TAG_BASTION" \
    --direction=INGRESS \
    --quiet

# ────────────────────────────────────────────────────────────────
# 5. Firewall: Allow SSH from bastion to private app servers
# ────────────────────────────────────────────────────────────────
echo "Creating firewall rule allow-ssh-bastion for private app SSH"
gcloud compute firewall-rules create allow-ssh-bastion \
    --network="$VPC" \
    --allow=tcp:22 \
    --source-tags="$TAG_BASTION" \
    --target-tags="$TAG_APP" \
    --direction=INGRESS \
    --quiet

# ────────────────────────────────────────────────────────────────
# 6. Firewall: Allow Load Balancer health checks & traffic to app (port 8080)
# ────────────────────────────────────────────────────────────────
echo "Creating firewall rule allow-lb-to-app for LB traffic on 8080"
gcloud compute firewall-rules create allow-lb-to-app \
    --network="$VPC" \
    --allow=tcp:8080 \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --target-tags="$TAG_APP" \
    --direction=INGRESS \
    --quiet

# ────────────────────────────────────────────────────────────────
# 7. Create bastion host startup script
# ────────────────────────────────────────────────────────────────
echo "Creating bastion host startup script"
cat << EOF > bastion.sh
#!/bin/bash
set -e
useradd -m -s /bin/bash devops
echo "devops ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devops
mkdir -p /home/devops/.ssh
echo "$SSH_KEY" > /home/devops/.ssh/authorized_keys
chmod 700 /home/devops/.ssh
chmod 600 /home/devops/.ssh/authorized_keys
chown -R devops:devops /home/devops/.ssh
EOF

# ────────────────────────────────────────────────────────────────
# 8. Launch bastion host in public subnet
# ────────────────────────────────────────────────────────────────
echo "Launching bastion host $BASTION in public subnet"
gcloud compute instances create "$BASTION" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --subnet="$PUB_SUBNET_01" \
    --tags="$TAG_BASTION" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --metadata-from-file=startup-script=bastion.sh \
    --quiet