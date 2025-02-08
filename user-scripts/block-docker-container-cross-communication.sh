#!/bin/bash

LOCK_FILE="/var/run/docker-watch-cross-com.lock"
IPTABLES_LOCK="/var/lock/iptables.lock"

# Function to check and remove stale lock files (older than 5 seconds)
cleanup_stale_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
        if [[ $LOCK_AGE -gt 5 ]]; then
            logger -t userscript1[$$] "$(date): Stale lock file detected (age: $LOCK_AGE seconds). Removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
}

# Ensure only one instance runs at a time
cleanup_stale_lock
if [[ -f "$LOCK_FILE" ]]; then
    logger -t userscript1[$$] "$(date): Another instance is already running. Exiting."
    exit 1
fi

# Trap to remove lock file and release iptables lock on exit
trap 'rm -f "$LOCK_FILE"; exec 200>&-; exit' INT TERM EXIT

# Start a background process to keep the lock file updated every 3 seconds
( while true; do
    sleep 3
    touch "$LOCK_FILE"
done ) &

# Default subnet in case Docker bridge inspection fails
DEFAULT_SUBNET="172.17.0.0/16"

# Function to determine the current blocked subnet
get_blocked_subnet() {
    BLOCKED_SUBNET=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)

    # Set to default subnet if Docker command fails or returns empty
    if [[ -z "$BLOCKED_SUBNET" ]]; then
        BLOCKED_SUBNET="$DEFAULT_SUBNET"
    fi

    echo "$BLOCKED_SUBNET"
}

# Function to acquire iptables lock safely
acquire_iptables_lock() {
    exec 200>"$IPTABLES_LOCK"
    logger -t userscript1[$$] "$(date): Waiting for iptables lock..."
    flock -x 200 || { logger -t userscript1[$$] "$(date): Failed to acquire iptables lock"; exit 1; }
    logger -t userscript1[$$] "$(date): Acquired iptables lock."
    trap 'release_iptables_lock' EXIT  # Ensures lock is always released
}

# Function to release iptables lock
release_iptables_lock() {
    exec 200>&-  # Close the lock file descriptor
    logger -t userscript1[$$] "$(date): Released iptables lock."
}

# Function to remove duplicate iptables rules **by line number**
remove_duplicate_rules() {
    acquire_iptables_lock
    logger -t userscript1[$$] "Checking for duplicate iptables rules..."
    iptables -L FORWARD --line-numbers | grep "block docker container cross communication" | awk '{print $1}' | sort -rn | while read -r line_num; do
        logger -t userscript1[$$] "Removing duplicate rule at line $line_num"
        iptables -D FORWARD "$line_num"
    done
    release_iptables_lock
}

# Function to safely modify iptables with lock
apply_iptables_rule() {
    # Ensure Docker is running before updating iptables
    if [ ! -S /var/run/docker.sock ]; then
        logger -t userscript1[$$] "$(date): Docker is not running. Skipping iptables update."
        return
    fi

    BLOCKED_SUBNET=$(get_blocked_subnet)

    acquire_iptables_lock
    remove_duplicate_rules

    # Apply new rule with comment
    logger -t userscript1[$$] "$(date): Applying iptables rule to block cross-container communication..."
    iptables -I FORWARD -s "$BLOCKED_SUBNET" -d "$BLOCKED_SUBNET" -j DROP -m comment --comment "block docker container cross communication"
    
    release_iptables_lock
    logger -t userscript1[$$] "$(date): Applied iptables rule for subnet $BLOCKED_SUBNET."
}

# Run the rule immediately **only if Docker is running**
apply_iptables_rule

logger -t userscript1[$$] "Monitoring Docker restarts..."

# Infinite loop to monitor Docker service
while true; do
    # Wait for Docker to stop
    inotifywait -e delete_self /var/run/dockerd.pid >/dev/null 2>&1

    logger -t userscript1[$$] "$(date): Docker stopped. Waiting for restart..."

    # Wait for Docker to start back up
    while [ ! -S /var/run/docker.sock ]; do
        sleep 2
        cleanup_stale_lock  # Check if lock file needs to be removed
    done

    logger -t userscript1[$$] "$(date): Docker restarted. Re-applying iptables rule..."
    
    apply_iptables_rule
done
