#!/bin/bash
# Checks the external IP on AWS, GCP, and Azure

curl http://169.254.169.254/latest/meta-data/public-ipv4 # AWS
curl -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip # GCP
curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" # Azure
