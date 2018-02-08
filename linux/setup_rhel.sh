#!/bin/bash

ip_address=$1
dns_suffix=$2

# set hostname in hosts
if ! grep -Fq "$ip_address $(hostname).$dns_suffix $(hostname)" /etc/hosts ; then
  echo "$ip_address $(hostname).$dns_suffix $(hostname)" >> /etc/hosts
fi

# set dns
sed -i "s/reddog.microsoft.com/$dns_suffix/g" /etc/resolv.conf

# turn off local firewall as we have subnet and NIC level NSGs
systemctl stop firewalld.service
systemctl disable firewalld.service