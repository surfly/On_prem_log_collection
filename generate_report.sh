<<<<<<< HEAD
#!/bin/bash
set -Eeuo pipefail

umask 077

CONFIG_FILE="$HOME/surfly/config.env"
CERT_FILE="$HOME/surfly/certs/cobrowse.surflysupport.com"
REPORT_FILE="$PWD/surfly_diagnostic_full.html"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

html_escape() {
    sed \
        -e 's/\&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&#39;/g"
}

echo "Collecting system information..."

TARGET_USER=$(whoami)
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo "unknown")
EXPECTED_XDG="/run/user/$TARGET_UID"

OS_NAME=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "unknown")
PODMAN_VER=$(podman --version 2>/dev/null | awk '{print $3}' || echo "not installed")
SYSTEMD_VER=$(systemctl --version 2>/dev/null | head -n1 | awk '{print $2}' || echo "unknown")
REDIS_VER=$(redis-server --version 2>/dev/null | awk '{print $3}' | cut -d'=' -f2 || echo "not installed")
UMASK_VALUE=$(umask)
UMASK_SYMBOLIC=$(umask -S 2>/dev/null || echo "unknown")
XDG_RUNTIME_DIR_VALUE="${XDG_RUNTIME_DIR:-not set}"

# User validation
if id "$TARGET_USER" >/dev/null 2>&1; then
    if [[ "$TARGET_UID" != "unknown" && "$TARGET_UID" -ge 1000 ]]; then
        USER_STATUS="valid non-privileged user (uid=$TARGET_UID)"
        USER_COLOR="green"
    else
        USER_STATUS="not recommended (uid=$TARGET_UID)"
        USER_COLOR="red"
    fi
else
    USER_STATUS="user not found"
    USER_COLOR="red"
fi

# Linger validation
LINGER_STATUS=$(loginctl show-user "$TARGET_USER" 2>/dev/null | awk -F= '/^Linger=/ {print $2}' || echo "unknown")
if [[ "$LINGER_STATUS" == "yes" ]]; then
    LINGER_COLOR="green"
else
    LINGER_COLOR="red"
fi

# XDG validation
if [[ "$XDG_RUNTIME_DIR_VALUE" == "$EXPECTED_XDG" ]]; then
    XDG_COLOR="green"
    XDG_STATUS="verified"
elif [[ "$XDG_RUNTIME_DIR_VALUE" == "not set" ]]; then
    XDG_COLOR="red"
    XDG_STATUS="not set"
else
    XDG_COLOR="orange"
    XDG_STATUS="set but different from expected"
fi

# SELinux validation
SELINUX_RAW=$(/usr/sbin/sestatus 2>/dev/null | awk -F: '/SELinux status/ {print $2}' | xargs || true)
if [[ "${SELINUX_RAW:-unknown}" == "disabled" ]]; then
    SELINUX_STAT="disabled"
    SELINUX_COLOR="green"
else
    SELINUX_STAT=$(/usr/sbin/sestatus 2>/dev/null | awk -F: '/Current mode/ {print $2}' | xargs || echo "unknown")
    if [[ "$SELINUX_STAT" == "permissive" || "$SELINUX_STAT" == "disabled" ]]; then
        SELINUX_COLOR="green"
    else
        SELINUX_COLOR="red"
    fi
fi

# System limits
LIMIT_NOFILE_SOFT=$(ulimit -Sn 2>/dev/null || echo "unknown")
LIMIT_NOFILE_HARD=$(ulimit -Hn 2>/dev/null || echo "unknown")
LIMIT_NPROC_SOFT=$(ulimit -Su 2>/dev/null || echo "unknown")
LIMIT_NPROC_HARD=$(ulimit -Hu 2>/dev/null || echo "unknown")

if [[ "$LIMIT_NOFILE_SOFT" != "unknown" && "$LIMIT_NOFILE_SOFT" -ge 65535 ]]; then
    LIMIT_COLOR="green"
else
    LIMIT_COLOR="red"
fi

# Unprivileged ports
UNPRIV_PORT_START=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "unknown")
if [[ "$UNPRIV_PORT_START" == "0" ]]; then
    UNPRIV_PORT_COLOR="green"
    UNPRIV_PORT_STATUS="enabled"
else
    UNPRIV_PORT_COLOR="red"
    UNPRIV_PORT_STATUS="not enabled"
fi

# Config file
if [[ -f "$CONFIG_FILE" ]]; then
    ENV_DATA=$(
        grep -v '^#' "$CONFIG_FILE" 2>/dev/null | grep '=' | \
        sed -E '
            s/^([[:space:]]*(SECRET_KEY|CLIENT_SECRET|DASHBOARD_AUTH_TOKEN|COBRO_AUTH_TOKEN|COOKIEJAR_SECRET|PG_EXTERNAL_USER_PASS)[[:space:]]*=).*/\1********/I;
            s/^([[:space:]]*.*(PASS|PASSWORD|PASSWD|TOKEN|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|AUTH|CREDENTIALS)[[:space:]]*=).*/\1********/I;
            s/^([[:space:]]*(SMTP_USER|SMTP_USERNAME|SMTP_PASSWORD|MAIL_USER|MAIL_USERNAME|MAIL_PASSWORD|MAILGUN_API_KEY|SENDGRID_API_KEY|POSTMARK_API_TOKEN)[[:space:]]*=).*/\1********/I
        ' || true
    )
else
    ENV_DATA="config.env not found at $CONFIG_FILE"
fi

LICENSE_JSON=$(curl -s localhost:8017/info/ 2>/dev/null | jq '.' 2>/dev/null || echo '{"error": "API unreachable or jq missing"}')

# Detect service scope: prefer user units, fallback to system units
SERVICE_SCOPE="none"
SERVICES=""

USER_SERVICES=$(
    systemctl --user list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep '^ss-.*\.service$' \
    | sort -u || true
)

SYSTEM_SERVICES=$(
    systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep '^ss-.*\.service$' \
    | sort -u || true
)

if [[ -n "${USER_SERVICES:-}" ]]; then
    SERVICE_SCOPE="user"
    SERVICES="$USER_SERVICES"
elif [[ -n "${SYSTEM_SERVICES:-}" ]]; then
    SERVICE_SCOPE="system"
    SERVICES="$SYSTEM_SERVICES"
fi

if [[ "$SERVICE_SCOPE" == "user" ]]; then
    ALL_UNITS=$(systemctl --user list-dependencies ss-surfly.target --no-pager 2>/dev/null || echo "ss-surfly.target not found in user scope")
elif [[ "$SERVICE_SCOPE" == "system" ]]; then
    ALL_UNITS=$(systemctl list-dependencies ss-surfly.target --no-pager 2>/dev/null || echo "ss-surfly.target not found in system scope")
else
    ALL_UNITS="No ss-* services found in user or system scope"
fi

# sslcheck
SSLCHECK_BIN=$(command -v sslcheck || true)
SSLCHECK_STATUS=""
SSLCHECK_OUTPUT=""
SSLCHECK_VERBOSE_OUTPUT=""

if [[ -n "$SSLCHECK_BIN" ]]; then
    if [[ -f "$CERT_FILE" ]]; then
        SSLCHECK_STATUS="sslcheck found: $SSLCHECK_BIN"
        SSLCHECK_OUTPUT=$("$SSLCHECK_BIN" verify -c "$CERT_FILE" 2>&1 || true)
        SSLCHECK_VERBOSE_OUTPUT=$("$SSLCHECK_BIN" verify -c "$CERT_FILE" -v 2>&1 || true)
    else
        SSLCHECK_STATUS="sslcheck found, but certificate file not found: $CERT_FILE"
        SSLCHECK_OUTPUT="Certificate file not found: $CERT_FILE"
        SSLCHECK_VERBOSE_OUTPUT="Certificate file not found: $CERT_FILE"
    fi
else
    SSLCHECK_STATUS="sslcheck command not found in PATH"
    SSLCHECK_OUTPUT="sslcheck command not found in PATH"
    SSLCHECK_VERBOSE_OUTPUT="sslcheck command not found in PATH"
fi

cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Surfly Full Diagnostic Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, sans-serif;
            margin: 0;
            background: #f0f2f5;
            color: #1c1e21;
        }
        .container {
            max-width: 1600px;
            margin: 20px auto;
            background: white;
            padding: 24px;
            border-radius: 12px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.1);
        }
        .stat-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-bottom: 24px;
        }
        .box {
            padding: 20px;
            border: 1px solid #ddd;
            border-radius: 8px;
            background: #fafafa;
            margin-bottom: 20px;
        }
        pre {
            background: #1c1e21;
            color: #76ff03;
            padding: 15px;
            border-radius: 6px;
            overflow-x: auto;
            white-space: pre-wrap;
            word-wrap: break-word;
            font-family: monospace;
            font-size: 12px;
            max-height: 75vh;
        }
        .small-pre {
            background: #f4f4f4;
            color: #333;
            border: 1px solid #ccc;
            max-height: 300px;
        }
        .layout {
            display: grid;
            grid-template-columns: 280px 1fr;
            gap: 20px;
            margin-top: 20px;
        }
        .sidebar {
            border: 1px solid #ddd;
            border-radius: 8px;
            background: #fafafa;
            padding: 12px;
            height: fit-content;
            position: sticky;
            top: 20px;
        }
        .sidebar input {
            width: 100%;
            box-sizing: border-box;
            margin-bottom: 10px;
            padding: 10px;
            border: 1px solid #ccc;
            border-radius: 6px;
        }
        .service-btn {
            display: block;
            width: 100%;
            text-align: left;
            padding: 10px 12px;
            margin: 6px 0;
            border: 0;
            border-radius: 6px;
            cursor: pointer;
            background: #e4e6eb;
            font-weight: 600;
        }
        .service-btn:hover {
            background: #d8dbe1;
        }
        .service-btn.active {
            background: #0064ff;
            color: white;
        }
        .log-panel {
            display: none;
        }
        .log-panel.active {
            display: block;
        }
        .hint {
            font-size: 12px;
            color: #666;
        }
    </style>
    <script>
        function showService(id, btn) {
            document.querySelectorAll('.log-panel').forEach(function(p) {
                p.classList.remove('active');
            });
            document.querySelectorAll('.service-btn').forEach(function(b) {
                b.classList.remove('active');
            });
            var panel = document.getElementById(id);
            if (panel) panel.classList.add('active');
            if (btn) btn.classList.add('active');
        }

        function filterServices() {
            var q = document.getElementById('serviceSearch').value.toLowerCase();
            document.querySelectorAll('.service-btn').forEach(function(btn) {
                var txt = btn.getAttribute('data-service').toLowerCase();
                btn.style.display = txt.indexOf(q) !== -1 ? 'block' : 'none';
            });
        }

        window.onload = function() {
            var firstBtn = document.querySelector('.service-btn');
            if (firstBtn) firstBtn.click();
        };
    </script>
</head>
<body>
<div class="container">
    <h1>🚀 Surfly Node Diagnostic Report</h1>
    <p><strong>Generated:</strong> $(date)</p>
    <p><strong>Report path:</strong> $(realpath "$REPORT_FILE")</p>

    <div class="stat-grid">
        <div class="box">
            <h2>🖥️ System Specs</h2>
            <p><strong>OS:</strong> $(printf '%s' "$OS_NAME" | html_escape)</p>
            <p><strong>Podman:</strong> $(printf '%s' "$PODMAN_VER" | html_escape) (Req: 5.4.0+)</p>
            <p><strong>Systemd:</strong> $(printf '%s' "$SYSTEMD_VER" | html_escape) (Req: 252+)</p>
            <p><strong>Redis:</strong> $(printf '%s' "$REDIS_VER" | html_escape)</p>

            <p><strong>User ($TARGET_USER):</strong>
            <span style="color: $USER_COLOR; font-weight: bold;">$(printf '%s' "$USER_STATUS" | html_escape)</span></p>

            <p><strong>SELinux:</strong>
            <span style="color: $SELINUX_COLOR; font-weight: bold;">$(printf '%s' "$SELINUX_STAT" | html_escape)</span></p>

            <p><strong>Loginctl Linger ($TARGET_USER):</strong>
            <span style="color: $LINGER_COLOR; font-weight: bold;">$(printf '%s' "$LINGER_STATUS" | html_escape)</span></p>
            <p class="hint">Linger allows user services to keep running after logout.</p>

            <p><strong>XDG_RUNTIME_DIR:</strong>
            <span style="color: $XDG_COLOR; font-weight: bold;">$(printf '%s' "$XDG_RUNTIME_DIR_VALUE" | html_escape)</span></p>
            <p class="hint">Expected: $(printf '%s' "$EXPECTED_XDG" | html_escape) | Status: $(printf '%s' "$XDG_STATUS" | html_escape)</p>

            <p><strong>Unprivileged ports:</strong>
            <span style="color: $UNPRIV_PORT_COLOR; font-weight: bold;">$(printf '%s' "$UNPRIV_PORT_STATUS" | html_escape)</span></p>
            <p class="hint">net.ipv4.ip_unprivileged_port_start=$(printf '%s' "$UNPRIV_PORT_START" | html_escape)</p>

            <p><strong>Open files limit:</strong>
            <span style="color: $LIMIT_COLOR; font-weight: bold;">soft=$(printf '%s' "$LIMIT_NOFILE_SOFT" | html_escape), hard=$(printf '%s' "$LIMIT_NOFILE_HARD" | html_escape)</span></p>
            <p class="hint">Processes: soft=$(printf '%s' "$LIMIT_NPROC_SOFT" | html_escape), hard=$(printf '%s' "$LIMIT_NPROC_HARD" | html_escape)</p>

            <p><strong>Umask:</strong> $(printf '%s' "$UMASK_VALUE" | html_escape) ($(printf '%s' "$UMASK_SYMBOLIC" | html_escape))</p>
        </div>

        <div class="box">
            <h2>📜 License & Metadata</h2>
            <pre class="small-pre">$(printf '%s' "$LICENSE_JSON" | html_escape)</pre>
        </div>
    </div>

    <div class="box">
        <h2>🔑 Configuration (config.env)</h2>
        <pre class="small-pre">$(printf '%s' "$ENV_DATA" | html_escape)</pre>
    </div>

    <div class="box">
        <h2>🔐 SSL Certificate Check</h2>
        <p><strong>Certificate path:</strong> $(printf '%s' "$CERT_FILE" | html_escape)</p>
        <p><strong>Status:</strong> $(printf '%s' "$SSLCHECK_STATUS" | html_escape)</p>

        <h3>sslcheck verify</h3>
        <pre class="small-pre">$(printf '%s' "$SSLCHECK_OUTPUT" | html_escape)</pre>

        <h3>sslcheck verify -v</h3>
        <pre>$(printf '%s' "$SSLCHECK_VERBOSE_OUTPUT" | html_escape)</pre>
    </div>

    <div class="box">
        <h2>🏗️ Service Dependencies</h2>
        <p><strong>Detected service scope:</strong> $(printf '%s' "$SERVICE_SCOPE" | html_escape)</p>
        <pre>$(printf '%s' "$ALL_UNITS" | html_escape)</pre>
    </div>

    <h2>📋 Service Logs</h2>
    <div class="layout">
        <div class="sidebar">
            <input type="text" id="serviceSearch" onkeyup="filterServices()" placeholder="Filter services...">
EOF

if [[ -z "${SERVICES:-}" ]]; then
cat >> "$REPORT_FILE" <<EOF
            <div class="box">
                No ss-* services found.
            </div>
EOF
else
    for SERVICE in $SERVICES; do
        SAFE_ID=$(echo "$SERVICE" | tr '.@-' '___')
        cat >> "$REPORT_FILE" <<EOF
            <button class="service-btn" data-service="$SERVICE" onclick="showService('panel_$SAFE_ID', this)">$SERVICE</button>
EOF
    done
fi

cat >> "$REPORT_FILE" <<EOF
        </div>
        <div>
EOF

if [[ -n "${SERVICES:-}" ]]; then
    for SERVICE in $SERVICES; do
        SAFE_ID=$(echo "$SERVICE" | tr '.@-' '___')
        LOG_FILE="$TMP_DIR/$SAFE_ID.log"

        if [[ "$SERVICE_SCOPE" == "user" ]]; then
            journalctl --user-unit "$SERVICE" --no-pager -o short-iso 2>&1 | html_escape > "$LOG_FILE"
        else
            journalctl -u "$SERVICE" --no-pager -o short-iso 2>&1 | html_escape > "$LOG_FILE"
        fi

        cat >> "$REPORT_FILE" <<EOF
            <div class="log-panel" id="panel_$SAFE_ID">
                <div class="box">
                    <h3>$SERVICE</h3>
                    <p>Full journalctl output for this service</p>
                    <pre>
EOF
        cat "$LOG_FILE" >> "$REPORT_FILE"
        cat >> "$REPORT_FILE" <<EOF
                    </pre>
                </div>
            </div>
EOF
    done
fi

cat >> "$REPORT_FILE" <<EOF
        </div>
    </div>
</div>
</body>
</html>
EOF

chmod 600 "$REPORT_FILE"

echo "------------------------------------------------"
echo "Local report generated: $(realpath "$REPORT_FILE")"
ls -l "$REPORT_FILE"

read -r -p "Would you like to export this report to a shareable link? (y/n): " confirm
if [[ $confirm == [yY] ]]; then
    if command -v nc >/dev/null 2>&1; then
        URL=$(cat "$REPORT_FILE" | nc termbin.com 9999 || true)
        if [[ -n "${URL:-}" ]]; then
            echo "Successfully exported! Link: $URL"
        else
            echo "Export failed."
        fi
    else
        echo "nc command not found. Cannot export."
    fi
fi
=======

>>>>>>> origin/main
