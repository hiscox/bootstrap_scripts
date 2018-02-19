#!/bin/bash
set -e

puppet_master=$1
puppet_environment=$2
puppet_role=$3
puppet_autosign_key=$4

# create puppet environment directory if not production
if [ "$puppet_environment" != 'production' ]; then
  mkdir -p "/etc/puppetlabs/code/environments/$puppet_environment"
fi

# install puppet agent frictionless
curl -k "https://$puppet_master:8140/packages/current/install.bash" \
| sudo bash -s "main:environment=$puppet_environment" "custom_attributes:challengePassword=$puppet_autosign_key" "extension_requests:pp_role=$puppet_role"