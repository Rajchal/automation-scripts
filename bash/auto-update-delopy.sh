#!/bin/bash
cd /var/www/myapp || exit
git pull origin main
systemctl restart nginx
echo "Deployment completed!"
