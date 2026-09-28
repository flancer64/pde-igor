#!/usr/bin/env bash

# Provisions the canonical Linux environment for the pde-igor Embassy host.
# Run as root before the first application release is deployed.

set -euo pipefail

readonly APP_USER='pde-igor'
readonly APP_GROUP='pde-igor'
readonly APP_HOME="/home/${APP_USER}"
readonly APP_ROOT="${APP_HOME}/app/pde"
readonly PRIVATE_ROOT="${APP_HOME}/private"
readonly DATA_ROOT="${APP_HOME}/data"
readonly LOG_ROOT="${APP_HOME}/log"
readonly TMP_ROOT="${APP_HOME}/tmp"
readonly ENV_FILE="${PRIVATE_ROOT}/pde/app.env"
readonly SERVICE_NAME='pde-igor'
readonly DB_NAME='pde_igor'
readonly DB_USER='pde_igor'
readonly DB_HOST='127.0.0.1'
readonly DB_PORT='5432'
readonly NVM_VERSION='v0.40.6'
readonly APACHE_SITES_AVAILABLE='/etc/apache2/sites-available'
readonly APACHE_CONF_AVAILABLE='/etc/apache2/conf-available'

base_url=''
port=''
domain=''

usage() {
    cat <<'EOF'
Usage:
  sudo BASE_URL=https://pde.example.org PORT=3000 ./scripts/create-user.sh

Required environment variables:
  BASE_URL  Public HTTPS URL of the Embassy Runtime.
  PORT      Local HTTP port for the Embassy Runtime (1024-65535).
  CERTBOT_EMAIL  Optional email address for Let's Encrypt notices.

The script creates the pde-igor Unix account, PostgreSQL role/database,
private configuration, persistent directories, NVM, systemd service, narrowly
scoped deployment sudoers rule, logrotate configuration, Apache virtual hosts,
and a Let's Encrypt TLS certificate. It does not deploy an application release
or configure Telegram API credentials.
EOF
}

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: ${command_name}" >&2
        exit 1
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo 'Run this script as root.' >&2
        exit 1
    fi
}

create_user() {
    if ! id "$APP_USER" >/dev/null 2>&1; then
        adduser --disabled-password --gecos '' "$APP_USER"
    fi

    chmod 0700 "$APP_HOME"
    install -d -m 0700 -o "$APP_USER" -g "$APP_GROUP" \
        "$APP_ROOT/releases" \
        "${PRIVATE_ROOT}/pde" \
        "${PRIVATE_ROOT}/telegram" \
        "${DATA_ROOT}/pde" \
        "${DATA_ROOT}/telegram/tdlib" \
        "${LOG_ROOT}/pde" \
        "${TMP_ROOT}/deploy"
    touch "${LOG_ROOT}/pde/stdout.log" "${LOG_ROOT}/pde/stderr.log"
    chown "$APP_USER:$APP_GROUP" "${LOG_ROOT}/pde/stdout.log" "${LOG_ROOT}/pde/stderr.log"
    chmod 0600 "${LOG_ROOT}/pde/stdout.log" "${LOG_ROOT}/pde/stderr.log"

    grep -qxF 'umask 077' "${APP_HOME}/.profile" \
        || echo 'umask 077' >> "${APP_HOME}/.profile"
    chown "$APP_USER:$APP_GROUP" "${APP_HOME}/.profile"
}

generate_secret() {
    openssl rand -base64 48 | tr -d '\n'
}

create_database() {
    local database_password="$1"

    sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -v db_name="$DB_NAME" \
        -v db_password="$database_password" \
        -v db_user="$DB_USER" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name')
\gexec

SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db_name')
\gexec
SQL
}

create_environment_file() {
    local database_password owner_secret
    database_password="$(generate_secret)"
    owner_secret="$(generate_secret)"

    create_database "$database_password"

    umask 077
    cat > "$ENV_FILE" <<EOF
# Managed by scripts/create-user.sh. Keep this file private.
PDE_DESK_TELEGRAM__API_HASH=
PDE_DESK_TELEGRAM__API_ID=
PDE_DESK_TELEGRAM__TDLIB_DIRECTORY=${DATA_ROOT}/telegram/tdlib

PDE_RUNTIME__ACCESS_TOKEN_TTL_SECONDS=900
PDE_RUNTIME__AUTHORIZATION_CODE_TTL_SECONDS=120
PDE_RUNTIME__AUTHORIZATION_REQUEST_TTL_SECONDS=300
PDE_RUNTIME__BASE_URL=${base_url}
PDE_RUNTIME__COOKIE_SECURE=true
PDE_RUNTIME__OWNER_SECRET=${owner_secret}
PDE_RUNTIME__OWNER_SESSION_TTL_SECONDS=3600

TEQFW_DB__CLIENT=pg
TEQFW_DB__DATABASE=${DB_NAME}
TEQFW_DB__HOST=${DB_HOST}
TEQFW_DB__PASSWORD=${database_password}
TEQFW_DB__PORT=${DB_PORT}
TEQFW_DB__USER=${DB_USER}

TEQFW_WEB__HOST=127.0.0.1
TEQFW_WEB__PORT=${port}
TEQFW_WEB__TYPE=http
EOF
    chown "$APP_USER:$APP_GROUP" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
}

set_private_environment_value() {
    local key="$1"
    local value="$2"
    local matches

    matches="$(grep -c "^${key}=" "$ENV_FILE" || true)"
    if [ "$matches" -gt 1 ]; then
        echo "Private configuration contains duplicate ${key} entries: ${ENV_FILE}" >&2
        exit 1
    elif [ "$matches" -eq 1 ]; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
    chown "$APP_USER:$APP_GROUP" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
}

sync_runtime_endpoint() {
    set_private_environment_value 'PDE_RUNTIME__BASE_URL' "$base_url"
    set_private_environment_value 'TEQFW_WEB__PORT' "$port"
}

install_nvm() {
    if [ -s "${APP_HOME}/.nvm/nvm.sh" ]; then
        return
    fi

    sudo -u "$APP_USER" -H bash -c \
        "curl --fail --location --silent --show-error https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
}

install_systemd_service() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=PDE Embassy Host for Igor Gusev
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_ROOT}/current
Environment="HOME=${APP_HOME}"
Environment="NVM_DIR=${APP_HOME}/.nvm"
EnvironmentFile=-${ENV_FILE}
ExecStart=/bin/bash -c 'set -e; . "\$NVM_DIR/nvm.sh"; nvm use --silent; exec npm start'
Restart=on-failure
RestartSec=5s
TimeoutStopSec=10s
KillMode=control-group
UMask=0077
StandardOutput=append:${LOG_ROOT}/pde/stdout.log
StandardError=append:${LOG_ROOT}/pde/stderr.log

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

install_deployment_sudoers() {
    local sudoers_file="/etc/sudoers.d/${APP_USER}"
    local temporary_file
    temporary_file="$(mktemp)"
    trap 'rm -f "$temporary_file"' RETURN

    cat > "$temporary_file" <<EOF
${APP_USER} ALL=(root) NOPASSWD: \\
    /bin/systemctl start ${SERVICE_NAME}, \\
    /bin/systemctl stop ${SERVICE_NAME}
EOF
    visudo -cf "$temporary_file"
    install -m 0440 "$temporary_file" "$sudoers_file"
}

install_logrotate() {
    cat > "/etc/logrotate.d/${SERVICE_NAME}" <<EOF
${LOG_ROOT}/pde/*.log {
    daily
    maxsize 100M
    rotate 14
    compress
    delaycompress
    copytruncate
    su ${APP_USER} ${APP_GROUP}
    missingok
    notifempty
}
EOF
    chmod 0644 "/etc/logrotate.d/${SERVICE_NAME}"
}

install_apache_and_certbot() {
    apt-get update
    apt-get install -y apache2 certbot python3-certbot-apache

    a2enmod rewrite proxy proxy_http2 http2 ssl
    systemctl enable --now apache2

    local http_vhost="${APACHE_SITES_AVAILABLE}/${APP_USER}.conf"
    if [ ! -e "$http_vhost" ]; then
        cat > "$http_vhost" <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    ErrorLog \${APACHE_LOG_DIR}/${APP_USER}.error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_USER}.access.log combined
</VirtualHost>
EOF
        chmod 0644 "$http_vhost"
    elif ! grep -Fqx "    ServerName ${domain}" "$http_vhost"; then
        echo "Existing Apache site does not declare ServerName ${domain}: ${http_vhost}" >&2
        exit 1
    fi

    a2ensite "${APP_USER}.conf"
    apache2ctl configtest
    systemctl reload apache2

    local certbot_args=(--apache --non-interactive --agree-tos --redirect -d "$domain")
    if [ -n "${CERTBOT_EMAIL:-}" ]; then
        certbot_args+=(--email "$CERTBOT_EMAIL")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi
    certbot "${certbot_args[@]}"

    local ssl_vhost=''
    local candidate
    for candidate in "${APACHE_SITES_AVAILABLE}"/*-le-ssl.conf; do
        [ -f "$candidate" ] || continue
        if grep -Fq "ServerName ${domain}" "$candidate"; then
            if [ -n "$ssl_vhost" ]; then
                echo "Multiple Certbot SSL sites declare ${domain}; cannot select one safely." >&2
                exit 1
            fi
            ssl_vhost="$candidate"
        fi
    done
    if [ -z "$ssl_vhost" ]; then
        echo "Certbot did not create a *-le-ssl.conf site for ${domain}." >&2
        exit 1
    fi

    local proxy_config="${APACHE_CONF_AVAILABLE}/${APP_USER}-proxy.conf"
    cat > "$proxy_config" <<EOF
# Managed by scripts/create-user.sh.
ErrorLog \${APACHE_LOG_DIR}/${APP_USER}-ssl.error.log
CustomLog \${APACHE_LOG_DIR}/${APP_USER}-ssl.access.log combined
Protocols h2 http/1.1
RewriteEngine on
RewriteRule "^/(.*)$" "h2c://127.0.0.1:${port}/\$1" [P]
EOF
    chmod 0644 "$proxy_config"

    local include_line="Include ${proxy_config}"
    if ! grep -Fqx "    ${include_line}" "$ssl_vhost"; then
        local temporary_file
        temporary_file="$(mktemp "${ssl_vhost}.XXXXXX")"
        if ! awk -v include_line="$include_line" '
            /^[[:space:]]*<VirtualHost[[:space:]]+\*:443>/ { in_ssl_vhost = 1 }
            in_ssl_vhost && /<\/VirtualHost>/ && !inserted {
                print "    " include_line
                inserted = 1
            }
            { print }
            in_ssl_vhost && /<\/VirtualHost>/ { in_ssl_vhost = 0 }
            END { if (!inserted) exit 42 }
        ' "$ssl_vhost" > "$temporary_file"; then
            rm -f "$temporary_file"
            echo "Could not add the application proxy to ${ssl_vhost}." >&2
            exit 1
        fi
        chmod --reference="$ssl_vhost" "$temporary_file"
        chown --reference="$ssl_vhost" "$temporary_file"
        mv "$temporary_file" "$ssl_vhost"
    fi

    apache2ctl configtest
    systemctl reload apache2
}

validate_arguments() {
    base_url="${BASE_URL:-}"
    port="${PORT:-}"
    if [ -z "$base_url" ]; then
        echo 'BASE_URL is required.' >&2
        usage >&2
        exit 1
    fi
    local domain_pattern='^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))+$'
    if [[ ! "$base_url" =~ $domain_pattern ]]; then
        echo 'BASE_URL must be an HTTPS origin with a DNS hostname, without a port or path.' >&2
        exit 1
    fi
    domain="${base_url#https://}"
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
        echo 'PORT must be an integer between 1024 and 65535.' >&2
        usage >&2
        exit 1
    fi
    if ((10#$port < 1024 || 10#$port > 65535)); then
        echo 'PORT must be an integer between 1024 and 65535.' >&2
        exit 1
    fi
    port="$((10#$port))"
}

main() {
    if [ "${1:-}" = '--help' ]; then
        usage
        exit 0
    fi

    validate_arguments
    require_root
    require_command adduser
    require_command curl
    require_command openssl
    require_command psql
    require_command sudo
    require_command systemctl
    require_command visudo
    require_command apt-get

    if ! id postgres >/dev/null 2>&1; then
        echo 'The PostgreSQL system user is unavailable.' >&2
        exit 1
    fi

    create_user
    if [ -e "$ENV_FILE" ]; then
        echo "Keeping existing private configuration: ${ENV_FILE}"
    else
        create_environment_file
    fi
    install_nvm
    install_systemd_service
    install_deployment_sudoers
    install_logrotate
    sync_runtime_endpoint
    install_apache_and_certbot

    echo "Environment provisioned for ${APP_USER}."
    echo "Deploy the first release, then run: sudo systemctl start ${SERVICE_NAME}"
}

main "$@"
