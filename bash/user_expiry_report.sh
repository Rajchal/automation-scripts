#!/bin/bash
# user_expiry_report.sh
# Reports users whose accounts are expiring within a specified number of days
THRESHOLD=7
EMAIL="admin@example.com"
expiring_users=$(chage -l $(awk -F: '$2 >= 1000 {print $1}' /etc/passwd) 2>/dev/null | grep 'Account expires' | grep -v 'never' | awk -v threshold=$THRESHOLD -F': ' '{
    split($2, a, "-");
    expiry_date=mktime(a[3]" "a[2]" "a[1]" 0 0 0");
    now=systime();
    days_left=(expiry_date-now)/86400;
    if(days_left<=threshold && days_left>=0) print $0;
}')
if [ -n "$expiring_users" ]; then
    echo -e "Expiring users within $THRESHOLD days:\n$expiring_users" | mail -s "User Expiry Report" $EMAIL
fi
