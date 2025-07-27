#!/bin/bash
# ============================================================
# Multi-Server Tautulli Checker & Plex Session Killer
# ------------------------------------------------------------
# 1) Loops every WAIT_TIME seconds
# 2) For each Tautulli server, queries get_activity, groups by (username, session_id),
#    writes lines to /tmp/user.log: "username session_id session_key server_api server_url"
# 3) We parse /tmp/user.log line by line, properly counting sessions per user
# 4) If user_counts[user] > MAX_STREAMS => kill them from the lines in user.log
#
# Dependencies: jq
# ============================================================

WAIT_TIME=60
MAX_STREAMS=2
USER_LOG="/tmp/user.log"
# Create a temp file for each server to avoid appending issues
SERVER_TEMP_LOG="/tmp/server_temp.log"

# Add an array of exempt users who won't be limited
EXEMPT_USERS=(
  "User1"
  "User2"
  # Add more exempt users as needed
)

TAUTULLI_API_KEYS=(
  "ebdb8c80fc2b461ea182243dbc1b27a1" #server 1
  "d9e64926654741609b7db9294bca5e36" #server 2
  "bbc8ad8796104f668ff1aba2fb69e1d7" #server 3
  "" #server 4
)

TAUTULLI_URLS=(
  "http://10.0.0.10:8181/api/v2" #server 1
  "http://10.0.0.10:8182/api/v2" #server 2
  "http://10.0.0.10:8183/api/v2" #server 3
  "" #server 4
)

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if a user is exempt
is_exempt_user() {
    local check_user="$1"
    for exempt_user in "${EXEMPT_USERS[@]}"; do
        if [ "$check_user" = "$exempt_user" ]; then
            return 0
        fi
    done
    return 1 # False, user is not exempt
}

gather_server_sessions() {
    local apikey="$1"
    local url="$2"
    local server_name="$3"

    log_message "[${server_name}] Querying Tautulli at ${url}"
    local resp
    resp=$(curl -s "${url}?apikey=${apikey}&cmd=get_activity")

    if ! echo "$resp" | jq -e '.response.data.sessions' >/dev/null 2>&1; then
        log_message "[${server_name}] WARNING: Invalid or empty JSON. Skipping."
        return
    fi

    local sessions_array
    sessions_array=$(echo "$resp" | jq '.response.data.sessions')

    local count
    count=$(echo "$sessions_array" | jq 'length')
    log_message "[${server_name}] Found ${count} raw session object(s)."

    if [ "$count" -gt 0 ]; then
        log_message "[${server_name}] Processing sessions:"

        # Use a separate file for this server's sessions
        > "$SERVER_TEMP_LOG"
        
        echo "$sessions_array" | jq -r --arg ak "$apikey" --arg surl "$url" \
            '.[] | select(.username != null and .username != "") |
            "\(.username)|\(.session_id)|\(.session_key)|\($ak)|\($surl)"' > "$SERVER_TEMP_LOG"
        
        while IFS='|' read -r username session_id session_key server_api server_url; do
            log_message "   User: $username, Session ID: $session_id"
            echo "$username|$session_id|$session_key|$server_api|$server_url" >> "$USER_LOG"
        done < "$SERVER_TEMP_LOG"
    fi
}

kill_user_sessions() {
    local user="$1"
    log_message "Terminating ALL sessions for user: $user"

    while IFS='|' read -r username session_id session_key apikey url; do
        if [ "$username" = "$user" ]; then
            log_message "  Terminating session ID: $session_id on server: $url"
            local enc_user
            enc_user=$(echo "$username" | sed 's/ /%20/g')
            local msg="Too%20Many%20Streaming%20Sessions%20For%20USER%20${enc_user}%20between%20all%20PLEX%20servers!%20Only%20${MAX_STREAMS}%20are%20allowed%20at%20a%20time!"
            local resp
            resp=$(curl -s "${url}?apikey=${apikey}&cmd=terminate_session&session_id=${session_id}&session_key=${session_key}&message=${msg}")
            log_message "  Terminate response: ${resp}"
        fi
    done < "$USER_LOG"
}

# Main loop
while true; do
    log_message "Starting multi-server Tautulli check..."

    # CRITICAL: Reset the user log file at the start of each cycle
    > "$USER_LOG" # More efficient than rm + touch

    # Reset the user_counts array completely for each new check
    unset user_counts
    declare -A user_counts

    # 1) Gather lines from all servers
    for i in 0 1 2 3; do
        api_key="${TAUTULLI_API_KEYS[$i]}"
        url="${TAUTULLI_URLS[$i]}"
        server_name="Server $((i+1))"

        if [ -z "$api_key" ] || [ -z "$url" ]; then
            continue
        fi

        gather_server_sessions "$api_key" "$url" "$server_name"
    done

    # 2) Count sessions per user - ONLY from the current scan
    if [ -s "$USER_LOG" ]; then
        log_message "Processing user sessions from log file..."

        # Create a temporary file to deduplicate sessions by user+session_id
        > "/tmp/unique_sessions.log"

        # Use awk to deduplicate by username and session_id
        awk -F'|' '!seen[$1,$2]++' "$USER_LOG" > "/tmp/unique_sessions.log"

        # Clear user log and copy back deduplicated entries
        > "$USER_LOG"
        cat "/tmp/unique_sessions.log" > "$USER_LOG"

        while IFS='|' read -r username session_id _rest; do
            if [ -n "$username" ]; then
                user_counts["$username"]=$(( ${user_counts["$username"]:-0} + 1 ))
            fi
        done < "$USER_LOG"

        # 3) Display user counts
        log_message "User session counts:"
        for user in "${!user_counts[@]}"; do
            # Check if user is exempt
            if is_exempt_user "$user"; then
                log_message "   $user: ${user_counts[$user]} session(s) [EXEMPT]"
            else
                log_message "   $user: ${user_counts[$user]} session(s)"
            fi
        done

        # 4) Check for users exceeding limits and terminate their sessions
        for user in "${!user_counts[@]}"; do
            # Skip exempt users
            if is_exempt_user "$user"; then
                log_message "USER $user is exempt from the stream limit (${user_counts[$user]} active streams)"
                continue
            fi

            if [ "${user_counts[$user]}" -gt "$MAX_STREAMS" ]; then
                log_message "USER $user has exceeded the stream limit! (${user_counts[$user]}/${MAX_STREAMS})"
                kill_user_sessions "$user"
            fi
        done
    else
        log_message "No active sessions found."
    fi

    # Clean up temporary files
    rm -f "/tmp/unique_sessions.log" "$SERVER_TEMP_LOG"
    log_message "Check complete. Waiting ${WAIT_TIME} seconds for next run..."
    echo ""
    sleep "$WAIT_TIME"
done
