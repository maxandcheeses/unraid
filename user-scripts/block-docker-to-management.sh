#!/bin/bash

LOCK_FILE="/var/run/docker-watch-eth0.lock"

# Function to check and remove stale lock files (older than 8 seconds)
cleanup_stale_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
        if [[ $LOCK_AGE -gt 5 ]]; then
            logger -t userscript2[$$] "$(date): Stale lock file detected (age: $LOCK_AGE seconds). Removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
}

# Ensure only one instance runs at a time
cleanup_stale_lock
if [[ -f "$LOCK_FILE" ]]; then
    logger -t userscript2[$$] "$(date): Another instance is already running. Exiting."
    exit 1
fi

# Trap to remove lock file on exit
trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT

# Start a background subprocess to touch the lock file every 5 seconds
( while true; do
    sleep 3
    touch "$LOCK_FILE"
done ) &

# Function to get the eth0 IP from iptables rules
get_current_eth0_ip() {
    iptables -L INPUT -v -n | grep "block docker subnets to management ip" | awk '{print $9}' | head -n 1
}

# Function to remove duplicate iptables rules **by line number**
remove_duplicate_rules() {
    logger -t userscript2[$$] "Checking for duplicate iptables rules..."

    iptables -L INPUT --line-numbers | grep "block docker subnets to management ip" | awk '{print $1}' | sort -rn | while read -r line_num; do
        logger -t userscript2[$$] "Removing duplicate rule at line $line_num"
        iptables -D INPUT "$line_num"
    done
}

# Function to remove an existing iptables rule for a specific subnet **by line number**
remove_iptables_rule() {
    local subnet="$1"

    logger -t userscript2[$$] "Checking for existing rules for subnet $subnet..."

    iptables -L INPUT --line-numbers | grep "block docker subnets to management ip" | grep "$subnet" | awk '{print $1}' | sort -rn | while read -r line_num; do
        logger -t userscript2[$$] "$(date): Removing old iptables rule at line $line_num for subnet $subnet."
        iptables -D INPUT "$line_num"
    done
}

# Function to determine and apply the iptables rule **only if Docker is running**
apply_iptables_rule() {
    # Ensure Docker is running before updating iptables
    if [ ! -S /var/run/docker.sock ]; then
        logger -t userscript2[$$] "$(date): Docker is not running. Skipping iptables update."
        return
    fi

    # Define the default blocked subnet
    DEFAULT_SUBNET="172.17.0.0/16"

    # Get the blocked subnet from Docker bridge network or use the default
    BLOCKED_SUBNET=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)

    # Set to default subnet if Docker command fails or returns an empty value
    if [[ -z "$BLOCKED_SUBNET" ]]; then
        BLOCKED_SUBNET="$DEFAULT_SUBNET"
    fi

    logger -t userscript2[$$] "Blocked Subnet (from Docker or default): $BLOCKED_SUBNET"

    # Extract eth0 IP from existing iptables rule (if available)
    IPTABLES_ETH0_IP=$(get_current_eth0_ip)

    # Keep trying to get eth0 IP until it succeeds
    while true; do
        ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        
        if [[ -n "$ETH0_IP" ]]; then
            break  # Exit loop once a valid IP is found
        fi

        logger -t userscript2[$$] "Error: Unable to determine eth0 IP address. Retrying in 2 seconds..."
        sleep 2
    done

    logger -t userscript2[$$] "eth0 IP: $ETH0_IP"

    # If eth0 IP has changed, update rules
    if [[ "$ETH0_IP" != "$IPTABLES_ETH0_IP" ]]; then
        logger -t userscript2[$$] "eth0 IP has changed! Updating iptables rules..."

        # Remove duplicate rules
        remove_duplicate_rules
        remove_iptables_rule "$BLOCKED_SUBNET"

        # Apply new rule with comment
        logger -t userscript2[$$] "$(date): Applying iptables rule to block Docker subnets from management IP..."
        iptables -I INPUT -s "$BLOCKED_SUBNET" -d "$ETH0_IP" -j DROP -m comment --comment "block docker subnets to management ip"
        logger -t userscript2[$$] "$(date): Applied iptables rule for subnet $BLOCKED_SUBNET to management IP ($ETH0_IP)."
    else
        logger -t userscript2[$$] "eth0 IP has not changed, no updates required."
    fi
}

# Run the rule immediately **only if Docker is running**
apply_iptables_rule

logger -t userscript2[$$] "Monitoring Docker restarts and eth0 IP changes..."

# Infinite loop to monitor Docker service and eth0 IP address
while true; do
    # Wait for Docker to stop
    if [ ! -S /var/run/docker.sock ]; then
        logger -t userscript2[$$] "$(date): Docker stopped. Waiting for restart..."
        
        # Use `inotifywait` to wait for Docker to restart
        inotifywait -e create /var/run 2>/dev/null

        # Ensure Docker is back up before proceeding
        while [ ! -S /var/run/docker.sock ]; do
            sleep 1
        done
        
        logger -t userscript2[$$] "$(date): Docker restarted. Re-applying iptables rule..."
        apply_iptables_rule
    fi

    # Check eth0 IP every 5 seconds **only if Docker is running**
    if [ -S /var/run/docker.sock ]; then
        NEW_ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        IPTABLES_ETH0_IP=$(get_current_eth0_ip)

        if [[ "$NEW_ETH0_IP" != "$IPTABLES_ETH0_IP" ]]; then
            logger -t userscript2[$$] "$(date): eth0 IP changed from $IPTABLES_ETH0_IP to $NEW_ETH0_IP. Updating rules..."
            apply_iptables_rule
        fi
    fi

    sleep 5
done
