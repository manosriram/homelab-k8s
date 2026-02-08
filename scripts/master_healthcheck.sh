#!/bin/bash

URL="https://hc-ping.com/fa9173c1-0fe1-45dc-a939-43d7abe120c3"
TIMEOUT=5

if curl -sf --connect-timeout $TIMEOUT "$URL" > /dev/null 2>&1; then
    echo "✓ $URL is UP"
    exit 0
else
    echo "✗ $URL is DOWN"
    exit 1
fi
