#!/bin/bash

set -e

sudo firewall-cmd --zone=libvirt --add-service=http --permanent
sudo firewall-cmd --zone=libvirt --add-service=https --permanent
sudo firewall-cmd --zone=libvirt --add-service=dns --permanent
sudo firewall-cmd --zone=libvirt --add-port=3128/tcp --permanent
sudo firewall-cmd --reload 
