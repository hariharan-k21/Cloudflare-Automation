#!/bin/bash

# ========================================================
# Cloudflare DNS Manager
# Author: Hariharan K
# Date  : 31-07-2025
# Description: Manage Cloudflare DNS records using API
# ========================================================

# Load environment variables
source .env

# Set default API URL if not already set
CF_API_URL="${CF_API_URL:-https://api.cloudflare.com/client/v4}"

# -------------------------
# Function: Display Header
# -------------------------
print_header() {
    echo -e "\n============================================"
    echo " Cloudflare DNS Manager Utility"
    echo " Author: Hariharan K"
    echo " Date  : 31-07-2025"
    echo "============================================"
}

# -------------------------
# Function: Check domain
# -------------------------
check_domain() {
    echo "Enter the domain name you want to check:"
    read domain_name

    echo "Fetching the Zone ID for domain: $domain_name..."
    zone_response=$(curl -s -X GET "${CF_API_URL}/zones?name=${domain_name}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    zone_id=$(echo "$zone_response" | jq -r '.result[0].id')

    if [[ "$zone_id" == "null" || -z "$zone_id" ]]; then
        echo "Error: Domain not found in Cloudflare."
        return 1
    else
        CF_ZONE_ID="$zone_id"
        echo "Domain $domain_name is found. Zone ID is: $CF_ZONE_ID"
        return 0
    fi
}

# -------------------------
# Function: Rename CNAME
# -------------------------
rename_cname() {
    echo "Fetching CNAME records..."
    response=$(curl -s -X GET "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records?type=CNAME" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    cname_count=$(echo "$response" | jq '.result | length')
    if [[ "$cname_count" -eq 0 ]]; then
        echo "No CNAME records found for this domain."
        return 1
    fi

    echo "Available CNAME records:"
    echo "$response" | jq -r '.result[] | "ID: \(.id)\n  Name: \(.name)\n  Content: \(.content)\n"'

    echo "Enter the ID of the CNAME record you want to modify:"
    read cname_id

    selected=$(echo "$response" | jq -r --arg id "$cname_id" '.result[] | select(.id == $id)')
    if [[ -z "$selected" ]]; then
        echo "Invalid CNAME ID selected."
        return 1
    fi

    old_name=$(echo "$selected" | jq -r '.name')
    old_content=$(echo "$selected" | jq -r '.content')
    proxied=$(echo "$selected" | jq -r '.proxied')

    echo "Current Name: $old_name"
    echo "Current Content: $old_content"

    echo "Enter the new name (leave empty to keep current):"
    read new_name
    echo "Enter the new content (leave empty to keep current):"
    read new_content

    new_name=${new_name:-$old_name}
    new_content=${new_content:-$old_content}

    echo "Updating CNAME record..."
    update_response=$(curl -s -X PUT "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records/${cname_id}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"CNAME\",
            \"name\": \"$new_name\",
            \"content\": \"$new_content\",
            \"ttl\": 3600,
            \"proxied\": $proxied
        }")

    if [[ "$(echo "$update_response" | jq -r .success)" == "true" ]]; then
        echo "CNAME record updated successfully."
    else
        echo "Error: Failed to update CNAME record."
        echo "$update_response"
    fi
}

# -------------------------
# Function: Disable origin port
# -------------------------
disable_origin_port() {
    echo "Disabling origin ports (setting proxied = false)..."
    dns_records=$(curl -s -X GET "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    for record in $(echo "$dns_records" | jq -c '.result[]'); do
        id=$(echo "$record" | jq -r '.id')
        type=$(echo "$record" | jq -r '.type')
        name=$(echo "$record" | jq -r '.name')
        content=$(echo "$record" | jq -r '.content')
        ttl=$(echo "$record" | jq -r '.ttl')

        echo "Disabling proxy for record ID $id..."
        curl -s -X PUT "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records/${id}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"$type\",
                \"name\": \"$name\",
                \"content\": \"$content\",
                \"ttl\": $ttl,
                \"proxied\": false
            }" > /dev/null
    done

    echo "All origin ports disabled (proxied = false)."
}

# -------------------------
# Function: Delete all DNS records
# -------------------------
delete_dns_records() {
    echo "Deleting all DNS records..."
    records=$(curl -s -X GET "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    for record_id in $(echo "$records" | jq -r '.result[].id'); do
        echo "Deleting record ID: $record_id"
        curl -s -X DELETE "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" > /dev/null
    done

    echo "All DNS records deleted."
}

# -------------------------
# Function: Remove domain
# -------------------------
remove_domain() {
    echo "Are you sure you want to remove this domain from Cloudflare? (yes/no)"
    read confirm
    if [[ "$confirm" == "yes" ]]; then
        delete_zone_response=$(curl -s -X DELETE "${CF_API_URL}/zones/${CF_ZONE_ID}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json")
        if [[ "$(echo "$delete_zone_response" | jq -r .success)" == "true" ]]; then
            echo "Domain removed from Cloudflare successfully."
        else
            echo "Error: Failed to remove domain from Cloudflare."
        fi
    else
        echo "Domain removal cancelled."
    fi
}

# -------------------------
# Function: Modify or disable A/AAAA records (interactive)
# -------------------------
modify_and_disable_origin() {
    echo "Fetching A/AAAA DNS records..."
    records=$(curl -s -X GET "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    filtered=$(echo "$records" | jq -c '[.result[] | select(.type == "A" or .type == "AAAA")]')
    total_records=$(echo "$filtered" | jq 'length')

    if [[ "$total_records" -eq 0 ]]; then
        echo "No A or AAAA records found."
        return 1
    fi

    echo -e "\nAvailable Records:"
    for i in $(seq 0 $((total_records - 1))); do
        record=$(echo "$filtered" | jq -c ".[$i]")
        echo "$((i + 1))) $(echo "$record" | jq -r '.type') | ID: $(echo "$record" | jq -r '.id') | Name: $(echo "$record" | jq -r '.name') | Content: $(echo "$record" | jq -r '.content') | Proxied: $(echo "$record" | jq -r '.proxied')"
    done

    echo -e "\nEnter the record number to modify:"
    read index

    if ! [[ "$index" =~ ^[0-9]+$ ]] || (( index < 1 || index > total_records )); then
        echo "Invalid selection."
        return 1
    fi

    selected=$(echo "$filtered" | jq -c ".[$((index - 1))]")
    id=$(echo "$selected" | jq -r '.id')
    name=$(echo "$selected" | jq -r '.name')
    content=$(echo "$selected" | jq -r '.content')
    type=$(echo "$selected" | jq -r '.type')
    ttl=$(echo "$selected" | jq -r '.ttl')

    echo -e "\nSelected Record: $name ($type)\nContent: $content\n"

    echo "1) Disable proxy (proxied = false)"
    echo "2) Cancel"
    read -p "Choose action: " action

    case $action in
        1)
            curl -s -X PUT "${CF_API_URL}/zones/${CF_ZONE_ID}/dns_records/${id}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "{
                    \"type\": \"$type\",
                    \"name\": \"$name\",
                    \"content\": \"$content\",
                    \"ttl\": $ttl,
                    \"proxied\": false
                }" > /dev/null
            echo "Proxy disabled."
            ;;
        *)
            echo "Cancelled."
            ;;
    esac
}

# -------------------------
# Main Menu
# -------------------------
main_menu() {
    while true; do
        print_header
        echo -e "\nMain Menu:"
        echo "1) Check if domain is mapped"
        echo "2) Rename a CNAME record"
        echo "3) Disable all origin ports (proxied = false)"
        echo "4) Modify/Disable a specific A/AAAA record"
        echo "5) Delete all DNS records"
        echo "6) Remove domain from Cloudflare"
        echo "7) Exit"
        echo "============================================"
        read -p "Choose an option: " option

        case $option in
            1) check_domain ;;
            2) rename_cname ;;
            3) disable_origin_port ;;
            4) modify_and_disable_origin ;;
            5) delete_dns_records ;;
            6) remove_domain ;;
            7) echo "Goodbye!"; break ;;
            *) echo "Invalid option. Try again." ;;
        esac
    done
}

# Start the program
main_menu
