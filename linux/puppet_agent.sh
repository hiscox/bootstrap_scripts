#!/bin/bash
set -e

# set hostname in hosts
if ! grep -Fq "${ip_address} ${hostname}.${dns_suffix} ${hostname}" /etc/hosts ; then
  echo "${ip_address} ${hostname}.${dns_suffix} ${hostname}" >> /etc/hosts
fi

# set dns
sed -i "s/reddog.microsoft.com/${dns_suffix}/g" /etc/resolv.conf

# turn off local firewall as we have subnet and NIC level NSGs
systemctl --quiet stop firewalld.service
systemctl --quiet disable firewalld.service

# yum update
yum update -y -q -e 0

# install puppet agent
# check if puppet is already installed
if ! rpm -qa | grep -q puppet ; then

  # if puppet master is specified then connect to it
  if [ ! -z "${puppet_master}" ]; then

    # create puppet environment directory if not production
    if [ ! -z "${puppet_environment}" -a "${puppet_environment}" != 'production' ]; then
      mkdir -p /etc/puppetlabs/code/environments/${puppet_environment}
    fi

    # install puppet agent frictionless
    curl -k https://${puppet_master}:8140/packages/current/install.bash | sudo bash -s main:environment=${puppet_environment} custom_attributes:challengePassword=${puppet_autosign_key} extension_requests:pp_role=${puppet_role}
    
  fi
fi
