#!/bin/bash

LOCK_FILE="/var/run/docker-watch-eth0.lock"
IPTABLES_LOCK="/var/lock/iptables.lock"

# Function to check and remove stale lock files (older than 8 seconds)
cleanup_stale_locks() {
    # Remove stale script lock
    if [[ -f "$LOCK_FILE" ]]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
        if [[ $LOCK_AGE -gt 5 ]]; then
            logger -t userscript2[$$] "$(date): Stale script lock detected (age: $LOCK_AGE seconds). Removing..."
            rm -f "$LOCK_FILE"
        fi
    fi

    # Remove stale iptables lock
    if [[ -f "$IPTABLES_LOCK" ]]; then
        IPTABLES_LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$IPTABLES_LOCK") ))
        if [[ $IPTABLES_LOCK_AGE -gt 5 ]]; then
            logger -t userscript2[$$] "$(date): Stale iptables lock detected (age: $IPTABLES_LOCK_AGE seconds). Removing..."
            rm -f "$IPTABLES_LOCK"
        fi
    fi
}

# Ensure only one instance runs at a time
cleanup_stale_locks
if [[ -f "$LOCK_FILE" ]]; then
    logger -t userscript2[$$] "$(date): Another instance is already running. Exiting."
    exit 1
fi

# Trap to remove lock file and release iptables lock on exit
trap 'rm -f "$LOCK_FILE"; exec 200>&-; exit' INT TERM EXIT

# Start a background process to keep the lock file updated every 5 seconds
( while true; do
    sleep 3
    touch "$LOCK_FILE"
done ) &

# Function to acquire iptables lock safely
acquire_iptables_lock() {
    exec 200>"$IPTABLES_LOCK"
    logger -t userscript2[$$] "$(date): Waiting for iptables lock..."
    flock -x -w 5 200 || {
        logger -t userscript2[$$] "$(date): Timed out waiting for iptables lock"
        exit 1
    }
    logger -t userscript2[$$] "$(date): Acquired iptables lock."
    trap 'release_iptables_lock' EXIT  # Ensures release even on crash
}

# Function to release iptables lock
release_iptables_lock() {
    exec 200>&-  # Close the lock descriptor
    rm -f "$IPTABLES_LOCK"  # Ensure lock file is removed
    logger -t userscript2[$$] "$(date): Released iptables lock."
}

# Function to get the eth0 IP from iptables rules
get_current_eth0_ip() {
    acquire_iptables_lock
    local ip
    ip=$(iptables-save | grep -- "-A INPUT -m comment --comment \"block docker subnets to management ip\"" | awk '{print $(NF)}' | head -n 1)
    release_iptables_lock
    echo "$ip"
}

# Function to remove duplicate iptables rules **by exact match instead of line number**
remove_duplicate_rules() {
    acquire_iptables_lock
    logger -t userscript2[$$] "Checking for duplicate iptables rules..."

    iptables-save | grep -- "-A INPUT -m comment --comment \"block docker subnets to management ip\"" | while read -r rule; do
        logger -t userscript2[$$] "Removing duplicate rule: $rule"
        iptables -D INPUT -m comment --comment "block docker subnets to management ip" -j DROP
    done

    release_iptables_lock
}

# Function to remove an iptables rule for a specific subnet **by match**
remove_iptables_rule() {
    local subnet="$1"
    acquire_iptables_lock
    logger -t userscript2[$$] "Checking for existing rules for subnet $subnet..."

    iptables-save | grep -- "-A INPUT -s $subnet -m comment --comment \"block docker subnets to management ip\"" | while read -r rule; do
        logger -t userscript2[$$] "Removing rule for subnet $subnet: $rule"
        iptables -D INPUT -s "$subnet" -m comment --comment "block docker subnets to management ip" -j DROP
    done

    release_iptables_lock
}

# Function to apply iptables rule if Docker is running
apply_iptables_rule() {
    if [ ! -S /var/run/docker.sock ]; then
        logger -t userscript2[$$] "$(date): Docker is not running. Skipping iptables update."
        return
    fi

    DEFAULT_SUBNET="172.17.0.0/16"
    BLOCKED_SUBNET=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)
    BLOCKED_SUBNET=${BLOCKED_SUBNET:-$DEFAULT_SUBNET}

    logger -t userscript2[$$] "Blocked Subnet: $BLOCKED_SUBNET"

    IPTABLES_ETH0_IP=$(get_current_eth0_ip)
    while true; do
        ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        [[ -n "$ETH0_IP" ]] && break
        logger -t userscript2[$$] "Error: Unable to determine eth0 IP. Retrying..."
        sleep 2
    done

    logger -t userscript2[$$] "eth0 IP: $ETH0_IP"

    if [[ "$ETH0_IP" != "$IPTABLES_ETH0_IP" ]]; then
        logger -t userscript2[$$] "eth0 IP changed! Updating iptables rules..."
        remove_duplicate_rules
        remove_iptables_rule "$BLOCKED_SUBNET"
        acquire_iptables_lock

        # Check if rule already exists
        if iptables-save | grep -q -- "-A INPUT -s $BLOCKED_SUBNET -d $ETH0_IP -m comment --comment \"block docker subnets to management ip\""; then
            logger -t userscript2[$$] "$(date): Rule already exists. Skipping addition."
        else
            logger -t userscript2[$$] "$(date): Applying iptables rule..."
            iptables -I INPUT -s "$BLOCKED_SUBNET" -d "$ETH0_IP" -j DROP -m comment --comment "block docker subnets to management ip"
            logger -t userscript2[$$] "$(date): Applied iptables rule for subnet $BLOCKED_SUBNET."
        fi

        release_iptables_lock
    else
        logger -t userscript2[$$] "eth0 IP unchanged, no updates required."
    fi
}

# Run once initially
apply_iptables_rule

logger -t userscript2[$$] "Monitoring Docker restarts and eth0 IP changes..."

# Infinite loop to monitor Docker and eth0 IP address
while true; do
    if [ ! -S /var/run/docker.sock ]; then
        logger -t userscript2[$$] "$(date): Docker stopped. Waiting for restart..."
        inotifywait -e create /var/run 2>/dev/null
        while [ ! -S /var/run/docker.sock ]; do sleep 1; done
        logger -t userscript2[$$] "$(date): Docker restarted. Re-applying iptables rule..."
        sleep 2.5
        apply_iptables_rule
    fi
    sleep 5
done
