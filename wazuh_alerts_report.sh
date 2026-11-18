#!/usr/bin/env bash

echo "[$$] Starting Wazuh Alerts Report..."
ascii_art="
          _______  _______                      _______  _        _______  _______ _________ _______    _______  _______  _______  _______  _______ _________
|\     /|(  ___  )/ ___   )|\     /||\     /|  (  ___  )( \      (  ____ \(  ____ )\__   __/(  ____ \  (  ____ )(  ____ \(  ____ )(  ___  )(  ____ )\__   __/
| )   ( || (   ) |\/   )  || )   ( || )   ( |  | (   ) || (      | (    \/| (    )|   ) (   | (    \/  | (    )|| (    \/| (    )|| (   ) || (    )|   ) (   
| | _ | || (___) |    /   )| |   | || (___) |  | (___) || |      | (__    | (____)|   | |   | (_____   | (____)|| (__    | (____)|| |   | || (____)|   | |   
| |( )| ||  ___  |   /   / | |   | ||  ___  |  |  ___  || |      |  __)   |     __)   | |   (_____  )  |     __)|  __)   |  _____)| |   | ||     __)   | |   
| || || || (   ) |  /   /  | |   | || (   ) |  | (   ) || |      | (      | (\ (      | |         ) |  | (\ (   | (      | (      | |   | || (\ (      | |   
| () () || )   ( | /   (_/\| (___) || )   ( |  | )   ( || (____/\| (____/\| ) \ \__   | |   /\____) |  | ) \ \__| (____/\| )      | (___) || ) \ \__   | |   
(_______)|/     \|(_______/(_______)|/     \|  |/     \|(_______/(_______/|/   \__/   )_(   \_______)  |/   \__/(_______/|/       (_______)|/   \__/   )_(   
"
VERSION="1.1"
echo -e "$ascii_art"

# Prevent multiple instances
exec 200>/tmp/wazuh_report.lock
flock -n 200 || { echo "[$$] Another instance is running. Exiting."; exit 1; }

echo "[$$] Deleting existing tmp files..."
rm -f /tmp/alerts_combined.json

# Cleanup
cleanup() {
    echo "[$$] Cleaning up temporary files..."
    rm -f /tmp/alerts_combined.json
}

trap cleanup EXIT

echo "[$$] Current working directory: $(pwd)"

# Load config file
CONFIG_FILE="/opt/wazuh-report/report.conf"
echo "[$$] Checking for config file at: $CONFIG_FILE"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "[$$] Config file found and sourced successfully."
    source "$CONFIG_FILE"
else
    echo "[$$] Error: Config file not found at $CONFIG_FILE" >> /var/ossec/logs/alerts/jq_errors.log
fi

echo "[$$] Memory usage after loading config:"
free -h

# Output directory
OUTPUT_DIR="/var/ossec/logs/reports"
mkdir -p "$OUTPUT_DIR"

# Output file
REPORT_FILE="$OUTPUT_DIR/daily_wazuh_report.html"

# Set time period
START_TIME=$(date --date="24 hours ago" +%Y-%m-%dT%H:%M:%S)

# Determine yesterday's log filename (exactly one year and one month ago yesterday!)
YESTERDAY=$(date --date="yesterday" +%d)
PREV_LOG_DIR="/var/ossec/logs/alerts/$(date --date='yesterday' +%Y/%b)"
PREV_LOG="$PREV_LOG_DIR/ossec-alerts-$YESTERDAY.json"
PREV_LOG_GZ="$PREV_LOG.gz"
CUR_LOG="/var/ossec/logs/alerts/alerts.json"

echo "[$$] Debug: Searching for logs in $PREV_LOG_DIR and $CUR_LOG"

: > /tmp/alerts_combined.json
echo "[$$] Extracting and merging logs using jq streaming..."

# 1) Yesterday's alerts from the past 24 hours (if the file exists)
if [[ -f "$PREV_LOG_GZ" ]]; then
    echo "[$$] Extracting previous day's alerts from $PREV_LOG_GZ"
    gunzip -c "$PREV_LOG_GZ" | jq -c --arg start "$START_TIME" 'select(. != null and .timestamp >= $start)' 2>> /tmp/jq_errors.log >> /tmp/alerts_combined.json
elif [[ -f "$PREV_LOG" ]]; then
    echo "[$$] Using uncompressed previous day's alerts from $PREV_LOG"
    jq -c --arg start "$START_TIME" 'select(. != null and .timestamp >= $start)' "$PREV_LOG" 2>> /tmp/jq_errors.log >> /tmp/alerts_combined.json
fi

# 2) Today's alerts (add always if alerts.json exists)
if [[ -f "$CUR_LOG" ]]; then
    echo "[$$] Extracting current day's alerts from $CUR_LOG"
    jq -c --arg start "$START_TIME" 'select(. != null and .timestamp >= $start)' "$CUR_LOG" 2>> /tmp/jq_errors.log >> /tmp/alerts_combined.json
fi

# Wait a moment to ensure file is created
sleep 1

# Debug check
if [[ ! -s /tmp/alerts_combined.json ]]; then
    echo "[$$] Error: Merged log file is empty! Check /tmp/jq_errors.log" >> /var/ossec/logs/alerts/jq_errors.log
else
    echo "[$$] Success: Merged log file contains data."
fi

# Debug: Check JSON file structure
jq empty /tmp/alerts_combined.json 2>> /tmp/jq_errors.log
if [[ $? -ne 0 ]]; then
    echo "[$$] Error: JSON parsing failed! Check /tmp/jq_errors.log" >> /var/ossec/logs/alerts/jq_errors.log
fi

# Debug: Print first few lines of the merged JSON file
echo "[$$] Debug: First 10 lines of merged JSON file:"
head -n 10 /tmp/alerts_combined.json

echo "[$$] Processing system updates check..."
UBUNTU_UPDATES=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)

echo "[$$] Fetching latest Wazuh version..."
LATEST_WAZUH_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/wazuh/wazuh/releases/latest | jq -c -r '.tag_name' | sed 's/^v//')

if [[ -z "$LATEST_WAZUH_VERSION" || "$LATEST_WAZUH_VERSION" == "null" ]]; then
    echo "[$$] Warning: Could not fetch the latest Wazuh version."
fi

echo "[$$] Checking disk usage..."
#df -h | grep "/dev/mapper/ubuntu--vg-ubuntu--lv"
df -h | grep "/dev/root"
echo "[$$] Checking alerts directory usage..."
du -sh /var/ossec/logs/alerts

# Count total number of alerts for progress bar
TOTAL_ALERTS=$(wc -l < /tmp/alerts_combined.json)
echo "[$$] Total alerts to process: $TOTAL_ALERTS"

# Extract non-critical alerts
echo "[$$] Extracting non-critical alerts..."
NON_CRITICAL_ALERTS=$(jq -r 'select(type == "object" and .rule.level < 12 and .timestamp >= "'$START_TIME'") | "\(.rule.level)\t\(.rule.id)\t\(.rule.description)"' /tmp/alerts_combined.json | sort | uniq -c | sort -nr | head -n 10)

# Debug: Print non-critical alerts
echo "[$$] Debug: Non-Critical Alerts:"
echo "$NON_CRITICAL_ALERTS"

# Extract critical alerts
echo "[$$] Extracting critical alerts..."
CRITICAL_ALERTS=$(jq -r 'select(type == "object" and .rule.level >= 12 and .timestamp >= "'$START_TIME'") | "\(.rule.level)\t\(.rule.id)\t\(.rule.description)"' /tmp/alerts_combined.json | sort | uniq -c | sort -nr | head -n 10)

# Debug: Print critical alerts
echo "[$$] Debug: Critical Alerts:"
echo "$CRITICAL_ALERTS"

# Extract Top Alerting Agents
echo "[$$] Extracting top alerting agents..."
TOP_AGENTS=$(jq -r '"\(.agent.id // "-")\t\(.agent.name // "-")"' /tmp/alerts_combined.json | sort | uniq -c | sort -nr | head -n 10)

echo "[$$] Debug: Top Alerting Agents:"
echo "$TOP_AGENTS"

# HTML report header
echo "<html><body style='font-family: Arial, sans-serif;'>" > "$REPORT_FILE"
echo "<h2 style='color:blue;'>🔹 Daily Wazuh Report - $(date) </h2>" >> "$REPORT_FILE"
echo "<p>Hello Team,</p><p>Here's your daily Wazuh alert summary:</p>" >> "$REPORT_FILE"

# System Updates Check
echo "<h3>🔄 System Updates Status</h3>" >> "$REPORT_FILE"
if [[ "$UBUNTU_UPDATES" -gt 0 ]]; then
    echo "<p>🔴 <b>Ubuntu:</b> $UBUNTU_UPDATES updates available.</p>" >> "$REPORT_FILE"
else
    echo "<p>✅ <b>Ubuntu:</b> System is up to date.</p>" >> "$REPORT_FILE"
fi

# Wazuh Version Check
INSTALLED_WAZUH_VERSION=$(dpkg-query -W -f='${Version}\n' wazuh-manager 2>/dev/null | cut -d '-' -f1)
if [[ -z "$LATEST_WAZUH_VERSION" || "$LATEST_WAZUH_VERSION" == "null" ]]; then
    echo "<p>⚠️ <b>Wazuh:</b> Could not fetch the latest version info. Please check network connectivity.</p>" >> "$REPORT_FILE"
elif [[ "$INSTALLED_WAZUH_VERSION" == "$LATEST_WAZUH_VERSION" ]]; then
    echo "<p>✅ <b>Wazuh:</b> Version $INSTALLED_WAZUH_VERSION is up to date.</p>" >> "$REPORT_FILE"
else
    echo "<p>🔴 <b>Wazuh:</b> Update available! Installed: $INSTALLED_WAZUH_VERSION → Latest: $LATEST_WAZUH_VERSION</p>" >> "$REPORT_FILE"
fi

# Disk Usage Overview
echo "<h3>💾 Disk Usage</h3>" >> "$REPORT_FILE"
echo "<table border='1' cellspacing='0' cellpadding='5'>" >> "$REPORT_FILE"
echo "<tr><th>Filesystem</th><th>Size</th><th>Used</th><th>Avail</th><th>Use%</th></tr>" >> "$REPORT_FILE"
#df -h | grep "/dev/mapper/ubuntu--vg-ubuntu--lv" | awk '{print "<tr><td>"$1"</td><td>"$2"</td><td>"$3"</td><td>"$4"</td><td>"$5"</td></tr>"}' >> "$REPORT_FILE"
df -h | grep "/dev/root" | awk '{print "<tr><td>"$1"</td><td>"$2"</td><td>"$3"</td><td>"$4"</td><td>"$5"</td></tr>"}' >> "$REPORT_FILE"
echo "</table>" >> "$REPORT_FILE"

# Alerts Directory Breakdown
echo "<h3>📂 Alerts Directory Usage</h3>" >> "$REPORT_FILE"
TOTAL_ALERTS_SIZE=$(du -sb /var/ossec/logs/alerts | awk '{print $1}')
ALERT_ITEMS=()
while read -r size path; do
    [[ "$path" =~ jq$|jq_errors.log$ ]] && continue
    ALERT_ITEMS+=("$size $path")
done < <(du -sb /var/ossec/logs/alerts/* 2>/dev/null | sort -nr)
for file in /var/ossec/logs/alerts/alerts.json /var/ossec/logs/alerts/alerts.log; do
    if [[ -f "$file" ]]; then
        FILE_SIZE=$(stat -c %s "$file")
        ALERT_ITEMS+=("$FILE_SIZE $file")
    fi
done
echo "<p>Total size: <b>$(numfmt --to=iec-i --suffix=B $TOTAL_ALERTS_SIZE)</b></p>" >> "$REPORT_FILE"
echo "<table border='1' cellspacing='0' cellpadding='5'>" >> "$REPORT_FILE"
echo "<tr><th>Path</th><th>Size</th><th>Usage %</th></tr>" >> "$REPORT_FILE"
calculate_percentage() {
    local size=$1
    local total=$2
    awk "BEGIN {printf \"%.2f%%\", ($size / $total) * 100}"
}
for entry in "${ALERT_ITEMS[@]}"; do
    ITEM_SIZE=$(echo "$entry" | awk '{print $1}')
    ITEM_PATH=$(echo "$entry" | awk '{$1=""; print $0}' | sed 's/^ *//')
    ITEM_PERCENT=$(calculate_percentage "$ITEM_SIZE" "$TOTAL_ALERTS_SIZE")
    echo "<tr><td>$ITEM_PATH</td><td>$(numfmt --to=iec-i --suffix=B $ITEM_SIZE)</td><td>$ITEM_PERCENT</td></tr>" >> "$REPORT_FILE"
done
echo "</table>" >> "$REPORT_FILE"

# Swap Usage
echo "<h3>🔄 Swap Usage</h3>" >> "$REPORT_FILE"
echo "<table border='1' cellspacing='0' cellpadding='5'><tr><th>Total</th><th>Used</th><th>Free</th></tr>" >> "$REPORT_FILE"
free -h | grep "Swap" | awk '{print "<tr><td>"$2"</td><td>"$3"</td><td>"$4"</td></tr>"}' >> "$REPORT_FILE"
echo "</table>" >> "$REPORT_FILE"

# Non-Critical Alerts
echo "DEBUG: Non-Critical Alerts: $NON_CRITICAL_ALERTS"
if [[ -z "$NON_CRITICAL_ALERTS" ]]; then
    echo "<p style='color: gray;'>No non-critical alerts found.</p>" >> "$REPORT_FILE"
else
    echo "<h3>⚠️ Top Non-Critical Alerts (Level < 12) from the last 24 hours</h3>" >> "$REPORT_FILE"
    echo "<table border='1' cellspacing='0' cellpadding='5'><tr><th>Count</th><th>Level</th><th>Rule ID</th><th>Description</th></tr>" >> "$REPORT_FILE"
    echo "$NON_CRITICAL_ALERTS" | awk '{print "<tr><td>"$1"</td><td>"$2"</td><td>"$3"</td><td>"substr($0, index($0,$4))"</td></tr>"}' >> "$REPORT_FILE"
    echo "</table>" >> "$REPORT_FILE"
fi

# Critical Alerts
echo "DEBUG: Critical Alerts: $CRITICAL_ALERTS"
if [[ -z "$CRITICAL_ALERTS" ]]; then
    echo "<p style='color: gray;'>No critical alerts found.</p>" >> "$REPORT_FILE"
else
    echo "<h3>🚨 Top Critical Alerts (Level ≥ 12) from the last 24 hours</h3>" >> "$REPORT_FILE"
    echo "<table border='1' cellspacing='0' cellpadding='5'><tr><th>Count</th><th>Level</th><th>Rule ID</th><th>Description</th></tr>" >> "$REPORT_FILE"
    echo "$CRITICAL_ALERTS" | awk '{print "<tr><td>"$1"</td><td>"$2"</td><td>"$3"</td><td>"substr($0, index($0,$4))"</td></tr>"}' >> "$REPORT_FILE"
    echo "</table>" >> "$REPORT_FILE"
fi

# Top Alerting Agents
if [[ -z "$TOP_AGENTS" ]]; then
    echo "<p style='color: gray;'>No agents reported any alerts in the last 24 hours.</p>" >> "$REPORT_FILE"
else
    echo "<h3>🤖 Top Agents (by number of alerts)</h3>" >> "$REPORT_FILE"
    echo "<table border='1' cellspacing='0' cellpadding='5'><tr><th>Count</th><th>Agent ID</th><th>Agent Name</th></tr>" >> "$REPORT_FILE"
    echo "$TOP_AGENTS" | awk -F'\t' '{split($1, a, " "); print "<tr><td>"a[1]"</td><td>"a[2]"</td><td>"$2"</td></tr>"}' >> "$REPORT_FILE"
    echo "</table>" >> "$REPORT_FILE"
fi

# ==========================================
# Wazuh Services & ossec.log Health (24h)
# ==========================================
echo "[$$] Analyzing services and ossec.log (last 24h)..."

echo "<h3>🩺 Wazuh Services &amp; System Load</h3>" >> "$REPORT_FILE"
LOAD_AVG=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
echo "<p><b>Load Average (1m, 5m, 15m):</b> $LOAD_AVG</p>" >> "$REPORT_FILE"
echo "<table border='1' cellspacing='0' cellpadding='5'><tr><th>Service</th><th>Status</th></tr>" >> "$REPORT_FILE"
for svc in wazuh-manager wazuh-indexer wazuh-dashboard; do
    SVC_STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    if [[ "$SVC_STATUS" == "active" ]]; then
        BADGE="✅ active"
    else
        BADGE="🔴 $SVC_STATUS"
    fi
    echo "<tr><td>$svc</td><td>$BADGE</td></tr>" >> "$REPORT_FILE"
done
echo "</table>" >> "$REPORT_FILE"

OSSEC_CUTOFF=$(date --date="24 hours ago" "+%Y/%m/%d %H:%M:%S")
OSSEC_YEST_DIR="/var/ossec/logs/ossec/$(date --date='yesterday' +%Y/%b)"
OSSEC_YEST_DAY=$(date --date='yesterday' +%d)
OSSEC_YEST_GZ="$OSSEC_YEST_DIR/ossec-$OSSEC_YEST_DAY.log.gz"
OSSEC_YEST_LOG="$OSSEC_YEST_DIR/ossec-$OSSEC_YEST_DAY.log"
CLIENT_KEYS="/var/ossec/etc/client.keys"
OSSEC_TMP_DIR=$(mktemp -d /tmp/ossec_health.XXXXXX)

{
    [[ -f "$OSSEC_YEST_GZ" ]] && gunzip -c "$OSSEC_YEST_GZ" 2>/dev/null
    [[ -f "$OSSEC_YEST_LOG" ]] && cat "$OSSEC_YEST_LOG" 2>/dev/null
    [[ -f "/var/ossec/logs/ossec.log" ]] && cat /var/ossec/logs/ossec.log
} | awk -v cutoff="$OSSEC_CUTOFF" -v q="'" -v keys_file="$CLIENT_KEYS" -v outdir="$OSSEC_TMP_DIR" '
function esc(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    return s
}
BEGIN {
    while ((getline line < keys_file) > 0) {
        if (line ~ /^[0-9]+ /) {
            split(line, f, " ")
            agent_name[f[1]] = f[2]
        }
    }
    close(keys_file)
}
substr($0, 1, 19) < cutoff { next }
{
    if ($0 ~ /: CRITICAL: /) { crit++ }
    else if ($0 ~ /: ERROR: /) { err++ }
    else if ($0 ~ /: WARNING: /) { warn++ }
    else { next }

    if ($0 ~ /circuit_breaking_exception|Too many requests/) { cbe++ }

    if ($0 ~ /Agent key already in use: agent ID/) {
        if (match($0, "agent ID " q "[^" q "]+" q)) {
            id = substr($0, RSTART + 10, RLENGTH - 11)
            dup_key[id]++
        }
        next
    }
    if ($0 ~ /Wrong key or corrupt payload/) {
        if (match($0, "from agent " q "[^" q "]+" q)) {
            id = substr($0, RSTART + 12, RLENGTH - 13)
            bad_key[id]++
        }
        next
    }
    if ($0 ~ /\(1408\): Invalid ID /) {
        line = $0
        sub(/.*Invalid ID /, "", line)
        split(line, a, " ")
        id = a[1]
        ip = "unknown"
        if (match(line, "source ip: " q "[^" q "]+" q)) {
            ip = substr(line, RSTART + 12, RLENGTH - 13)
        }
        inv_id[ip "\t" id]++
        next
    }
    if ($0 ~ /Invalid password provided by /) {
        ip = $0
        sub(/.*Invalid password provided by /, "", ip)
        sub(/\. Closing connection.*/, "", ip)
        bad_pass[ip]++
        next
    }
    if ($0 ~ /document\(s\) rejected by index/) {
        msg = $0
        sub(/^[0-9\/]+ [0-9:]+ /, "", msg)
        sub(/ in document with id .*/, "", msg)
        other[msg]++
        next
    }

    msg = $0
    sub(/^[0-9\/]+ [0-9:]+ /, "", msg)
    gsub(q "[^" q "]*" q, q "..." q, msg)
    gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "<IP>", msg)
    other[msg]++
}
END {
    printf "CRIT=%d\nERR=%d\nWARN=%d\nCBE=%d\n", crit+0, err+0, warn+0, cbe+0 > (outdir "/summary.env")
    for (k in dup_key) {
        name = (k in agent_name) ? agent_name[k] : "(deleted/unknown)"
        printf "%d\t%s\t%s\n", dup_key[k], k, esc(name) > (outdir "/dup_key.tsv")
    }
    for (k in bad_key) {
        name = (k in agent_name) ? agent_name[k] : "(deleted/unknown)"
        printf "%d\t%s\t%s\n", bad_key[k], k, esc(name) > (outdir "/bad_key.tsv")
    }
    for (k in inv_id)   printf "%d\t%s\n", inv_id[k], k         > (outdir "/inv_id.tsv")
    for (k in bad_pass) printf "%d\t%s\n", bad_pass[k], esc(k)  > (outdir "/bad_pass.tsv")
    for (k in other)    printf "%d\t%s\n", other[k], esc(k)     > (outdir "/other.tsv")
}
'

source "$OSSEC_TMP_DIR/summary.env" 2>/dev/null || { CRIT=0; ERR=0; WARN=0; CBE=0; }

echo "<h3>📋 Wazuh Manager Log Health (<code>ossec.log</code>, last 24h)</h3>" >> "$REPORT_FILE"
if [[ "$CBE" -gt 0 ]]; then
    echo "<p>🔴 <b>Indexer Circuit Breaker / 429 errors:</b> $CBE (check JVM Heap in <code>/etc/wazuh-indexer/jvm.options</code>!)</p>" >> "$REPORT_FILE"
fi
echo "<p><b>CRITICAL:</b> ${CRIT:-0} | <b>ERROR:</b> ${ERR:-0} | <b>WARNING:</b> ${WARN:-0}</p>" >> "$REPORT_FILE"

HINT_INV_ID=$(cat <<'EOF'
grep "Invalid ID" /var/ossec/logs/ossec.log | sed -E "s/.*Invalid ID ([0-9]+) for the source ip: '([^']+)'.*/\2 \1/" | sort | uniq -c | sort -nr
EOF
)

HINT_BAD_PASS=$(cat <<'EOF'
grep "Invalid password provided by" /var/ossec/logs/ossec.log | sed -E "s/.*provided by ([^ ]+)\. Closing.*/\1/" | sort | uniq -c | sort -nr
EOF
)

render_ossec_table() {
    local title="$1"
    local file="$2"
    local cols_html="$3"
    local limit="${4:-15}"
    local hint_cmd="${5:-}"
    if [[ -s "$file" ]]; then
        local total_rows
        total_rows=$(wc -l < "$file")
        echo "<h4>$title (total: $total_rows)</h4>" >> "$REPORT_FILE"
        echo "<table border='1' cellspacing='0' cellpadding='5'><tr>$cols_html</tr>" >> "$REPORT_FILE"
        if [[ "$limit" -eq 0 ]]; then
            sort -nr "$file"
        else
            sort -nr "$file" | head -n "$limit"
        fi | awk -F'\t' '{
            printf "<tr>"
            for (i = 1; i <= NF; i++) printf "<td>%s</td>", $i
            print "</tr>"
        }' >> "$REPORT_FILE"
        echo "</table>" >> "$REPORT_FILE"
        if [[ -n "$hint_cmd" ]]; then
            echo "<p style='margin:6px 0 2px;font-size:12px;color:#555;'>Run on server for full output:</p>" >> "$REPORT_FILE"
            echo "<pre style='background:#f4f4f4;padding:8px;border:1px solid #ddd;border-radius:4px;font-size:12px;white-space:pre-wrap;margin-top:2px;'><code>$hint_cmd</code></pre>" >> "$REPORT_FILE"
        fi
    fi
}

render_ossec_table "🔁 Duplicate Agent Keys (Agent key already in use)" "$OSSEC_TMP_DIR/dup_key.tsv" "<th>Count</th><th>Agent ID</th><th>Agent Name</th>" 0
render_ossec_table "🔑 Corrupt / Wrong Agent Keys (1404)" "$OSSEC_TMP_DIR/bad_key.tsv" "<th>Count</th><th>Agent ID</th><th>Agent Name</th>" 0
render_ossec_table "🚫 Invalid Agent IDs (1408, Top 25)" "$OSSEC_TMP_DIR/inv_id.tsv" "<th>Count</th><th>Source IP</th><th>Agent ID</th>" 25 "$HINT_INV_ID"
render_ossec_table "🔐 Authd Invalid Password (All)" "$OSSEC_TMP_DIR/bad_pass.tsv" "<th>Count</th><th>Source IP</th>" 0 "$HINT_BAD_PASS"
render_ossec_table "🧩 Other Errors &amp; Warnings (Indexer / Config / Rules, Top 20)" "$OSSEC_TMP_DIR/other.tsv" "<th>Count</th><th>Message Pattern</th>" 20

rm -rf "$OSSEC_TMP_DIR"

# Close HTML
echo "</body></html>" >> "$REPORT_FILE"

echo "[$$] Sending email report..."
(
echo "Subject: $MAIL_SUBJECT"
echo "MIME-Version: 1.0"
echo "Content-Type: text/html; charset=UTF-8"
cat "$REPORT_FILE"
) | sendmail -f "$MAIL_FROM" "$MAIL_TO"

swapoff -a; swapon -a
echo "[$$] Script execution completed successfully!"