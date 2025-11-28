#!/bin/bash
set -e

# ============================================================
#    VPROFILE FRONTEND PART 1 ON GCP 
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
PRIVATE_DNS="vprofile.internal"

TAG_BASTION="bastion"
TAG_APP="app"


# ────────────────────────────────────────────────────────────────
# 14. Create private DNS zone for internal service discovery
# ────────────────────────────────────────────────────────────────
echo "Creating private DNS zone for internal service discovery"
gcloud dns managed-zones create "$PRIVATE_ZONE" \
    --dns-name="$PRIVATE_DNS" \
    --networks="$VPC" \
    --visibility=private \
    --description="Private DNS for VProfile" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 15. Get private IPs of DB and Memcached
# ────────────────────────────────────────────────────────────────
echo "Getting private IPs of DB and Memcached"
DB_IP=$(gcloud sql instances describe "$DB" --format="value(ipAddresses[0].ipAddress)")
MC_IP=$(gcloud memcache instances describe "$MEMCACHE" --region="$REGION" --format="value(memcacheNodes[0].host)")

echo "Database IP: $DB_IP"
echo "Memcached IP: $MC_IP"
# ────────────────────────────────────────────────────────────────
# 16. Add A records so app can resolve vprodb.vprofile.local & vpromc.vprofile.local
# ────────────────────────────────────────────────────────────────

# Start transaction for database A record addition
echo "Starting transaction for database A record addition"
gcloud dns record-sets transaction start \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"

# Add A record for database (vprodb subdomain pointing to DB IP)
echo "Adding A record for database"
gcloud dns record-sets transaction add $DB_IP \
    --name="vprodb."$PRIVATE_DNS"." \
    --type=A \
    --ttl=300 \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"

# Execute/commit the transaction to apply DB record
echo "Executing transaction for DB record"
gcloud dns record-sets transaction execute \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"

# List records to verify DB A record was added
echo "Listing records to verify DB A record"
gcloud dns record-sets list \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"

# Start transaction for Memcached A record addition
echo "Starting transaction for Memcached A record addition"
gcloud dns record-sets transaction start \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"

# Add A record for Memcached (vpromc subdomain pointing to MC IP)
echo "Adding A record for Memcached"
gcloud dns record-sets transaction add $MC_IP \
    --name="vpromc."$PRIVATE_DNS"." \
    --type=A \
    --ttl=300 \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"

# Execute/commit the transaction to apply MC record
echo "Executing transaction for MC record"
gcloud dns record-sets transaction execute \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"

# List records to verify MC A record was added
echo "Listing records to verify MC A record"
gcloud dns record-sets list \
    --zone="$PRIVATE_ZONE" \
    --project="$PROJECT_ID"
# ────────────────────────────────────────────────────────────────
# 17. Create startup script for golden app instance
# ────────────────────────────────────────────────────────────────
echo "Creating startup script for golden app instance"
cat << EOF > app-golden.sh
#!/bin/bash
set -e

# Create devops user and setup SSH key
useradd -m -s /bin/bash devops
echo "devops ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devops
mkdir -p /home/devops/.ssh
echo "$SSH_KEY" > /home/devops/.ssh/authorized_keys
chmod 700 /home/devops/.ssh
chmod 600 /home/devops/.ssh/authorized_keys
chown -R devops:devops /home/devops/.ssh

sleep 60
TOMURL="https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.26/bin/apache-tomcat-10.1.26.tar.gz"
apt update -y
apt install -y openjdk-17-jdk openjdk-17-jdk-headless git wget unzip zip rsync

cd /tmp/
wget \$TOMURL -O tomcatbin.tar.gz
EXTOUT=\$(tar xzvf tomcatbin.tar.gz)
TOMDIR=\$(echo "\$EXTOUT" | cut -d '/' -f1)

useradd --shell /bin/false --system tomcat
rsync -avzh /tmp/\$TOMDIR/ /usr/local/tomcat/
chown -R tomcat:tomcat /usr/local/tomcat

cat > /etc/systemd/system/tomcat.service << 'EOL'
[Unit]
Description=Apache Tomcat 10
After=network.target

[Service]
Type=simple
User=tomcat
Group=tomcat
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
Environment="CATALINA_PID=/tmp/tomcat.pid"
Environment="CATALINA_HOME=/usr/local/tomcat"
Environment="CATALINA_BASE=/usr/local/tomcat"
ExecStart=/usr/local/tomcat/bin/startup.sh
ExecStop=/usr/local/tomcat/bin/shutdown.sh
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable --now tomcat

cd /tmp/
wget https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.zip
unzip apache-maven-3.9.9-bin.zip
cp -r apache-maven-3.9.9 /usr/local/maven3.9

export MAVEN_OPTS="-Xmx512m"

git clone -b gcp https://github.com/hkhcoder/vprofile-project.git
cd vprofile-project
/usr/local/maven3.9/bin/mvn install

systemctl stop tomcat
sleep 20
rm -rf /usr/local/tomcat/webapps/ROOT*
cp target/vprofile-v2.war /usr/local/tomcat/webapps/ROOT.war
systemctl start tomcat
sleep 20

ufw allow 8080/tcp || true
systemctl restart tomcat
EOF

# ────────────────────────────────────────────────────────────────
# 18. Launch golden instance (to build final image)
# ────────────────────────────────────────────────────────────────
echo "Launching golden instance to build final image"
gcloud compute instances create "$GOLDEN" \
    --zone="$ZONE" \
    --machine-type=e2-small \
    --subnet="$PRIV_SUBNET_01" \
    --no-address \
    --tags="$TAG_APP" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --metadata-from-file=startup-script=app-golden.sh \
    --quiet

echo "Waiting 12 minutes for application build and Tomcat startup..."
sleep 720

# ────────────────────────────────────────────────────────────────
# 19. Stop instance and create snapshot
# ────────────────────────────────────────────────────────────────
echo "Stopping golden instance"
gcloud compute instances stop "$GOLDEN" --zone="$ZONE" --quiet

echo "Creating snapshot from golden instance"
gcloud compute disks snapshot "$GOLDEN" \
    --snapshot-names="$SNAPSHOT" \
    --zone="$ZONE" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 20. Create custom image from snapshot
# ────────────────────────────────────────────────────────────────
echo "Creating custom image from snapshot"
gcloud compute images create "$IMAGE" \
    --source-snapshot="$SNAPSHOT" \
    --storage-location="$REGION" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 21. Delete golden instance (no longer needed)
# ────────────────────────────────────────────────────────────────
echo "Deleting golden instance"
gcloud compute instances delete "$GOLDEN" --zone="$ZONE" --quiet || true

# ────────────────────────────────────────────────────────────────
# 22. Create instance template from custom image
# ────────────────────────────────────────────────────────────────
echo "Creating instance template from custom image"
gcloud compute instance-templates create "$TEMPLATE" \
    --machine-type=e2-micro \
    --image="$IMAGE" \
    --subnet="$PRIV_SUBNET_01" \
    --region="$REGION" \
    --no-address \
    --tags="$TAG_APP" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 23. Create Managed Instance Group (MIG)
# ────────────────────────────────────────────────────────────────
echo "Creating Managed Instance Group"
gcloud compute instance-groups managed create "$MIG" \
    --zone="$ZONE" \
    --template="$TEMPLATE" \
    --size=2 \
    --quiet

# ────────────────────────────────────────────────────────────────
# 24. Set named port so load balancer knows port 8080 = http
# ────────────────────────────────────────────────────────────────
echo "Setting named ports for MIG"
gcloud compute instance-groups managed set-named-ports "$MIG" \
    --zone="$ZONE" \
    --named-ports=http:8080 \
    --quiet

# ────────────────────────────────────────────────────────────────
# 25. Create HTTP health check
# ────────────────────────────────────────────────────────────────
echo "Creating HTTP health check"
gcloud compute health-checks create http "$HEALTH_CHECK" \
    --global \
    --port=8080 \
    --request-path=/ \
    --quiet

# ────────────────────────────────────────────────────────────────
# 26. Create global backend service
# ────────────────────────────────────────────────────────────────
echo "Creating global backend service"
gcloud compute backend-services create "$BACKEND" \
    --global \
    --protocol=HTTP \
    --port-name=http \
    --health-checks="$HEALTH_CHECK" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 27. Attach MIG to backend service
# ────────────────────────────────────────────────────────────────
echo "Attaching MIG to backend service"
gcloud compute backend-services add-backend "$BACKEND" \
    --global \
    --instance-group="$MIG" \
    --instance-group-zone="$ZONE" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 28. Create URL map (routing rules)
# ────────────────────────────────────────────────────────────────
echo "Creating URL map"
gcloud compute url-maps create "$URL_MAP" \
    --default-service="$BACKEND" \
    --quiet

# ────────────────────────────────────────────────────────────────
# 29. Create HTTP  proxy
# ────────────────────────────────────────────────────────────────
echo "Creating HTTP proxy"
gcloud compute target-http-proxies create "$HTTP_PROXY" \
    --url-map="$URL_MAP" \
    --quiet



# ────────────────────────────────────────────────────────────────
# 30. Reserve global static IP for load balancer
# ────────────────────────────────────────────────────────────────
echo "Reserving global static IP for load balancer"
gcloud compute addresses create "$LB_IP" --global --quiet

# ────────────────────────────────────────────────────────────────
# 31. Create DNS authorization for Google-managed SSL certificate
# ────────────────────────────────────────────────────────────────
echo "Creating DNS authorization for SSL certificate"
gcloud certificate-manager dns-authorizations create auth-"$SUBDOMAIN" \
    --domain="$DOMAIN" \
    --quiet

echo ""
echo "=== ADD THESE CNAME RECORDS TO YOUR DOMAIN REGISTRAR (GoDaddy, etc.) ==="
echo "Describing DNS authorization for CNAME records"
gcloud certificate-manager dns-authorizations describe auth-"$SUBDOMAIN" \
    --format="table(dnsResourceRecord.name,dnsResourceRecord.type,dnsResourceRecord.data)"