#!/bin/bash
# inactive_user_report.sh
# Reports users who have not logged in for a specified number of days
THRESHOLD=30
EMAIL="admin@example.com"
REPORT=""
while IFS=: read -r user _ uid _ _ _ home _; do
    if [ "$uid" -ge 1000 ] && [ -d "$home" ]; then
        last_login=$(lastlog -u "$user" | awk 'NR==2 {print $4,$5,$6}')
        if [ "$last_login" != "**Never logged in**" ]; then
            last_login_date=$(date -d "$last_login" +%s 2>/dev/null)
            now=$(date +%s)
            days_inactive=$(( (now - last_login_date) / 86400 ))
            if [ "$days_inactive" -ge "$THRESHOLD" ]; then
                REPORT+="$user has been inactive for $days_inactive days\n"
            fi
        fi
    fi
done < /etc/passwd
if [ -n "$REPORT" ]; then
    echo -e "$REPORT" | mail -s "Inactive User Report" $EMAIL
fi
