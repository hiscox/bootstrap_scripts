#!/bin/bash

pe_version=$1
bitbucket_username=$2
bitbucket_password=$3
bitbucket_team=$4
control_repo_name=$5
control_repo_url="git@bitbucket.org:$bitbucket_team/$control_repo_name.git"
console_admin_password=$6
console_url=$7
public_ip=$8

# download Puppet Enterprise installer
pe_source="https://s3.amazonaws.com/pe-builds/released/$pe_version/puppet-enterprise-$pe_version-el-7-x86_64.tar.gz"
curl -sL $pe_source | tar xz --strip-components=1 --directory /tmp

# create keys
mkdir -p /etc/puppetlabs/puppetserver/ssh
ssh-keygen -f /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa -N ''

# add deploy keys to repos
curl -X POST --user "$bitbucket_username:$bitbucket_password" \
"https://api.bitbucket.org/1.0/repositories/$bitbucket_team/$control_repo_name/deploy-keys" \
--data-urlencode "key=$(cat /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa.pub)&label=$console_url"

curl -s -X GET --user "$bitbucket_username:$bitbucket_password" \
"https://api.bitbucket.org/2.0/repositories/$bitbucket_team/$control_repo_name/src/production/Puppetfile" \
| grep "ssh://git@bitbucket.org/$bitbucket_team/" \
| sed "s|:git => 'ssh://git@bitbucket.org/$bitbucket_team/||" | sed "s|.git',||" \
| sed -e 's|^[[:space:]]*||' | while read -r repo; do
  curl -X POST --user "$bitbucket_username:$bitbucket_password" \
  "https://api.bitbucket.org/1.0/repositories/$bitbucket_team/$repo/deploy-keys" \
  --data-urlencode "key=$(cat /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa.pub)"
done

# install Puppet Enterprise"
echo "{
  \"console_admin_password\": \"$console_admin_password\",
  \"puppet_enterprise::puppet_master_host\": \"$(hostname --fqdn)\",
  \"pe_install::puppet_master_dnsaltnames\": [\"puppet\", \"$console_url\"],
  \"puppet_enterprise::profile::master::code_manager_auto_configure\": true,
  \"puppet_enterprise::profile::master::r10k_remote\": \"${control_repo_url}\",
  \"puppet_enterprise::profile::master::r10k_private_key\": \"/etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa\",
  \"puppet_enterprise::puppetdb_port\": \"8091\",
}" > /tmp/pe.conf

/tmp/puppet-enterprise-installer -c /tmp/pe.conf

# install required Puppet modules"
/opt/puppetlabs/bin/puppet module install keirans-azuremetadata
/opt/puppetlabs/bin/puppet module install puppetlabs-puppetserver_gem
/opt/puppetlabs/bin/puppet module install npwalker-pe_code_manager_webhook

# set up code manager"
chown pe-puppet:pe-puppet /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa
chown -R pe-puppet:pe-puppet /etc/puppetlabs/code/
/opt/puppetlabs/bin/puppet apply -e "include pe_code_manager_webhook::code_manager"
echo 'code_manager_mv_old_code=true' > /opt/puppetlabs/facter/facts.d/code_manager_mv_old_code.txt
/opt/puppetlabs/bin/puppet agent -t
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 -o /tmp/jq
chmod +x /tmp/jq
mv /tmp/jq /usr/bin/jq
token_file='/etc/puppetlabs/puppetserver/.puppetlabs/code_manager_service_user_token'
token=$(/usr/bin/jq '.token' $token_file -r)
echo $token > $token_file.raw

# add webhook to control repo
webhook="https://$public_ip:8170/code-manager/v1/webhook?type=bitbucket&token=$token"
curl -X POST --user "$bitbucket_username:$bitbucket_password" -H 'Content-Type: application/json' \
"https://api.bitbucket.org/2.0/repositories/$bitbucket_team/$control_repo_name/hooks" --data "
{
  \"description\": \"$console_url\",
  \"url\": \"$webhook\",
  \"active\": true,
  \"skip_cert_verification\": true,
  \"events\": [
    \"repo:push\"
  ]
}"

# hiera eyaml
/opt/puppetlabs/bin/puppetserver gem install hiera-eyaml
mkdir -p /etc/puppetlabs/puppet/eyaml
cd /tmp
/opt/puppetlabs/bin/puppetserver ruby /opt/puppetlabs/server/data/puppetserver/jruby-gems/gems/hiera-eyaml-2.1.0/bin/eyaml createkeys
mv /tmp/keys/private_key.pkcs7.pem /etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem
mv /tmp/keys/public_key.pkcs7.pem /etc/puppetlabs/puppet/eyaml/public_key.pkcs7.pem
echo "---
eyaml_public_key: |
$(cat /etc/puppetlabs/puppet/eyaml/public_key.pkcs7.pem | sed 's/^/  /')" > /opt/puppetlabs/facter/facts.d/eyaml_public_key.txt
service pe-puppetserver reload
chown -R pe-puppet:pe-puppet /etc/puppetlabs/puppet/eyaml
chmod -R 0500 /etc/puppetlabs/puppet/eyaml
chmod 0400 /etc/puppetlabs/puppet/eyaml/*.pem

# code deploy
/opt/puppetlabs/bin/puppet-code deploy --all --wait --token-file=$token_file.raw

# run puppet agent a few times to complete configuration
/opt/puppetlabs/bin/puppet agent -t
/opt/puppetlabs/bin/puppet agent -t
/opt/puppetlabs/bin/puppet agent -t

# allow agents to specify environment
id=$(curl -s -X GET "https://$(hostname --fqdn):4433/classifier-api/v1/groups" \
-H "Content-Type: application/json" \
--cert "/etc/puppetlabs/puppet/ssl/certs/$(hostname --fqdn).pem" \
--key "/etc/puppetlabs/puppet/ssl/private_keys/$(hostname --fqdn).pem" \
--cacert "/etc/puppetlabs/puppet/ssl/certs/ca.pem" \
| /usr/bin/jq '.[] | select(.name=="Agent-specified environment)"' \
| /usr/bin/jq -r '.["id"]')

curl -X POST "https://$(hostname --fqdn):4433/classifier-api/v1/groups/$id" \
-H "Content-Type: application/json" \
--cert "/etc/puppetlabs/puppet/ssl/certs/$(hostname --fqdn).pem" \
--key "/etc/puppetlabs/puppet/ssl/private_keys/$(hostname --fqdn).pem" \
--cacert "/etc/puppetlabs/puppet/ssl/certs/ca.pem" \
--data '
{
  "rule": [
    "and",
    [
      "not",
      [
        "=",
        [
          "fact",
          "agent_specified_environment"
        ],
        "production"
      ]
    ]
  ]
}
'