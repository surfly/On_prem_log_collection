#!/bin/bash

# Configuration and Paths from Surfly Manual [cite: 1316, 1317]
CONFIG_FILE="$HOME/surfly/config.env"
REPORT_FILE="surfly_diagnostic_full.html"

# 1. System Data Extraction [cite: 1307, 2011]
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
PODMAN_VER=$(podman --version | awk '{print $3}')
SYSTEMD_VER=$(systemctl --version | head -n1 | awk '{print $2}')

# Robust SELinux Extraction 
# Logic updated to handle "disabled" status found on your RHEL/CentOS node
SELINUX_RAW=$(/usr/sbin/sestatus | awk -F: '/SELinux status/ {print $2}' | xargs)
if [[ "$SELINUX_RAW" == "disabled" ]]; then
    SELINUX_STAT="disabled"
    SELINUX_COLOR="green"
else
    SELINUX_STAT=$(/usr/sbin/sestatus | awk -F: '/Current mode/ {print $2}' | xargs)
    [[ "$SELINUX_STAT" == "permissive" ]] && SELINUX_COLOR="green" || SELINUX_COLOR="red"
fi

# 2. Config Extraction & Security Masking [cite: 1324]
# Masking sensitive tokens as requested to protect your environment 
if [ -f "$CONFIG_FILE" ]; then
    ENV_DATA=$(grep -v '^#' "$CONFIG_FILE" | grep '=' | \
    sed 's/SECRET_KEY=.*/SECRET_KEY=********/' | \
    sed 's/CLIENT_SECRET=.*/CLIENT_SECRET=********/' | \
    sed 's/DASHBOARD_AUTH_TOKEN=.*/DASHBOARD_AUTH_TOKEN=********/' | \
    sed 's/COBRO_AUTH_TOKEN=.*/COBRO_AUTH_TOKEN=********/' | \
    sed 's/COOKIEJAR_SECRET=.*/COOKIEJAR_SECRET=********/')
else
    ENV_DATA="config.env not found at $CONFIG_FILE"
fi

# Pulling full Info JSON from local API 
LICENSE_JSON=$(curl -s localhost:8017/info/ | jq '.' || echo '{"error": "API unreachable"}')

# 3. Service Discovery [cite: 795, 1449]
SERVICES=$(systemctl --user list-units "ss-*" --no-legend | awk '{print $1}' | grep ".service")
ALL_UNITS=$(systemctl --user list-dependencies ss-surfly.target --no-pager)

# Generate HTML
cat <<EOF > $REPORT_FILE
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Surfly Full Diagnostic Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, sans-serif; margin: 20px; background: #f0f2f5; color: #1c1e21; }
        .container { max-width: 1400px; margin: auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.1); }
        .stat-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 30px; }
        .box { padding: 20px; border: 1px solid #ddd; border-radius: 8px; background: #fafafa; }
        pre { background: #1c1e21; color: #76ff03; padding: 15px; border-radius: 6px; overflow-x: auto; font-family: monospace; font-size: 12px; }
        .tabs { display: flex; flex-wrap: wrap; margin-top: 20px; }
        .tabs label { order: 1; display: block; padding: 10px 15px; margin: 0 4px 4px 0; cursor: pointer; background: #e4e6eb; border-radius: 6px; font-weight: bold; }
        .tabs .tab-content { order: 99; flex-grow: 1; width: 100%; display: none; padding: 20px; border: 1px solid #ddd; }
        .tabs input[type="radio"] { display: none; }
        .tabs input[type="radio"]:checked + label { background: #0064ff; color: white; }
        .tabs input[type="radio"]:checked + label + .tab-content { display: block; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Surfly Node Diagnostic Report</h1>
        <p><strong>Generated:</strong> $(date)</p>

        <div class="stat-grid">
            <div class="box">
                <h2>🖥️ System Specs</h2>
                <p><strong>OS:</strong> $OS_NAME</p>
                <p><strong>Podman:</strong> $PODMAN_VER (Req: 5.4.0+)</p>
                <p><strong>Systemd:</strong> $SYSTEMD_VER (Req: 252+)</p>
                <p><strong>SELinux:</strong> <span style="color: $SELINUX_COLOR; font-weight: bold;">$SELINUX_STAT</span></p>
            </div>
            <div class="box">
                <h2>📜 License & Metadata</h2>
                <pre style="background:#f4f4f4; color:#333; border:1px solid #ccc; max-height: 250px;">$LICENSE_JSON</pre>
            </div>
        </div>

        <div class="box" style="margin-bottom:20px;">
            <h2>🔑 Configuration (config.env)</h2>
            <pre style="background:#f4f4f4; color:#333; border:1px solid #ccc;">$ENV_DATA</pre>
        </div>

        <h2>🏗️ Service Dependencies</h2>
        <pre>$ALL_UNITS</pre>

        <h2>📋 Service Logs (journalctl -n 2000)</h2>
        <div class="tabs">
EOF

# Loop for 2000-line logs per service 
FIRST=true
for SERVICE in $SERVICES; do
    CHECKED=""
    if [ "$FIRST" = true ]; then CHECKED="checked"; FIRST=false; fi
    SAFE_ID=$(echo $SERVICE | tr '.' '_')
    LOG_DATA=$(journalctl --user-unit "$SERVICE" -n 2000 --no-pager | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    
    cat <<EOF >> $REPORT_FILE
        <input type="radio" name="tabs" id="tab_$SAFE_ID" $CHECKED>
        <label for="tab_$SAFE_ID">${SERVICE#ss-}</label>
        <div class="tab-content">
            <h3>Recent 2000 lines for $SERVICE</h3>
            <pre>$LOG_DATA</pre>
        </div>
EOF
done

echo "</div></div></body></html>" >> $REPORT_FILE
echo "------------------------------------------------"
echo "Local report generated: $REPORT_FILE"

# Export Option
read -p "Would you like to export this report to a shareable link? (y/n): " confirm
if [[ $confirm == [yY] ]]; then
    URL=$(cat "$REPORT_FILE" | nc termbin.com 9999)
    echo "Successfully exported! Link: $URL"
fi
