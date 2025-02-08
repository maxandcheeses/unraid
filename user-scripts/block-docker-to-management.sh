#!/bin/bash

LOCK_FILE="/var/run/docker-watch-eth0.lock"
IPTABLES_LOCK="/var/lock/iptables.lock"
IPTABLES_COMMENT="block docker subnets to management ip"  # Easily change this comment
SCRIPT_ID=userscript2

# Function to check and remove stale lock files (older than 8 seconds)
cleanup_stale_locks() {
    # Remove stale script lock
    if [[ -f "$LOCK_FILE" ]]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
        if [[ $LOCK_AGE -gt 5 ]]; then
            logger -t $SCRIPT_ID[$$] "$(date): Stale script lock detected (age: $LOCK_AGE seconds). Removing..."
            rm -f "$LOCK_FILE"
        fi
    fi

    # Remove stale iptables lock
    if [[ -f "$IPTABLES_LOCK" ]]; then
        IPTABLES_LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$IPTABLES_LOCK") ))
        if [[ $IPTABLES_LOCK_AGE -gt 5 ]]; then
            logger -t $SCRIPT_ID[$$] "$(date): Stale iptables lock detected (age: $IPTABLES_LOCK_AGE seconds). Removing..."
            rm -f "$IPTABLES_LOCK"
        fi
    fi
}

# Ensure only one instance runs at a time
cleanup_stale_locks
if [[ -f "$LOCK_FILE" ]]; then
    logger -t $SCRIPT_ID[$$] "$(date): Another instance is already running. Exiting."
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
    logger -t $SCRIPT_ID[$$] "$(date): Waiting for iptables lock..."
    flock -x -w 5 200 || {
        logger -t $SCRIPT_ID[$$] "$(date): Timed out waiting for iptables lock"
        exit 1
    }
    logger -t $SCRIPT_ID[$$] "$(date): Acquired iptables lock."
    trap 'release_iptables_lock' EXIT  # Ensures release even on crash
}

# Function to release iptables lock
release_iptables_lock() {
    exec 200>&-  # Close the lock descriptor
    rm -f "$IPTABLES_LOCK"  # Ensure lock file is removed
    logger -t $SCRIPT_ID[$$] "$(date): Released iptables lock."
}

# Function to get the eth0 IP from iptables rules
get_current_eth0_ip() {
    acquire_iptables_lock
    local ip
    ip=$(iptables-save | grep -- "-A INPUT -m comment --comment \"$IPTABLES_COMMENT\"" | awk '{print $(NF-2)}' | head -n 1)
    release_iptables_lock
    echo "$ip"
}

# Function to remove duplicate iptables rules **by exact match**
remove_duplicate_rules() {
    acquire_iptables_lock
    logger -t $SCRIPT_ID[$$] "Checking for duplicate iptables rules in INPUT..."

    while read -r rule; do
        SRC_IP=$(echo "$rule" | grep -oP '(?<=-s )[^ ]+')
        DST_IP=$(echo "$rule" | grep -oP '(?<=-d )[^ ]+/32')

        if [[ -n "$SRC_IP" && -n "$DST_IP" ]]; then
            logger -t $SCRIPT_ID[$$] "Removing duplicate rule: $rule"
            iptables -D INPUT -s "$SRC_IP" -d "$DST_IP" -m comment --comment "$IPTABLES_COMMENT" -j DROP
        else
            logger -t $SCRIPT_ID[$$] "Skipping malformed rule: $rule"
        fi
    done < <(iptables-save | grep -E -- '-A INPUT -s [0-9./]+ -d [0-9.]+/32 -m comment --comment "'"$IPTABLES_COMMENT"'"')

    release_iptables_lock
}

# Function to remove an iptables rule for a specific subnet **by exact match**
remove_iptables_rule() {
    local subnet="$1"
    local eth0_ip="$2"
    acquire_iptables_lock
    logger -t $SCRIPT_ID[$$] "Checking for existing rules for subnet $subnet and destination $eth0_ip..."

    iptables-save | grep -- "-A INPUT -s $subnet -d $eth0_ip -m comment --comment \"$IPTABLES_COMMENT\"" | while read -r rule; do
        logger -t $SCRIPT_ID[$$] "Removing rule: $rule"
        iptables -D INPUT -s "$subnet" -d "$eth0_ip" -m comment --comment "$IPTABLES_COMMENT" -j DROP
    done

    release_iptables_lock
}

# Function to apply iptables rule if Docker is running
apply_iptables_rule() {
    if [ ! -S /var/run/docker.sock ]; then
        logger -t $SCRIPT_ID[$$] "$(date): Docker is not running. Skipping iptables update."
        return
    fi

    DEFAULT_SUBNET="172.17.0.0/16"
    BLOCKED_SUBNET=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)
    BLOCKED_SUBNET=${BLOCKED_SUBNET:-$DEFAULT_SUBNET}

    logger -t $SCRIPT_ID[$$] "Blocked Subnet: $BLOCKED_SUBNET"

    IPTABLES_ETH0_IP=$(get_current_eth0_ip)
    while true; do
        ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        [[ -n "$ETH0_IP" ]] && break
        logger -t $SCRIPT_ID[$$] "Error: Unable to determine eth0 IP. Retrying..."
        sleep 2
    done

    logger -t $SCRIPT_ID[$$] "eth0 IP: $ETH0_IP"

    if [[ "$ETH0_IP" != "$IPTABLES_ETH0_IP" ]]; then
        logger -t $SCRIPT_ID[$$] "eth0 IP changed! Updating iptables rules..."
        remove_duplicate_rules
        remove_iptables_rule "$BLOCKED_SUBNET" "$ETH0_IP"
        acquire_iptables_lock

        if iptables-save | grep -q -- "-A INPUT -s $BLOCKED_SUBNET -d $ETH0_IP -m comment --comment \"$IPTABLES_COMMENT\""; then
            logger -t $SCRIPT_ID[$$] "$(date): Rule already exists. Skipping addition."
        else
            logger -t $SCRIPT_ID[$$] "$(date): Applying iptables rule..."
            iptables -I INPUT -s "$BLOCKED_SUBNET" -d "$ETH0_IP" -j DROP -m comment --comment "$IPTABLES_COMMENT"
            logger -t $SCRIPT_ID[$$] "$(date): Applied iptables rule for subnet $BLOCKED_SUBNET."
        fi

        release_iptables_lock
    else
        logger -t $SCRIPT_ID[$$] "eth0 IP unchanged, no updates required."
    fi
}

# Run once initially
apply_iptables_rule
logger -t $SCRIPT_ID[$$] "Monitoring Docker restarts and eth0 IP changes..."

while true; do
    if [ ! -S /var/run/docker.sock ]; then
        inotifywait -e create /var/run 2>/dev/null
        while [ ! -S /var/run/docker.sock ]; do sleep 1; done
        apply_iptables_rule
    fi
    sleep 5
done
