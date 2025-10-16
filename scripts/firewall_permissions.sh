#!/bin/bash

set -e

echo "Configuring firewall rules for libvirt zone..."
sudo firewall-cmd --zone=libvirt --add-service=http --permanent
sudo firewall-cmd --zone=libvirt --add-service=https --permanent
sudo firewall-cmd --zone=libvirt --add-service=dns --permanent
sudo firewall-cmd --zone=libvirt --add-port=3128/tcp --permanent
sudo firewall-cmd --reload
echo "  ✓ Firewall configured (http, https, dns, proxy:3128)"
echo "" 
