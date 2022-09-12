#!/usr/bin/env bash

imds_token=$( curl -Ss -H "X-aws-ec2-metadata-token-ttl-seconds: 30" -XPUT 169.254.169.254/latest/api/token )
instance_id=$( curl -Ss -H "X-aws-ec2-metadata-token: $imds_token" 169.254.169.254/latest/meta-data/instance-id )
local_ipv4=$( curl -Ss -H "X-aws-ec2-metadata-token: $imds_token" 169.254.169.254/latest/meta-data/local-ipv4 )

# install package

curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
apt-get update
apt-get install -y vault=${vault_version}-* awscli jq

echo "Configuring system time"
timedatectl set-timezone UTC

# removing any default installation files from /opt/vault/tls/
rm -rf /opt/vault/tls/*

# /opt/vault/tls should be readable by all users of the system
chmod 0755 /opt/vault/tls

# vault-key.pem should be readable by the vault group only
touch /opt/vault/tls/vault-key.pem
chown root:vault /opt/vault/tls/vault-key.pem
chmod 0640 /opt/vault/tls/vault-key.pem

secret_result=$(aws secretsmanager get-secret-value --secret-id ${secrets_manager_arn} --region ${region} --output text --query SecretString)

jq -r .vault_cert <<< "$secret_result" | base64 -d > /opt/vault/tls/vault-cert.pem

jq -r .vault_ca <<< "$secret_result" | base64 -d > /opt/vault/tls/vault-ca.pem

jq -r .vault_pk <<< "$secret_result" | base64 -d > /opt/vault/tls/vault-key.pem

cat << EOF > /etc/vault.d/vault.hcl
ui = true
disable_mlock = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "$instance_id"
  retry_join {
    auto_join = "provider=aws region=${region} tag_key=${name}-vault tag_value=server"
    auto_join_scheme = "https"
    leader_tls_servername = "${leader_tls_servername}"
    leader_ca_cert_file = "/opt/vault/tls/vault-ca.pem"
    leader_client_cert_file = "/opt/vault/tls/vault-cert.pem"
    leader_client_key_file = "/opt/vault/tls/vault-key.pem"
  }
}

cluster_addr = "https://$local_ipv4:8201"
api_addr = "https://$local_ipv4:8200"

listener "tcp" {
  address            = "0.0.0.0:8200"
  tls_disable        = false
  tls_cert_file      = "/opt/vault/tls/vault-cert.pem"
  tls_key_file       = "/opt/vault/tls/vault-key.pem"
  tls_client_ca_file = "/opt/vault/tls/vault-ca.pem"
}

seal "awskms" {
  region     = "${region}"
  kms_key_id = "${kms_key_arn}"
}

EOF

# vault.hcl should be readable by the vault group only
chown root:root /etc/vault.d
chown root:vault /etc/vault.d/vault.hcl
chmod 640 /etc/vault.d/vault.hcl

systemctl enable vault
systemctl start vault

echo "Setup Vault profile" 
cat <<PROFILE | sudo tee /etc/profile.d/vault.sh
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/vault-ca.pem"
PROFILE

echo "Download Vault automated backup task"
wget https://github.com/luong-komorebi/vault_raft_snapshot_agent/releases/download/custom_0.0.1/vault_raft_snapshot_agent
chmod +x vault_raft_snapshot_agent
sudo mv vault_raft_snapshot_agent /usr/local/bin/vault_raft_snapshot_agent

echo "Create systemd service for backup task"
sudo tee /etc/systemd/system/vault-snapshot.service <<EOF
[Unit]
Description="An Open Source Snapshot Service for Raft"
Documentation=https://github.com/Lucretius/vault_raft_snapshot_agent/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/snapshot.json
[Service]
Type=simple
User=vault
Group=vault
ExecStart=/usr/local/bin/vault_raft_snapshot_agent
ExecReload=/usr/local/bin/vault_raft_snapshot_agent
KillMode=process
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

echo "Create vault policy for taking snapshot"
tee snapshot_policy.hcl <<EOF
path "/sys/storage/raft/snapshot"
{
  capabilities = ["read"]
}
EOF

# use the above result to create a snapshot configuration
echo "Create snapshot configurations"
sudo tee /etc/vault.d/snapshot.json <<EOF
{
   "retain":10,
   "frequency":"1h",
   "role_id": "62cd6d5f-b088-b5cf-8baa-86c067b0cbf0",
   "secret_id": "640ac304-51b0-16dd-5d38-1793226bc77c",
   "aws_storage":{
      "s3_region":"us-west-2",
      "s3_bucket":"${name}-vault-snapshots"
   }
}
EOF

systemctl enable vault-snapshot
systemctl start vault-snapshot