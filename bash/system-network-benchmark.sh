#!/bin/bash
#
# System Network Benchmark
# ------------------------
# A script to quickly check system network performance (latency and download speed)
# using ping and curl, with optional fallback to speedtest-cli if available.
#

echo "======================================"
echo "    System Network Benchmark Tool    "
echo "======================================"
echo "Time: $(date)"
echo ""

# Function to check command existence
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. Ping Latency Test
echo "[1] Latency Test (Ping)"
echo "-----------------------"
HOSTS=("8.8.8.8" "1.1.1.1" "github.com")

for HOST in "${HOSTS[@]}"; do
    echo -n "Pinging $HOST... "
    if ping -c 4 "$HOST" > /dev/null 2>&1; then
        AVG_LATENCY=$(ping -c 4 "$HOST" | tail -1 | awk '{print $4}' | cut -d '/' -f 2)
        echo "${AVG_LATENCY} ms (Avg)"
    else
        echo "Failed"
    fi
done
echo ""

# 2. Basic Download Speed Test using curl
echo "[2] Basic Download Speed Test"
echo "-----------------------------"
echo "Downloading 100MB test file from Cloudflare..."
if command_exists curl; then
    # Download a 100MB speed test file and format output
    curl -o /dev/null -s -w "Speed: %{speed_download} bytes/sec\nTime: %{time_total} sec\n" \
    https://speed.cloudflare.com/__down?bytes=104857600
    
    # Let's do a more human readable form manually
    # 104857600 bytes = 100 MB
    echo "Note: The above speed is in bytes/second. Divide by 1024/1024 for MB/s."
else
    echo "curl is not installed. Cannot perform download test."
fi
echo ""

# 3. Comprehensive test using speedtest-cli (if installed)
echo "[3] Advanced Speed Test (speedtest-cli)"
echo "---------------------------------------"
if command_exists speedtest-cli; then
    echo "Running speedtest-cli... This may take a minute."
    speedtest-cli --simple
elif command_exists speedtest; then
    echo "Running speedtest (Ookla)... This may take a minute."
    speedtest --accept-license --accept-gdpr
else
    echo "speedtest-cli / speedtest not found."
    echo "To get full bandwidth testing, install speedtest-cli: "
    echo "  sudo apt install speedtest-cli  (or pip install speedtest-cli)"
fi

echo ""
echo "======================================"
echo "           Benchmark Complete         "
echo "======================================"
