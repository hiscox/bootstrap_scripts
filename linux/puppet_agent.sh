#!/bin/bash
set -e

puppet_master=$1
puppet_environment=$2
puppet_role=$3
puppet_autosign_key=$4

# install puppet agent
# check if puppet is already installed
if ! rpm -qa | grep -q puppet ; then

  # if puppet master is specified then connect to it
  if [ ! -z "$puppet_master" ]; then

    # create puppet environment directory if not production
    if [ ! -z "$puppet_environment" -a "$puppet_environment" != 'production' ]; then
      mkdir -p "/etc/puppetlabs/code/environments/$puppet_environment"
    fi

    # install puppet agent frictionless
    curl -k "https://$puppet_master:8140/packages/current/install.bash" | sudo bash -s "main:environment=$puppet_environment" "custom_attributes:challengePassword=$puppet_autosign_key" "extension_requests:pp_role=$puppet_role"
    
  fi
fi
