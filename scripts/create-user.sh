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
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SERVICE_WANTS_FILE="/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
readonly DB_NAME='pde_igor'
readonly DB_USER='pde_igor'
readonly DB_HOST='127.0.0.1'
readonly DB_PORT='5432'
readonly NVM_VERSION='v0.40.6'
readonly SUDOERS_FILE="/etc/sudoers.d/${APP_USER}"
readonly LOGROTATE_FILE="/etc/logrotate.d/${SERVICE_NAME}"
readonly APACHE_SITES_AVAILABLE='/etc/apache2/sites-available'
readonly APACHE_SITES_ENABLED='/etc/apache2/sites-enabled'
readonly APACHE_CONF_AVAILABLE='/etc/apache2/conf-available'
readonly APACHE_MODS_AVAILABLE='/etc/apache2/mods-available'
readonly APACHE_MODS_ENABLED='/etc/apache2/mods-enabled'
readonly HTTP_VHOST_FILE="${APACHE_SITES_AVAILABLE}/${APP_USER}.conf"
readonly PROXY_CONFIG_FILE="${APACHE_CONF_AVAILABLE}/${APP_USER}-proxy.conf"
readonly CERTBOT_ROOT='/etc/letsencrypt'
readonly MANAGED_MARKER='# Managed by scripts/create-user.sh.'
readonly USER_GECOS_MARKER='PDE host managed by scripts/create-user.sh'
readonly DB_OBJECT_MARKER="Managed by scripts/create-user.sh for ${APP_USER}."
readonly PROFILE_MARKER='# Managed by scripts/create-user.sh.'
readonly APACHE_REQUIRED_MODULES=(rewrite proxy proxy_http2 http2 ssl)
readonly APP_DIRECTORIES=(
    "${APP_HOME}/app"
    "${APP_ROOT}"
    "${APP_ROOT}/releases"
    "${PRIVATE_ROOT}"
    "${PRIVATE_ROOT}/pde"
    "${PRIVATE_ROOT}/telegram"
    "${DATA_ROOT}"
    "${DATA_ROOT}/pde"
    "${DATA_ROOT}/telegram"
    "${DATA_ROOT}/telegram/tdlib"
    "${LOG_ROOT}"
    "${LOG_ROOT}/pde"
    "${TMP_ROOT}"
    "${TMP_ROOT}/deploy"
)

base_url=''
port=''
domain=''
app_uid=''
app_gid=''
existing_install=false
app_env_exists=false
pg_role_exists=false
pg_database_exists=false
pg_role_can_login=true
pg_role_marked=false
pg_role_comment_null=false
pg_database_marked=false
pg_database_comment_null=false
pg_database_owner=''
pg_reset_password=false
pg_fix_database_owner=false
apache_changed=false
app_user_present=false
certificate_lineage=''
certificate_valid=false
ssl_vhost_missing_certificate=false
systemd_file_state=''
sudoers_file_state=''
logrotate_file_state=''
http_vhost_state=''
proxy_config_state=''
ssl_vhosts=()
temporary_files=()

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

fail() {
    echo "$1" >&2
    exit 1
}

cleanup_temporary_files() {
    local temporary_file
    for temporary_file in "${temporary_files[@]}"; do
        rm -f -- "$temporary_file" || true
    done
}

# Cleanup reads only script-scoped paths; traps never capture local variables.
trap cleanup_temporary_files EXIT

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

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

ensure_file_properties() {
    local path="$1"
    local owner="$2"
    local group="$3"
    local mode="$4"
    local expected_owner current_owner current_mode
    expected_owner="$(id -u "$owner"):$(getent group "$group" | cut -d: -f3)"
    current_owner="$(stat -c '%u:%g' "$path")"
    current_mode="$(stat -c '%a' "$path")"
    [ "$current_owner" = "$expected_owner" ] || chown "$owner:$group" "$path"
    [ "$current_mode" = "${mode#0}" ] || chmod "$mode" "$path"
}

commit_rendered_file() {
    local source="$1"
    local target="$2"
    local owner="$3"
    local group="$4"
    local mode="$5"
    local replacement
    file_changed=false

    if path_exists "$target" && cmp -s "$source" "$target"; then
        ensure_file_properties "$target" "$owner" "$group" "$mode"
        rm -f "$source"
        return
    fi
    replacement="$(mktemp "${target}.tmp.XXXXXX")"
    temporary_files+=("$replacement")
    install -m "$mode" -o "$owner" -g "$group" "$source" "$replacement"
    mv -f "$replacement" "$target"
    rm -f "$source"
    file_changed=true
}

read_env_value() {
    local key="$1"
    awk -v key="$key" '
        index($0, key "=") == 1 {
            count++
            value = substr($0, length(key) + 2)
        }
        END {
            if (count != 1) exit 1
            print value
        }
    ' "$ENV_FILE"
}

assert_root_owned_regular_file() {
    local path="$1"
    if [ -L "$path" ] || [ ! -f "$path" ]; then
        fail "Expected a regular, non-symlink configuration file: ${path}"
    fi
    if [ "$(stat -c '%u:%g' "$path")" != '0:0' ]; then
        fail "Expected root ownership for configuration file: ${path}"
    fi
}

classify_managed_file() {
    local path="$1"
    local legacy_renderer="$2"
    local description="$3"

    if ! path_exists "$path"; then
        printf 'absent\n'
        return
    fi
    assert_root_owned_regular_file "$path"
    if grep -Fqx "$MANAGED_MARKER" "$path"; then
        existing_install=true
        printf 'managed\n'
        return
    fi
    if [ "$existing_install" = true ] && [ -n "$legacy_renderer" ] \
        && cmp -s "$path" <("$legacy_renderer"); then
        printf 'legacy\n'
        return
    fi
    fail "Existing ${description} is not marked as managed by this script and does not match its legacy format: ${path}"
}

render_systemd_service_body() {
    cat <<EOF
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
}

render_systemd_service() {
    printf '%s\n' "$MANAGED_MARKER"
    render_systemd_service_body
}

render_legacy_systemd_service() {
    render_systemd_service_body
}

render_sudoers_body() {
    cat <<EOF
${APP_USER} ALL=(root) NOPASSWD: \\
    /bin/systemctl start ${SERVICE_NAME}, \\
    /bin/systemctl stop ${SERVICE_NAME}
EOF
}

render_sudoers_file() {
    printf '%s\n' "$MANAGED_MARKER"
    render_sudoers_body
}

render_legacy_sudoers_file() {
    render_sudoers_body
}

render_logrotate_body() {
    cat <<EOF
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
}

render_logrotate_file() {
    printf '%s\n' "$MANAGED_MARKER"
    render_logrotate_body
}

render_legacy_logrotate_file() {
    render_logrotate_body
}

create_user() {
    if ! id "$APP_USER" >/dev/null 2>&1; then
        adduser --disabled-password --gecos "$USER_GECOS_MARKER" "$APP_USER"
    fi

    app_uid="$(id -u "$APP_USER")"
    app_gid="$(id -g "$APP_USER")"
    install -d -m 0700 -o "$APP_USER" -g "$APP_GROUP" "$APP_HOME"
    ensure_file_properties "$APP_HOME" "$APP_USER" "$APP_GROUP" 0700
    install -d -m 0700 -o "$APP_USER" -g "$APP_GROUP" "${APP_DIRECTORIES[@]}"
    local log_file
    for log_file in "${LOG_ROOT}/pde/stdout.log" "${LOG_ROOT}/pde/stderr.log"; do
        if ! path_exists "$log_file"; then
            install -m 0600 -o "$APP_USER" -g "$APP_GROUP" /dev/null "$log_file"
        else
            ensure_file_properties "$log_file" "$APP_USER" "$APP_GROUP" 0600
        fi
    done

    local profile="${APP_HOME}/.profile"
    if ! grep -Eq '^[[:space:]]*umask[[:space:]]+(077|0077)([[:space:]]*(#.*)?)?$' "$profile"; then
        if ! grep -Fqx "$PROFILE_MARKER" "$profile"; then
            printf '\n%s\n' "$PROFILE_MARKER" >> "$profile"
        fi
        printf 'umask 077\n' >> "$profile"
    fi
    ensure_file_properties "$profile" "$APP_USER" "$APP_GROUP" "$(stat -c '%a' "$profile")"
}

generate_secret() {
    openssl rand -base64 48 | tr -d '\n'
}

inspect_postgres() {
    local result
    result="$(sudo -u postgres psql -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -v db_name="$DB_NAME" \
        -v db_user="$DB_USER" \
        -v object_marker="$DB_OBJECT_MARKER" <<'SQL'
SELECT
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user'),
    COALESCE((SELECT rolcanlogin FROM pg_roles WHERE rolname = :'db_user'), false),
    COALESCE((SELECT shobj_description(oid, 'pg_authid') = :'object_marker'
              FROM pg_authid WHERE rolname = :'db_user'), false),
    COALESCE((SELECT shobj_description(oid, 'pg_authid') IS NULL
              FROM pg_authid WHERE rolname = :'db_user'), false),
    EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name'),
    COALESCE((SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = :'db_name'), ''),
    COALESCE((SELECT shobj_description(oid, 'pg_database') = :'object_marker'
              FROM pg_database WHERE datname = :'db_name'), false),
    COALESCE((SELECT shobj_description(oid, 'pg_database') IS NULL
              FROM pg_database WHERE datname = :'db_name'), false);
SQL
    )" || fail 'Could not inspect PostgreSQL state as the postgres administrator.'

    IFS='|' read -r pg_role_exists role_can_login pg_role_marked pg_role_comment_null \
        pg_database_exists pg_database_owner pg_database_marked pg_database_comment_null <<< "$result"
    pg_role_exists="$([[ "$pg_role_exists" == t ]] && echo true || echo false)"
    pg_role_marked="$([[ "$pg_role_marked" == t ]] && echo true || echo false)"
    pg_role_comment_null="$([[ "$pg_role_comment_null" == t ]] && echo true || echo false)"
    pg_database_exists="$([[ "$pg_database_exists" == t ]] && echo true || echo false)"
    pg_database_marked="$([[ "$pg_database_marked" == t ]] && echo true || echo false)"
    pg_database_comment_null="$([[ "$pg_database_comment_null" == t ]] && echo true || echo false)"
    if [ "$pg_role_exists" = true ] && [ "$role_can_login" != t ]; then
        pg_role_can_login=false
    else
        pg_role_can_login=true
    fi
}

create_database() {
    local database_password="$1"
    local reset_password="$2"
    local database_was_missing=false
    [ "$pg_database_exists" = true ] || database_was_missing=true

    # Create and mark a role in one transaction so interruption cannot leave an
    # unrecognizable role behind. Existing unmarked roles are adopted only
    # after preflight has proved this is a legacy PDE installation.
    sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 \
        -v db_password="$database_password" -v db_user="$DB_USER" \
        -v object_marker="$DB_OBJECT_MARKER" -v role_exists="$pg_role_exists" \
        -v reset_password="$reset_password" <<'SQL'
BEGIN;
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE :'role_exists' = 'false'
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE :'role_exists' = 'true' AND :'reset_password' = 'true'
\gexec
SELECT format('COMMENT ON ROLE %I IS %L', :'db_user', :'object_marker')
WHERE (SELECT shobj_description(oid, 'pg_authid') IS NULL
       FROM pg_authid WHERE rolname = :'db_user')
\gexec
COMMIT;
SQL

    if [ "$database_was_missing" = true ]; then
        sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 \
            -v db_name="$DB_NAME" -v db_user="$DB_USER" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name')
\gexec
SQL
    elif [ "$pg_fix_database_owner" = true ]; then
        sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 \
            -v db_name="$DB_NAME" -v db_user="$DB_USER" <<'SQL'
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user')
WHERE (SELECT pg_get_userbyid(datdba) <> :'db_user'
       FROM pg_database WHERE datname = :'db_name')
\gexec
SQL
    fi
    sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 \
        -v db_name="$DB_NAME" -v object_marker="$DB_OBJECT_MARKER" <<'SQL'
SELECT format('COMMENT ON DATABASE %I IS %L', :'db_name', :'object_marker')
WHERE (SELECT shobj_description(oid, 'pg_database') IS NULL
       FROM pg_database WHERE datname = :'db_name')
\gexec
REVOKE ALL ON DATABASE :"db_name" FROM PUBLIC;
SQL
}

create_environment_file() {
    local database_password="$1"
    local owner_secret="$2"
    local temporary_file
    temporary_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    temporary_files+=("$temporary_file")
    umask 077
    cat > "$temporary_file" <<EOF
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
    chown "$APP_USER:$APP_GROUP" "$temporary_file"
    chmod 0600 "$temporary_file"
    mv -f "$temporary_file" "$ENV_FILE"
}

set_private_environment_value() {
    local key="$1"
    local value="$2"
    local matches temporary_file
    local current_value

    matches="$(awk -v key="$key" 'index($0, key "=") == 1 { count++ } END { print count + 0 }' "$ENV_FILE")"
    if [ "$matches" -gt 1 ]; then
        fail "Private configuration contains duplicate ${key} entries: ${ENV_FILE}"
    fi
    if [ "$matches" -eq 1 ]; then
        current_value="$(read_env_value "$key")"
        if [ "$current_value" = "$value" ]; then
            return
        fi
    fi
    temporary_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    temporary_files+=("$temporary_file")
    if [ "$matches" -eq 1 ]; then
        awk -v key="$key" -v value="$value" '
            index($0, key "=") == 1 { print key "=" value; next }
            { print }
        ' "$ENV_FILE" > "$temporary_file"
    else
        cat "$ENV_FILE" > "$temporary_file"
        printf '\n%s=%s\n' "$key" "$value" >> "$temporary_file"
    fi
    ensure_file_properties "$temporary_file" "$APP_USER" "$APP_GROUP" 0600
    if ! cmp -s "$temporary_file" "$ENV_FILE"; then
        mv -f "$temporary_file" "$ENV_FILE"
    fi
}

sync_runtime_endpoint() {
    set_private_environment_value 'PDE_RUNTIME__BASE_URL' "$base_url"
    set_private_environment_value 'TEQFW_WEB__PORT' "$port"
}

install_nvm() {
    if [ -s "${APP_HOME}/.nvm/nvm.sh" ] \
        && [ "$(stat -c '%u:%g' "${APP_HOME}/.nvm/nvm.sh")" = "${app_uid}:${app_gid}" ]; then
        return
    fi

    sudo -u "$APP_USER" -H bash -c \
        "set -o pipefail; curl --fail --location --silent --show-error https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | PROFILE=/dev/null bash"
}

install_systemd_service() {
    local temporary_file
    if [ "$systemd_file_state" = legacy ]; then
        ensure_file_properties "$SERVICE_FILE" root root 0644
        if ! systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
            systemctl enable "$SERVICE_NAME"
        fi
        return
    fi
    temporary_file="$(mktemp --suffix=.service /tmp/pde-igor-unit.XXXXXX)"
    temporary_files+=("$temporary_file")
    if ! render_systemd_service > "$temporary_file"; then
        rm -f "$temporary_file"
        fail "Could not render the systemd unit for ${SERVICE_NAME}."
    fi
    chmod 0644 "$temporary_file"
    if ! systemd-analyze verify "$temporary_file"; then
        rm -f "$temporary_file"
        fail "Generated systemd unit failed validation: ${SERVICE_FILE}"
    fi

    commit_rendered_file "$temporary_file" "$SERVICE_FILE" root root 0644
    if [ "$file_changed" = true ]; then
        systemctl daemon-reload
    fi
    if path_exists "$SERVICE_WANTS_FILE" && [ ! -e "$SERVICE_WANTS_FILE" ]; then
        rm -f "$SERVICE_WANTS_FILE"
    fi
    if ! systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl enable "$SERVICE_NAME"
    fi
}

install_deployment_sudoers() {
    local temporary_file
    if [ "$sudoers_file_state" = legacy ]; then
        ensure_file_properties "$SUDOERS_FILE" root root 0440
        return
    fi
    temporary_file="$(mktemp /tmp/pde-igor-sudoers.XXXXXX)"
    temporary_files+=("$temporary_file")
    if ! render_sudoers_file > "$temporary_file"; then
        rm -f "$temporary_file"
        fail "Could not render the sudoers rule for ${APP_USER}."
    fi
    chmod 0440 "$temporary_file"
    if ! visudo -cf "$temporary_file"; then
        rm -f "$temporary_file"
        fail "Generated sudoers rule failed validation: ${SUDOERS_FILE}"
    fi

    commit_rendered_file "$temporary_file" "$SUDOERS_FILE" root root 0440
}

install_logrotate() {
    local temporary_file
    if [ "$logrotate_file_state" = legacy ]; then
        ensure_file_properties "$LOGROTATE_FILE" root root 0644
        return
    fi
    temporary_file="$(mktemp /tmp/pde-igor-logrotate.XXXXXX)"
    temporary_files+=("$temporary_file")
    if ! render_logrotate_file > "$temporary_file"; then
        rm -f "$temporary_file"
        fail "Could not render the logrotate rule for ${SERVICE_NAME}."
    fi
    chmod 0644 "$temporary_file"
    if ! logrotate --debug "$temporary_file" >/dev/null; then
        rm -f "$temporary_file"
        fail "Generated logrotate configuration failed validation: ${LOGROTATE_FILE}"
    fi

    commit_rendered_file "$temporary_file" "$LOGROTATE_FILE" root root 0644
}

render_http_vhost_base_body() {
    cat <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    ErrorLog \${APACHE_LOG_DIR}/${APP_USER}.error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_USER}.access.log combined
</VirtualHost>
EOF
}

render_http_vhost_body() {
    render_http_vhost_base_body | sed '$d'
    if [ "$certificate_valid" = true ]; then
        cat <<EOF
    RewriteEngine on
    RewriteCond %{SERVER_NAME} =${domain}
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
EOF
    fi
    cat <<'EOF'
</VirtualHost>
EOF
}

render_http_vhost() {
    printf '%s\n' "$MANAGED_MARKER"
    render_http_vhost_body
}

render_proxy_config() {
    cat <<EOF
${MANAGED_MARKER}
ErrorLog \${APACHE_LOG_DIR}/${APP_USER}-ssl.error.log
CustomLog \${APACHE_LOG_DIR}/${APP_USER}-ssl.access.log combined
Protocols h2 http/1.1
RewriteEngine on
RewriteRule "^/(.*)$" "h2c://127.0.0.1:${port}/\$1" [P]
EOF
}

read_app_environment() {
    app_env_exists=false
    if ! path_exists "$ENV_FILE"; then
        return
    fi
    if [ -L "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
        fail "Private configuration must be a regular, non-symlink file: ${ENV_FILE}"
    fi
    if ! grep -Eq '^# Managed by scripts/create-user\.sh\.' "$ENV_FILE"; then
        fail "Existing private configuration is not marked as managed by this script: ${ENV_FILE}"
    fi
    if [ -z "$app_uid" ] || [ "$(stat -c '%u:%g' "$ENV_FILE")" != "${app_uid}:${app_gid}" ]; then
        fail "Private configuration ownership does not match ${APP_USER}:${APP_GROUP}: ${ENV_FILE}"
    fi
    app_env_exists=true
    existing_install=true
    local key value matches
    for key in PDE_RUNTIME__OWNER_SECRET TEQFW_DB__PASSWORD TEQFW_DB__DATABASE TEQFW_DB__USER \
        TEQFW_DB__HOST TEQFW_DB__PORT; do
        value="$(read_env_value "$key")" || fail "Private configuration is missing or duplicates ${key}: ${ENV_FILE}"
        [ -n "$value" ] || fail "Private configuration has an empty ${key}: ${ENV_FILE}"
    done
    for key in PDE_RUNTIME__BASE_URL TEQFW_WEB__PORT; do
        matches="$(awk -v key="$key" 'index($0, key "=") == 1 { count++ } END { print count + 0 }' "$ENV_FILE")"
        [ "$matches" -le 1 ] || fail "Private configuration contains duplicate ${key} entries: ${ENV_FILE}"
    done
    [ "$(read_env_value TEQFW_DB__DATABASE)" = "$DB_NAME" ] || \
        fail "Private configuration points to an unexpected PostgreSQL database: ${ENV_FILE}"
    [ "$(read_env_value TEQFW_DB__USER)" = "$DB_USER" ] || \
        fail "Private configuration points to an unexpected PostgreSQL role: ${ENV_FILE}"
    [ "$(read_env_value TEQFW_DB__HOST)" = "$DB_HOST" ] || \
        fail "Private configuration points to an unexpected PostgreSQL host: ${ENV_FILE}"
    [ "$(read_env_value TEQFW_DB__PORT)" = "$DB_PORT" ] || \
        fail "Private configuration points to an unexpected PostgreSQL port: ${ENV_FILE}"
}

inspect_account_and_directories() {
    local passwd_entry group_entry home_field profile nvm_dir path
    if id "$APP_USER" >/dev/null 2>&1; then
        app_user_present=true
        passwd_entry="$(getent passwd "$APP_USER")"
        app_uid="$(id -u "$APP_USER")"
        app_gid="$(id -g "$APP_USER")"
        [ "$(id -gn "$APP_USER")" = "$APP_GROUP" ] || \
            fail "Existing Unix user ${APP_USER} has a primary group other than ${APP_GROUP}."
        group_entry="$(getent group "$APP_GROUP")" || fail "Unix group ${APP_GROUP} is missing."
        [ "$(printf '%s' "$group_entry" | cut -d: -f3)" = "$app_gid" ] || \
            fail "Existing Unix group ${APP_GROUP} does not match ${APP_USER}'s primary group."
        home_field="$(printf '%s' "$passwd_entry" | cut -d: -f6)"
        [ "$home_field" = "$APP_HOME" ] || \
            fail "Existing Unix user ${APP_USER} has unexpected home directory: ${home_field}"
        if [[ "$(printf '%s' "$passwd_entry" | cut -d: -f5)" == *"$USER_GECOS_MARKER"* ]]; then
            existing_install=true
        fi
        if [ -e "$APP_HOME" ] || [ -L "$APP_HOME" ]; then
            [ -d "$APP_HOME" ] && [ ! -L "$APP_HOME" ] || fail "Expected a real home directory at ${APP_HOME}."
        fi
    elif getent group "$APP_GROUP" >/dev/null 2>&1; then
        fail "Unix group ${APP_GROUP} already exists without its expected user; refusing to adopt it."
    fi

    read_app_environment
    if [ "$app_env_exists" = true ] && [ "$(id -u "$APP_USER")" != "$app_uid" ]; then
        fail "Private configuration exists but the ${APP_USER} account is missing."
    fi

    if [ -d "$APP_HOME" ]; then
        for path in "${APP_DIRECTORIES[@]}"; do
            if path_exists "$path"; then
                [ -d "$path" ] && [ ! -L "$path" ] || fail "Expected an application directory, found a conflicting path: ${path}"
            fi
        done
        profile="${APP_HOME}/.profile"
        if path_exists "$profile" && { [ -L "$profile" ] || [ ! -f "$profile" ]; }; then
            fail "Expected a regular profile file: ${profile}"
        fi
        nvm_dir="${APP_HOME}/.nvm"
        if path_exists "$nvm_dir"; then
            [ -d "$nvm_dir" ] && [ ! -L "$nvm_dir" ] || fail "NVM path is not a real directory: ${nvm_dir}"
            if [ "$(stat -c '%u:%g' "$nvm_dir")" != "${app_uid}:${app_gid}" ]; then
                fail "Existing NVM directory has unexpected ownership: ${nvm_dir}"
            fi
            if [ -e "${nvm_dir}/nvm.sh" ] && { [ -L "${nvm_dir}/nvm.sh" ] || [ ! -f "${nvm_dir}/nvm.sh" ]; }; then
                fail "Existing NVM entry point is not a regular file: ${nvm_dir}/nvm.sh"
            fi
        fi
        for path in "${LOG_ROOT}/pde/stdout.log" "${LOG_ROOT}/pde/stderr.log"; do
            if path_exists "$path"; then
                [ -f "$path" ] && [ ! -L "$path" ] || fail "Expected a regular log file: ${path}"
            fi
        done
    elif path_exists "$APP_HOME"; then
        fail "Expected a real home directory at ${APP_HOME}."
    fi
}

inspect_postgres_state() {
    inspect_postgres
    if [ "$pg_role_marked" = true ] || [ "$pg_database_marked" = true ]; then
        existing_install=true
    fi
    if [ "$pg_role_exists" = true ] && [ "$pg_role_marked" != true ] && [ "$pg_role_comment_null" != true ]; then
        fail "PostgreSQL role ${DB_USER} has a different ownership comment; refusing to modify it."
    fi
    if [ "$pg_database_exists" = true ] && [ "$pg_database_marked" != true ] && [ "$pg_database_comment_null" != true ]; then
        fail "PostgreSQL database ${DB_NAME} has a different ownership comment; refusing to modify it."
    fi
    if [ "$pg_database_exists" = true ] && [ "$pg_database_owner" != "$DB_USER" ]; then
        if [ "$pg_database_marked" = true ]; then
            pg_fix_database_owner=true
        else
            fail "PostgreSQL database ${DB_NAME} is owned by ${pg_database_owner}, expected ${DB_USER}, and is not marked as managed."
        fi
    fi
    if [ "$pg_role_exists" = true ] && [ "$pg_role_can_login" != true ]; then
        if [ "$pg_role_marked" = true ]; then
            pg_reset_password=true
        else
            fail "PostgreSQL role ${DB_USER} exists without LOGIN permission and is not marked as managed."
        fi
    fi

    if [ "$app_env_exists" = true ]; then
        if [ "$pg_role_exists" = true ] && [ "$pg_role_comment_null" = true ] && [ "$existing_install" != true ]; then
            fail "Unmarked PostgreSQL role ${DB_USER} cannot be tied to this installation."
        fi
        if [ "$pg_database_exists" = true ] && [ "$pg_database_comment_null" = true ] && [ "$existing_install" != true ]; then
            fail "Unmarked PostgreSQL database ${DB_NAME} cannot be tied to this installation."
        fi
        if [ "$pg_role_exists" = true ]; then
            local database_password auth_output auth_database
            database_password="$(read_env_value TEQFW_DB__PASSWORD)"
            auth_database="$DB_NAME"
            [ "$pg_database_exists" = true ] || auth_database=postgres
            if ! auth_output="$(PGPASSWORD="$database_password" psql -X -w -h "$DB_HOST" -p "$DB_PORT" \
                -U "$DB_USER" -d "$auth_database" -qAt -c 'SELECT current_user' 2>&1)"; then
                if [ "$pg_role_marked" = true ]; then
                    pg_reset_password=true
                else
                    fail "Cannot authenticate to the existing PostgreSQL database with app.env credentials; the role is not marked as managed, so its password was not changed. ${auth_output}"
                fi
            elif [ "$auth_output" != "$DB_USER" ]; then
                fail "PostgreSQL authentication returned an unexpected role for ${DB_NAME}."
            fi
        fi
    elif [ "$pg_role_exists" = true ] || [ "$pg_database_exists" = true ]; then
        if [ "$pg_role_marked" != true ] || \
            { [ "$pg_database_exists" = true ] && [ "$pg_database_marked" != true ] && [ "$pg_database_comment_null" != true ]; }; then
            fail "PostgreSQL role/database ${DB_USER}/${DB_NAME} exists without app.env and is not unambiguously marked as this PDE installation; refusing to invent credentials."
        fi
        if [ "$pg_database_exists" = true ] && [ "$pg_database_marked" != true ] && [ "$pg_database_comment_null" = true ]; then
            [ "$pg_role_marked" = true ] || fail "Unmarked PostgreSQL database ${DB_NAME} cannot be recovered safely."
        fi
        pg_reset_password=true
    fi
}

is_expected_legacy_http_vhost() {
    local path="$1"
    cmp -s "$path" <(render_http_vhost_base_body) && return 0
    awk -v domain="$domain" '
        /^[[:space:]]*RewriteEngine on[[:space:]]*$/ { next }
        $0 == "    RewriteCond %{SERVER_NAME} =" domain { next }
        $0 == "    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]" { next }
        /^[[:space:]]*$/ { next }
        { print }
    ' "$path" | cmp -s - <(render_http_vhost_base_body)
}

vhost_mentions_domain() {
    local path="$1" directive candidate
    while read -r directive candidate _; do
        case "$directive" in
            ServerName|ServerAlias)
                for candidate in ${candidate:-}; do
                    if [[ "$domain" == $candidate ]]; then
                        return 0
                    fi
                done
                ;;
        esac
    done < <(awk '
        tolower($1) == "servername" { print "ServerName", $2 }
        tolower($1) == "serveralias" { for (i = 2; i <= NF; i++) print "ServerAlias", $i }
    ' "$path")
    return 1
}

inspect_certbot_configuration() {
    local renewal renewal_domain domains ssl_file cert_file key_file lineage candidate
    local renewal_matches=0
    certificate_lineage=''
    certificate_valid=false
    ssl_vhost_missing_certificate=false
    ssl_vhosts=()

    if [ -d "${CERTBOT_ROOT}/renewal" ]; then
        for renewal in "${CERTBOT_ROOT}"/renewal/*.conf; do
            [ -f "$renewal" ] || continue
            assert_root_owned_regular_file "$renewal"
            domains="$(awk -F= '/^[[:space:]]*domains[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$renewal" | tr -d '[:space:]')"
            renewal_domain="${domains//,/ }"
            local exact_domains=true name
            for name in $renewal_domain; do
                [ "$name" = "$domain" ] || exact_domains=false
            done
            if [[ " $renewal_domain " == *" $domain "* ]]; then
                [ "$exact_domains" = true ] || fail "Certbot lineage $(basename "$renewal") also covers other domains; refusing to alter a shared certificate."
                renewal_matches=$((renewal_matches + 1))
                certificate_lineage="$(basename "$renewal" .conf)"
            fi
        done
    fi
    [ "$renewal_matches" -le 1 ] || fail "Multiple Certbot lineages cover ${domain}; cannot choose one safely."

    if [ -d "$APACHE_SITES_AVAILABLE" ]; then
        for candidate in "$APACHE_SITES_AVAILABLE"/*-le-ssl.conf; do
            [ -f "$candidate" ] || continue
            if vhost_mentions_domain "$candidate"; then
                assert_root_owned_regular_file "$candidate"
                ssl_vhosts+=("$candidate")
            fi
        done
    fi
    [ "${#ssl_vhosts[@]}" -le 1 ] || fail "Multiple Certbot SSL virtual hosts declare ${domain}; cannot select one safely."

    if [ "${#ssl_vhosts[@]}" -eq 1 ]; then
        ssl_file="${ssl_vhosts[0]}"
        local ssl_block_count
        ssl_block_count="$(awk '
            /^[[:space:]]*<VirtualHost[[:space:]]+\*:443>/ { total++ }
            /^[[:space:]]*<VirtualHost[[:space:]]/ { all++ }
            END { printf "%d|%d", all, total }
        ' "$ssl_file")"
        [ "$ssl_block_count" = '1|1' ] || \
            fail "Certbot virtual host for ${domain} contains an unexpected number of VirtualHost blocks: ${ssl_file}"
        cert_file="$(awk 'tolower($1) == "sslcertificatefile" { print $2; exit }' "$ssl_file")"
        key_file="$(awk 'tolower($1) == "sslcertificatekeyfile" { print $2; exit }' "$ssl_file")"
        [[ "$cert_file" == "${CERTBOT_ROOT}/live/"*/fullchain.pem ]] || \
            fail "Certbot virtual host for ${domain} references an unexpected certificate path: ${ssl_file}"
        [[ "$key_file" == "${CERTBOT_ROOT}/live/"*/privkey.pem ]] || \
            fail "Certbot virtual host for ${domain} references an unexpected private key path: ${ssl_file}"
        [ "$(dirname "$cert_file")" = "$(dirname "$key_file")" ] || \
            fail "Certbot virtual host for ${domain} uses mismatched certificate and key lineages."
        lineage="$(basename "$(dirname "$cert_file")")"
        [ -n "$certificate_lineage" ] && [ "$certificate_lineage" = "$lineage" ] || \
            fail "Certbot virtual host and renewal configuration disagree for ${domain}."
    fi

    if [ -n "$certificate_lineage" ]; then
        cert_file="${CERTBOT_ROOT}/live/${certificate_lineage}/fullchain.pem"
        key_file="${CERTBOT_ROOT}/live/${certificate_lineage}/privkey.pem"
        if [ ! -s "$cert_file" ] || [ ! -s "$key_file" ]; then
            [ "${#ssl_vhosts[@]}" -eq 0 ] || ssl_vhost_missing_certificate=true
        elif openssl x509 -in "$cert_file" -noout -checkhost "$domain" -checkend 0 >/dev/null 2>&1; then
            certificate_valid=true
        fi
    fi
}

inspect_apache_state() {
    local candidate module link target listener port_number count
    if ! path_exists "$HTTP_VHOST_FILE"; then
        http_vhost_state=absent
    else
        assert_root_owned_regular_file "$HTTP_VHOST_FILE"
        if grep -Fqx "$MANAGED_MARKER" "$HTTP_VHOST_FILE"; then
            http_vhost_state=managed
            existing_install=true
        else
            is_expected_legacy_http_vhost "$HTTP_VHOST_FILE" || \
                fail "Existing Apache site is not a recognized pde-igor HTTP virtual host: ${HTTP_VHOST_FILE}"
            http_vhost_state=legacy
            existing_install=true
        fi
    fi
    proxy_config_state="$(classify_managed_file "$PROXY_CONFIG_FILE" '' 'PDE Apache proxy configuration')"
    [ "$proxy_config_state" != managed ] || existing_install=true

    inspect_certbot_configuration

    if [ -d "$APACHE_SITES_AVAILABLE" ]; then
        local expected_http_name ssl_candidate_found=false
        expected_http_name="$HTTP_VHOST_FILE"
        for candidate in "$APACHE_SITES_AVAILABLE"/*.conf; do
            [ -f "$candidate" ] || continue
            vhost_mentions_domain "$candidate" || continue
            if [ "$candidate" = "$expected_http_name" ]; then
                [ "$http_vhost_state" != absent ] || fail "An Apache site declares ${domain} at the expected path but is not recognized."
            elif [[ "$candidate" == *-le-ssl.conf ]]; then
                ssl_candidate_found=true
            else
                fail "Another Apache virtual host already declares ${domain}: ${candidate}"
            fi
        done
        if [ "$ssl_candidate_found" = true ] && [ "${#ssl_vhosts[@]}" -ne 1 ]; then
            fail "Apache has an SSL virtual host for ${domain} that is not a single recognized Certbot configuration."
        fi
        for candidate in "$APACHE_SITES_ENABLED"/*; do
            [ -e "$candidate" ] || [ -L "$candidate" ] || continue
            if [ "$candidate" = "${APACHE_SITES_ENABLED}/${APP_USER}.conf" ]; then
                [ -L "$candidate" ] || fail "Enabled Apache site path is not a symlink: ${candidate}"
                target="$(readlink -m "$candidate")"
                [ "$target" = "$HTTP_VHOST_FILE" ] || fail "Enabled Apache site points somewhere unexpected: ${candidate}"
            elif [ "${#ssl_vhosts[@]}" -eq 1 ] && [ "$candidate" = "${APACHE_SITES_ENABLED}/$(basename "${ssl_vhosts[0]}")" ]; then
                [ -L "$candidate" ] || fail "Enabled Certbot site path is not a symlink: ${candidate}"
                target="$(readlink -m "$candidate")"
                [ "$target" = "${ssl_vhosts[0]}" ] || fail "Enabled Certbot site points somewhere unexpected: ${candidate}"
            fi
        done
    fi

    for module in "${APACHE_REQUIRED_MODULES[@]}"; do
        link="${APACHE_MODS_ENABLED}/${module}.load"
        if path_exists "$link"; then
            [ -L "$link" ] || fail "Apache module enable path is not a symlink: ${link}"
            target="$(readlink -m "$link")"
            [ "$target" = "${APACHE_MODS_AVAILABLE}/${module}.load" ] || \
                fail "Apache module link points to an unexpected module: ${link}"
        fi
    done

    if [ "${#ssl_vhosts[@]}" -eq 1 ] && [ "$http_vhost_state" = absent ] \
        && ! grep -Fq "$PROXY_CONFIG_FILE" "${ssl_vhosts[0]}"; then
        fail "Certbot SSL configuration for ${domain} has no matching managed HTTP site or PDE proxy include."
    fi
    if [ -d /etc/apache2 ]; then
        local allowed_proxy_vhost=''
        [ "${#ssl_vhosts[@]}" -eq 1 ] && allowed_proxy_vhost="${ssl_vhosts[0]}"
        while IFS= read -r candidate; do
            [ -f "$candidate" ] || continue
            count="$(awk -v include_file="$PROXY_CONFIG_FILE" '
                {
                    line = $0
                    sub(/^[[:space:]]+/, "", line)
                    if (tolower(line) ~ /^include[[:space:]]/) {
                        split(line, fields, /[[:space:]]+/)
                        target = fields[2]
                        gsub(/"/, "", target)
                        if (target == include_file) count++
                    }
                }
                END { print count + 0 }
            ' "$candidate")"
            if [ "$count" -gt 0 ]; then
                [ "$candidate" = "$allowed_proxy_vhost" ] || \
                    fail "PDE proxy include is referenced by another Apache configuration: ${candidate}"
            fi
        done < <(find /etc/apache2 -type f -name '*.conf' -print 2>/dev/null)
    fi

    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r listener; do
            [ -n "$listener" ] || continue
            port_number="$(awk '{split($4, parts, ":"); print parts[length(parts)]}' <<< "$listener")"
            if [[ "$port_number" == 80 || "$port_number" == 443 ]] && [[ "$listener" != *apache2* ]]; then
                fail "TCP port ${port_number} is already used by a non-Apache process: ${listener}"
            fi
        done < <(ss -H -ltnp 2>/dev/null)
    else
        fail 'Required command is unavailable: ss (cannot verify Apache ports 80 and 443).'
    fi

}

inspect_managed_files() {
    systemd_file_state="$(classify_managed_file "$SERVICE_FILE" render_legacy_systemd_service 'systemd unit')"
    sudoers_file_state="$(classify_managed_file "$SUDOERS_FILE" render_legacy_sudoers_file 'sudoers rule')"
    logrotate_file_state="$(classify_managed_file "$LOGROTATE_FILE" render_legacy_logrotate_file 'logrotate configuration')"
    [ "$systemd_file_state" != managed ] || existing_install=true
    [ "$sudoers_file_state" != managed ] || existing_install=true
    [ "$logrotate_file_state" != managed ] || existing_install=true

    if path_exists "$SERVICE_FILE" && [ "$systemd_file_state" != managed ]; then
        systemd-analyze verify "$SERVICE_FILE" || fail "Existing systemd unit is invalid: ${SERVICE_FILE}"
    fi
    if path_exists "$SUDOERS_FILE" && [ "$sudoers_file_state" != managed ]; then
        visudo -cf "$SUDOERS_FILE" >/dev/null || fail "Existing sudoers rule is invalid: ${SUDOERS_FILE}"
    fi
    if path_exists "$LOGROTATE_FILE" && [ "$logrotate_file_state" != managed ] \
        && command -v logrotate >/dev/null 2>&1; then
        logrotate --debug "$LOGROTATE_FILE" >/dev/null 2>&1 || fail "Existing logrotate configuration is invalid: ${LOGROTATE_FILE}"
    fi
    if path_exists "$SERVICE_WANTS_FILE"; then
        [ -L "$SERVICE_WANTS_FILE" ] || fail "Systemd enable path is not a symlink: ${SERVICE_WANTS_FILE}"
        [ "$(readlink -m "$SERVICE_WANTS_FILE")" = "$SERVICE_FILE" ] || \
            fail "Systemd enable path points to another unit: ${SERVICE_WANTS_FILE}"
    fi
    inspect_apache_state
    inspect_postgres_state
}

preflight() {
    inspect_account_and_directories
    inspect_managed_files
    if [ "$app_user_present" = true ] && [ "$existing_install" != true ]; then
        fail "Unix user ${APP_USER} exists but has no marker or private configuration proving it belongs to this PDE installation."
    fi
}

package_is_installed() {
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = installed ]
}

install_missing_packages() {
    local package
    local packages=()
    for package in apache2 certbot python3-certbot-apache logrotate; do
        package_is_installed "$package" || packages+=("$package")
    done
    if [ "${#packages[@]}" -gt 0 ]; then
        apt-get update
        apt-get install -y "${packages[@]}"
    fi
    apache_available=true
}

validate_apache_candidate() {
    local path="$1"
    local validator_config
    validator_config="$(mktemp /tmp/pde-igor-apache-validator.XXXXXX)"
    temporary_files+=("$validator_config")
    cat > "$validator_config" <<EOF
ServerRoot /etc/apache2
PidFile /tmp/pde-igor-apache-validator.pid
DefaultRuntimeDir /tmp
Define APACHE_LOG_DIR /var/log/apache2
ServerName localhost
ErrorLog /tmp/pde-igor-apache-validator.log
LogFormat "%h %l %u %t %r %>s %b" combined
User www-data
Group www-data
IncludeOptional ${APACHE_MODS_ENABLED}/*.load
IncludeOptional ${APACHE_MODS_ENABLED}/*.conf
Include ${path}
EOF
    apache2ctl -t -f "$validator_config" >/dev/null || \
        fail "Generated Apache configuration failed validation: ${path}"
}

install_http_vhost() {
    local temporary_file
    if [ "$http_vhost_state" = legacy ] \
        && { [ "$certificate_valid" != true ] || grep -Fqx "    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]" "$HTTP_VHOST_FILE"; }; then
        ensure_file_properties "$HTTP_VHOST_FILE" root root 0644
        return
    fi
    temporary_file="$(mktemp /tmp/pde-igor-http-vhost.XXXXXX)"
    temporary_files+=("$temporary_file")
    render_http_vhost > "$temporary_file"
    chmod 0644 "$temporary_file"
    validate_apache_candidate "$temporary_file"
    commit_rendered_file "$temporary_file" "$HTTP_VHOST_FILE" root root 0644
    [ "$file_changed" = true ] && apache_changed=true
    http_vhost_state=managed
}

install_proxy_configuration() {
    local temporary_file
    temporary_file="$(mktemp /tmp/pde-igor-proxy-conf.XXXXXX)"
    temporary_files+=("$temporary_file")
    render_proxy_config > "$temporary_file"
    chmod 0644 "$temporary_file"
    validate_apache_candidate "$temporary_file"
    commit_rendered_file "$temporary_file" "$PROXY_CONFIG_FILE" root root 0644
    if [ "$file_changed" = true ]; then
        apache_changed=true
    fi
}

ensure_module_enabled() {
    local module="$1"
    local link="${APACHE_MODS_ENABLED}/${module}.load"
    local expected="${APACHE_MODS_AVAILABLE}/${module}.load"
    if path_exists "$link"; then
        [ -L "$link" ] || fail "Apache module enable path is not a symlink: ${link}"
        [ "$(readlink -m "$link")" = "$expected" ] || fail "Apache module link points to an unexpected module: ${link}"
        if [ -e "$link" ]; then
            return
        fi
        rm -f "$link"
    fi
    a2enmod "$module"
    apache_changed=true
}

ensure_site_enabled() {
    local site_name="$1"
    local target_file="$2"
    local link="${APACHE_SITES_ENABLED}/${site_name}"
    if path_exists "$link"; then
        [ -L "$link" ] || fail "Enabled Apache site path is not a symlink: ${link}"
        [ "$(readlink -m "$link")" = "$target_file" ] || fail "Enabled Apache site points somewhere unexpected: ${link}"
        if [ -e "$link" ]; then
            return
        fi
        rm -f "$link"
    fi
    a2ensite "$site_name"
    apache_changed=true
}

disable_broken_certbot_site() {
    local site_name site_link
    if [ "$ssl_vhost_missing_certificate" != true ] || [ "${#ssl_vhosts[@]}" -ne 1 ]; then
        return
    fi
    site_name="$(basename "${ssl_vhosts[0]}")"
    site_link="${APACHE_SITES_ENABLED}/${site_name}"
    if path_exists "$site_link" && [ -e "$site_link" ]; then
        [ -L "$site_link" ] || fail "Enabled Certbot site path is not a symlink: ${site_link}"
        [ "$(readlink -m "$site_link")" = "${ssl_vhosts[0]}" ] || \
            fail "Enabled Certbot site points somewhere unexpected: ${site_link}"
        a2dissite "$site_name"
        apache_changed=true
    fi
}

apply_apache_changes() {
    if [ "$apache_changed" = true ]; then
        apache2ctl configtest
        if systemctl is-active --quiet apache2; then
            systemctl reload apache2
        else
            systemctl start apache2
        fi
        apache_changed=false
    elif ! systemctl is-active --quiet apache2; then
        apache2ctl configtest
        systemctl start apache2
    fi
    if ! systemctl is-enabled apache2 >/dev/null 2>&1; then
        systemctl enable apache2
    fi
}

install_proxy_include() {
    local ssl_vhost="$1"
    local include_line="Include ${PROXY_CONFIG_FILE}"
    local temporary_file candidate count count_in_ssl counts
    local include_count=0 include_in_ssl_vhost=0

    while IFS= read -r candidate; do
        [ -f "$candidate" ] || continue
        counts="$(awk -v include_file="$PROXY_CONFIG_FILE" '
            /^[[:space:]]*<VirtualHost[[:space:]]+\*:443>/ { in_ssl_vhost = 1 }
            {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                if (tolower(line) ~ /^include[[:space:]]/) {
                    split(line, fields, /[[:space:]]+/)
                    target = fields[2]
                    gsub(/"/, "", target)
                    if (target == include_file) {
                        total++
                        if (in_ssl_vhost) in_ssl++
                    }
                }
                if (in_ssl_vhost && /<\/VirtualHost>/) in_ssl_vhost = 0
            }
            END { printf "%d|%d", total, in_ssl }
        ' "$candidate")"
        IFS='|' read -r count count_in_ssl <<< "$counts"
        if [ "$count" -gt 0 ]; then
            [ "$candidate" = "$ssl_vhost" ] || \
                fail "PDE proxy include is referenced by another Apache configuration: ${candidate}"
            include_count=$((include_count + count))
            include_in_ssl_vhost=$((include_in_ssl_vhost + count_in_ssl))
        fi
    done < <(find /etc/apache2 -type f -name '*.conf' -print 2>/dev/null)

    [ "$include_count" -eq 1 ] && [ "$include_in_ssl_vhost" -eq 1 ] && return
    temporary_file="$(mktemp "${ssl_vhost}.tmp.XXXXXX")"
    temporary_files+=("$temporary_file")
    if ! awk -v include_line="$include_line" -v include_file="$PROXY_CONFIG_FILE" '
        /^[[:space:]]*<VirtualHost[[:space:]]+\*:443>/ { in_ssl_vhost = 1 }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (tolower(line) ~ /^include[[:space:]]/) {
                split(line, fields, /[[:space:]]+/)
                target = fields[2]
                gsub(/"/, "", target)
                if (target == include_file) next
            }
            if (in_ssl_vhost && /<\/VirtualHost>/ && !inserted) {
                print "    " include_line
                inserted = 1
            }
            print
            if (in_ssl_vhost && /<\/VirtualHost>/) in_ssl_vhost = 0
        }
        END { if (!inserted) exit 42 }
    ' "$ssl_vhost" > "$temporary_file"; then
        fail "Could not place the PDE proxy include in ${ssl_vhost}."
    fi
    chmod --reference="$ssl_vhost" "$temporary_file"
    chown --reference="$ssl_vhost" "$temporary_file"
    validate_apache_candidate "$temporary_file"
    mv -f "$temporary_file" "$ssl_vhost"
    apache_changed=true
}

install_apache_and_certbot() {
    local module certbot_args ssl_vhost
    install_missing_packages

    apache_changed=false
    for module in "${APACHE_REQUIRED_MODULES[@]}"; do
        ensure_module_enabled "$module"
    done

    install_proxy_configuration
    disable_broken_certbot_site
    install_http_vhost
    ensure_site_enabled "${APP_USER}.conf" "$HTTP_VHOST_FILE"
    if [ "$certificate_valid" = true ] && [ "${#ssl_vhosts[@]}" -eq 1 ]; then
        ssl_vhost="${ssl_vhosts[0]}"
        ensure_site_enabled "$(basename "$ssl_vhost")" "$ssl_vhost"
        install_proxy_include "$ssl_vhost"
    fi
    apply_apache_changes

    if [ "$certificate_valid" != true ] || [ "${#ssl_vhosts[@]}" -eq 0 ]; then
        certbot_args=(--apache --non-interactive --agree-tos --redirect --keep-until-expiring -d "$domain")
        if [ -n "$certificate_lineage" ]; then
            certbot_args+=(--cert-name "$certificate_lineage")
        fi
        if [ -n "${CERTBOT_EMAIL:-}" ]; then
            certbot_args+=(--email "$CERTBOT_EMAIL")
        else
            certbot_args+=(--register-unsafely-without-email)
        fi
        certbot "${certbot_args[@]}"
        inspect_certbot_configuration
    fi

    [ "$certificate_valid" = true ] || fail "Certbot did not provide a currently valid certificate for ${domain}."
    [ "${#ssl_vhosts[@]}" -eq 1 ] || fail "Certbot did not create a single *-le-ssl.conf site for ${domain}."
    ssl_vhost="${ssl_vhosts[0]}"

    ensure_site_enabled "$(basename "$ssl_vhost")" "$ssl_vhost"
    install_proxy_include "$ssl_vhost"
    apache2ctl configtest
    if [ "$apache_changed" = true ]; then
        if systemctl is-active --quiet apache2; then
            systemctl reload apache2
        else
            systemctl start apache2
        fi
    fi
    if ! systemctl is-enabled apache2 >/dev/null 2>&1; then
        systemctl enable apache2
    fi
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
    local database_password owner_secret
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
    require_command systemd-analyze
    require_command visudo
    require_command apt-get
    require_command dpkg-query
    require_command getent
    require_command id
    require_command stat
    require_command awk
    require_command grep
    require_command sed
    require_command tr
    require_command cmp
    require_command cut
    require_command find
    require_command readlink
    require_command install
    require_command chown
    require_command chmod
    require_command mktemp
    require_command ss

    if ! id postgres >/dev/null 2>&1; then
        echo 'The PostgreSQL system user is unavailable.' >&2
        exit 1
    fi

    preflight

    create_user
    if [ "$app_env_exists" = true ]; then
        database_password="$(read_env_value TEQFW_DB__PASSWORD)"
        echo "Preserving existing private configuration and secrets: ${ENV_FILE}"
    else
        database_password="$(generate_secret)"
        owner_secret="$(generate_secret)"
        echo "Creating private configuration: ${ENV_FILE}"
    fi
    create_database "$database_password" "$pg_reset_password"
    if [ "$app_env_exists" != true ]; then
        create_environment_file "$database_password" "$owner_secret"
    fi
    ensure_file_properties "$ENV_FILE" "$APP_USER" "$APP_GROUP" 0600

    install_nvm
    install_systemd_service
    install_deployment_sudoers
    visudo -c >/dev/null
    install_logrotate
    sync_runtime_endpoint
    install_apache_and_certbot

    echo "Environment provisioned for ${APP_USER}."
    echo "Deploy the first release, then run: sudo systemctl start ${SERVICE_NAME}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
