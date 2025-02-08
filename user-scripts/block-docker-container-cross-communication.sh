#!/bin/bash

LOCK_FILE="/var/run/docker-watch-cross-com.lock"
IPTABLES_LOCK="/var/lock/iptables.lock"
IPTABLES_COMMENT="block docker container cross communication"  # Easily change this comment
SCRIPT_ID=userscript1

# Function to check and remove stale lock files (older than 5 seconds)
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

# Start a background process to keep the lock file updated every 3 seconds
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

# Function to determine the current blocked subnet
get_blocked_subnet() {
    BLOCKED_SUBNET=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)
    BLOCKED_SUBNET=${BLOCKED_SUBNET:-"172.17.0.0/16"}
    echo "$BLOCKED_SUBNET"
}

# Function to remove duplicate iptables rules **by exact match**
remove_duplicate_rules() {
    acquire_iptables_lock
    logger -t $SCRIPT_ID[$$] "Checking for duplicate iptables rules in FORWARD..."

    iptables-save | grep -- "-A FORWARD .* -m comment --comment \"$IPTABLES_COMMENT\"" | while read -r rule; do
        SRC_IP=$(echo "$rule" | grep -oP '(?<=-s )[^ ]+')
        DST_IP=$(echo "$rule" | grep -oP '(?<=-d )[^ ]+')

        if [[ -n "$SRC_IP" && -n "$DST_IP" ]]; then
            logger -t $SCRIPT_ID[$$] "Removing duplicate rule: $rule"
            iptables -D FORWARD -s "$SRC_IP" -d "$DST_IP" -m comment --comment "$IPTABLES_COMMENT" -j DROP
        else
            logger -t $SCRIPT_ID[$$] "Skipping malformed rule: $rule"
        fi
    done

    release_iptables_lock
}

# Function to safely modify iptables with lock
apply_iptables_rule() {
    # Ensure Docker is running before updating iptables
    if [ ! -S /var/run/docker.sock ]; then
        logger -t $SCRIPT_ID[$$] "$(date): Docker is not running. Skipping iptables update."
        return
    fi

    BLOCKED_SUBNET=$(get_blocked_subnet)

    # Remove duplicate rules before adding a new one
    remove_duplicate_rules

    acquire_iptables_lock

    # Check if the rule already exists
    if iptables-save | grep -q -- "-A FORWARD -s $BLOCKED_SUBNET -d $BLOCKED_SUBNET -m comment --comment \"$IPTABLES_COMMENT\""; then
        logger -t $SCRIPT_ID[$$] "$(date): Rule already exists. Skipping addition."
    else
        # Apply new rule with comment
        logger -t $SCRIPT_ID[$$] "$(date): Applying iptables rule to block cross-container communication..."
        iptables -I FORWARD -s "$BLOCKED_SUBNET" -d "$BLOCKED_SUBNET" -j DROP -m comment --comment "$IPTABLES_COMMENT"
        logger -t $SCRIPT_ID[$$] "$(date): Applied iptables rule for subnet $BLOCKED_SUBNET."
    fi

    release_iptables_lock
}

# Run the rule immediately **only if Docker is running**
apply_iptables_rule

logger -t $SCRIPT_ID[$$] "Monitoring Docker restarts..."

# Infinite loop to monitor Docker service
while true; do
    # Wait for Docker to stop
    inotifywait -e delete_self /var/run/dockerd.pid >/dev/null 2>&1

    logger -t $SCRIPT_ID[$$] "$(date): Docker stopped. Waiting for restart..."

    # Wait for Docker to start back up
    while [ ! -S /var/run/docker.sock ]; do
        sleep 2
        cleanup_stale_locks  # Check if lock file needs to be removed
    done

    logger -t $SCRIPT_ID[$$] "$(date): Docker restarted. Re-applying iptables rule..."
    sleep 2
    
    apply_iptables_rule
done
