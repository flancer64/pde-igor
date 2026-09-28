#!/usr/bin/env bash
# Prepare the PDE host; application releases are deployed by GitHub Actions.
set -euo pipefail

APP_USER=pde-igor
APP_HOME=/home/$APP_USER
APP_ROOT=$APP_HOME/app/pde
ENV_FILE=$APP_HOME/private/pde/app.env
SERVICE=pde-igor
DOMAIN=''
DB_USER=pde_igor
DB_NAME=pde_igor
UNIT=/etc/systemd/system/$SERVICE.service
SUDOERS=/etc/sudoers.d/$APP_USER
LOGROTATE=/etc/logrotate.d/$SERVICE
HTTP_SITE=/etc/apache2/sites-available/$APP_USER.conf
PROXY_CONF=/etc/apache2/conf-available/$APP_USER-proxy.conf
MARKER='# Managed by scripts/create-user.sh.'
TMP_FILES=()
APACHE_CHANGED=false

cleanup() {
    local file
    for file in "${TMP_FILES[@]}"; do rm -f -- "$file"; done
}
trap cleanup EXIT
fail() { echo "$*" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
new_temp() {
    TEMP_FILE=$(mktemp --suffix="${1:-}")
    TMP_FILES+=("$TEMP_FILE")
}
env_value() {
    local key=$1
    awk -v key="$key" 'index($0,key "=")==1 { n++; v=substr($0,length(key)+2) } END { if(n!=1) exit 1; print v }' "$ENV_FILE"
}
install_private_env() {
    local source=$1 temporary_private
    temporary_private=$(mktemp "${ENV_FILE}.tmp.XXXXXX")
    TMP_FILES+=("$temporary_private")
    install -o "$APP_USER" -g "$APP_USER" -m 0600 "$source" "$temporary_private"
    mv -f "$temporary_private" "$ENV_FILE"
}

usage() {
    echo 'Usage: sudo BASE_URL=https://pde.example.org PORT=3000 [CERTBOT_EMAIL=...] ./scripts/create-user.sh'
}
validate_input() {
    BASE_URL=${BASE_URL:-}
    PORT=${PORT:-}
    local domain_pattern='^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))+$'
    [[ $BASE_URL =~ $domain_pattern ]] || fail 'BASE_URL must be an HTTPS origin with a DNS hostname.'
    DOMAIN=${BASE_URL#https://}
    [[ $PORT =~ ^[0-9]{1,5}$ ]] || fail 'PORT must be an integer from 1024 to 65535.'
    ((10#$PORT >= 1024 && 10#$PORT <= 65535)) || fail 'PORT must be an integer from 1024 to 65535.'
    PORT=$((10#$PORT))
    [ "$(id -u)" -eq 0 ] || fail 'Run as root.'
}

# Existing files are accepted only when their content is compatible. The marker
# is optional for files produced by the original provisioner.
install_config() {
    local path=$1 mode=$2 validator=$3
    if [ "$path" = "$UNIT" ]; then new_temp .service; else new_temp; fi
    cat > "$TEMP_FILE"
    chmod "$mode" "$TEMP_FILE"
    if exists "$path"; then
        [ -f "$path" ] && [ ! -L "$path" ] || fail "Conflicting configuration path: $path"
        [ "$(stat -c %u "$path")" = 0 ] || fail "Configuration is not root-owned: $path"
        if cmp -s "$path" "$TEMP_FILE"; then
            [ "$(stat -c %a "$path")" = "${mode#0}" ] || chmod "$mode" "$path"
            return 1
        fi
        # Accept a previous unmarked version of this exact configuration.
        if ! { tail -n +2 "$TEMP_FILE" | cmp -s "$path" -; }; then
            fail "Existing configuration differs from expected PDE configuration: $path"
        fi
        [ "$(stat -c %a "$path")" = "${mode#0}" ] || chmod "$mode" "$path"
        return 1
    fi
    if [ -n "$validator" ]; then "$validator" "$TEMP_FILE"; fi
    install -o root -g root -m "$mode" "$TEMP_FILE" "$path"
    return 0
}

prepare_account() {
    if id "$APP_USER" >/dev/null 2>&1; then
        [ "$(id -gn "$APP_USER")" = "$APP_USER" ] || fail "Unexpected primary group for $APP_USER"
        [ "$(getent passwd "$APP_USER" | cut -d: -f6)" = "$APP_HOME" ] || fail "Unexpected home for $APP_USER"
    else
        getent group "$APP_USER" >/dev/null && fail "Group $APP_USER exists without its user."
        exists "$APP_HOME" && fail "Home $APP_HOME exists without its user."
        adduser --disabled-password --gecos '' "$APP_USER"
    fi
    local path
    for path in "$APP_HOME" "$APP_HOME/app" "$APP_ROOT" "$APP_ROOT/releases" \
        "$APP_HOME/private" "$APP_HOME/private/pde" "$APP_HOME/private/telegram" \
        "$APP_HOME/data" "$APP_HOME/data/pde" "$APP_HOME/data/telegram" \
        "$APP_HOME/data/telegram/tdlib" "$APP_HOME/log" "$APP_HOME/log/pde" \
        "$APP_HOME/tmp" "$APP_HOME/tmp/deploy"; do
        if exists "$path"; then
            [ -d "$path" ] && [ ! -L "$path" ] || fail "Expected directory: $path"
            [ "$(stat -c %U:%G "$path")" = "$APP_USER:$APP_USER" ] || fail "Unexpected directory owner: $path"
            [ "$(stat -c %a "$path")" = 700 ] || chmod 0700 "$path"
        else
            install -d -o "$APP_USER" -g "$APP_USER" -m 0700 "$path"
        fi
    done
    for path in "$APP_HOME/log/pde/stdout.log" "$APP_HOME/log/pde/stderr.log"; do
        if ! exists "$path"; then install -o "$APP_USER" -g "$APP_USER" -m 0600 /dev/null "$path"; fi
        [ -f "$path" ] && [ ! -L "$path" ] || fail "Expected log file: $path"
        [ "$(stat -c %U:%G "$path")" = "$APP_USER:$APP_USER" ] || fail "Unexpected log file owner: $path"
        [ "$(stat -c %a "$path")" = 600 ] || chmod 0600 "$path"
    done
    local profile=$APP_HOME/.profile
    if ! exists "$profile"; then
        install -o "$APP_USER" -g "$APP_USER" -m 0644 /dev/null "$profile"
    fi
    [ -f "$profile" ] && [ ! -L "$profile" ] || fail "Expected profile file: $profile"
    [ "$(stat -c %U:%G "$profile")" = "$APP_USER:$APP_USER" ] || fail "Unexpected profile owner: $profile"
    if [ -f "$profile" ] && ! grep -Eq '^[[:space:]]*umask[[:space:]]+0?077([[:space:]]|$)' "$profile"; then
        printf '\numask 077\n' >> "$profile"
    fi
}

prepare_database() {
    local role database password owner_secret role_comment public_access
    role=$(sudo -u postgres psql -XAtqc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")
    database=$(sudo -u postgres psql -XAtqc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB_NAME'")
    if exists "$ENV_FILE"; then
        [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || fail "Invalid private configuration: $ENV_FILE"
        [ "$(stat -c %U:%G "$ENV_FILE")" = "$APP_USER:$APP_USER" ] || fail "Unexpected app.env owner."
        [ "$(stat -c %a "$ENV_FILE")" = 600 ] || chmod 0600 "$ENV_FILE"
        for key in PDE_RUNTIME__OWNER_SECRET TEQFW_DB__PASSWORD TEQFW_DB__DATABASE TEQFW_DB__USER; do
            [ -n "$(env_value "$key")" ] || fail "Missing or duplicate $key in $ENV_FILE"
        done
        [ "$(env_value TEQFW_DB__DATABASE)" = "$DB_NAME" ] || fail 'Unexpected database in app.env.'
        [ "$(env_value TEQFW_DB__USER)" = "$DB_USER" ] || fail 'Unexpected database user in app.env.'
        [ "$(env_value TEQFW_DB__HOST)" = 127.0.0.1 ] || fail 'Unexpected database host in app.env.'
        [ "$(env_value TEQFW_DB__PORT)" = 5432 ] || fail 'Unexpected database port in app.env.'
        password=$(env_value TEQFW_DB__PASSWORD)
        if [ "$role" = 1 ]; then
            PGPASSWORD=$password psql -Xw -h 127.0.0.1 -U "$DB_USER" -d postgres -Atqc 'SELECT 1' >/dev/null || fail 'Existing PostgreSQL role does not accept app.env password.'
        fi
    else
        if [ "$role" = 1 ]; then
            role_comment=$(sudo -u postgres psql -XAtqc "SELECT coalesce(shobj_description(oid,'pg_authid'),'') FROM pg_authid WHERE rolname='$DB_USER'")
            [ "$role_comment" = "Managed by scripts/create-user.sh for $APP_USER." ] || fail 'PostgreSQL role exists without app.env; its credentials are unknown.'
        elif [ -n "$database" ]; then
            fail 'PostgreSQL database exists without its role or app.env.'
        fi
        password=$(openssl rand -base64 48 | tr -d '\n')
        owner_secret=$(openssl rand -base64 48 | tr -d '\n')
    fi
    [ -z "$database" ] || [ "$database" = "$DB_USER" ] || fail "Database $DB_NAME is owned by $database."
    if [ "$role" != 1 ]; then
        sudo -u postgres psql -X -v ON_ERROR_STOP=1 -v pass="$password" -v name="$DB_USER" \
            -v marker="Managed by scripts/create-user.sh for $APP_USER." -q <<'SQL'
BEGIN;
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'name', :'pass')
\gexec
SELECT format('COMMENT ON ROLE %I IS %L', :'name', :'marker')
\gexec
COMMIT;
SQL
    elif ! exists "$ENV_FILE"; then
        sudo -u postgres psql -X -v ON_ERROR_STOP=1 -v pass="$password" -v name="$DB_USER" -q <<'SQL'
SELECT format('ALTER ROLE %I PASSWORD %L', :'name', :'pass')
\gexec
SQL
    fi
    if [ -z "$database" ]; then
        sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $DB_NAME OWNER $DB_USER"
    fi
    public_access=$(sudo -u postgres psql -XAtqc "SELECT EXISTS (SELECT 1 FROM pg_database d, LATERAL aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname='$DB_NAME' AND a.grantee=0)")
    if [ "$public_access" = t ]; then
        sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q -c "REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC"
    fi
    if ! exists "$ENV_FILE"; then
        new_temp
        cat > "$TEMP_FILE" <<EOF
# Managed by scripts/create-user.sh. Keep this file private.
PDE_DESK_TELEGRAM__API_HASH=
PDE_DESK_TELEGRAM__API_ID=
PDE_DESK_TELEGRAM__TDLIB_DIRECTORY=$APP_HOME/data/telegram/tdlib

PDE_RUNTIME__ACCESS_TOKEN_TTL_SECONDS=900
PDE_RUNTIME__AUTHORIZATION_CODE_TTL_SECONDS=120
PDE_RUNTIME__AUTHORIZATION_REQUEST_TTL_SECONDS=300
PDE_RUNTIME__BASE_URL=$BASE_URL
PDE_RUNTIME__COOKIE_SECURE=true
PDE_RUNTIME__OWNER_SECRET=$owner_secret
PDE_RUNTIME__OWNER_SESSION_TTL_SECONDS=3600

TEQFW_DB__CLIENT=pg
TEQFW_DB__DATABASE=$DB_NAME
TEQFW_DB__HOST=127.0.0.1
TEQFW_DB__PASSWORD=$password
TEQFW_DB__PORT=5432
TEQFW_DB__USER=$DB_USER

TEQFW_WEB__HOST=127.0.0.1
TEQFW_WEB__PORT=$PORT
TEQFW_WEB__TYPE=http
EOF
        install_private_env "$TEMP_FILE"
    fi
}
sync_env() {
    local key=$1 value=$2 count
    count=$(awk -v key="$key" 'index($0,key "=")==1 {n++} END {print n+0}' "$ENV_FILE")
    [ "$count" -le 1 ] || fail "Duplicate $key in $ENV_FILE"
    if [ "$count" = 1 ] && [ "$(env_value "$key")" = "$value" ]; then return; fi
    new_temp
    if [ "$count" = 1 ]; then
        awk -v key="$key" -v value="$value" 'index($0,key "=")==1 {print key "=" value; next} {print}' "$ENV_FILE" > "$TEMP_FILE"
    else
        cat "$ENV_FILE" > "$TEMP_FILE"
        printf '\n%s=%s\n' "$key" "$value" >> "$TEMP_FILE"
    fi
    install_private_env "$TEMP_FILE"
}

prepare_nvm() {
    if exists "$APP_HOME/.nvm"; then
        [ -d "$APP_HOME/.nvm" ] && [ ! -L "$APP_HOME/.nvm" ] || fail 'NVM path is not a directory.'
        [ "$(stat -c %U:%G "$APP_HOME/.nvm")" = "$APP_USER:$APP_USER" ] || fail 'NVM directory has an unexpected owner.'
    fi
    if exists "$APP_HOME/.nvm/nvm.sh"; then
        [ -f "$APP_HOME/.nvm/nvm.sh" ] && [ ! -L "$APP_HOME/.nvm/nvm.sh" ] || fail 'NVM entry point is not a regular file.'
        [ "$(stat -c %U:%G "$APP_HOME/.nvm/nvm.sh")" = "$APP_USER:$APP_USER" ] || fail 'NVM entry point has an unexpected owner.'
    fi
    if [ -s "$APP_HOME/.nvm/nvm.sh" ]; then return; fi
    sudo -u "$APP_USER" -H bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | PROFILE=/dev/null bash'
    [ -s "$APP_HOME/.nvm/nvm.sh" ] || fail 'NVM installation did not create nvm.sh.'
}

validate_unit() { systemd-analyze verify "$1"; }
validate_sudoers() { visudo -cf "$1"; }
prepare_service() {
    if install_config "$UNIT" 0644 validate_unit <<EOF
$MARKER
[Unit]
Description=PDE Embassy Host for Igor Gusev
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_ROOT/current
Environment="HOME=$APP_HOME"
Environment="NVM_DIR=$APP_HOME/.nvm"
EnvironmentFile=-$ENV_FILE
ExecStart=/bin/bash -c 'set -e; . "\$NVM_DIR/nvm.sh"; nvm use --silent; exec npm start'
Restart=on-failure
RestartSec=5s
TimeoutStopSec=10s
KillMode=control-group
UMask=0077
StandardOutput=append:$APP_HOME/log/pde/stdout.log
StandardError=append:$APP_HOME/log/pde/stderr.log

[Install]
WantedBy=multi-user.target
EOF
    then systemctl daemon-reload; fi
    local unit_link=/etc/systemd/system/multi-user.target.wants/$SERVICE.service
    if exists "$unit_link"; then
        [ -L "$unit_link" ] && [ "$(readlink -m "$unit_link")" = "$UNIT" ] || fail "Conflicting systemd enable link: $unit_link"
    fi
    systemctl is-enabled --quiet "$SERVICE" || systemctl enable "$SERVICE"
    if install_config "$SUDOERS" 0440 validate_sudoers <<EOF
$MARKER
$APP_USER ALL=(root) NOPASSWD: \\
    /bin/systemctl start $SERVICE, \\
    /bin/systemctl stop $SERVICE
EOF
    then :; fi
    visudo -c >/dev/null
    if install_config "$LOGROTATE" 0644 '' <<EOF
$MARKER
$APP_HOME/log/pde/*.log {
    daily
    maxsize 100M
    rotate 14
    compress
    delaycompress
    copytruncate
    su $APP_USER $APP_USER
    missingok
    notifempty
}
EOF
    then :; fi
}

render_http_site() {
    local redirect=$1
    cat <<EOF
$MARKER
<VirtualHost *:80>
    ServerName $DOMAIN
    ErrorLog \${APACHE_LOG_DIR}/$APP_USER.error.log
    CustomLog \${APACHE_LOG_DIR}/$APP_USER.access.log combined
EOF
    if [ "$redirect" = true ]; then
        cat <<EOF
    RewriteEngine on
    RewriteCond %{SERVER_NAME} =$DOMAIN
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
EOF
    fi
    echo '</VirtualHost>'
}
valid_http_site() {
    local error_log="\${APACHE_LOG_DIR}/$APP_USER.error.log"
    local access_log="\${APACHE_LOG_DIR}/$APP_USER.access.log"
    awk -v domain="$DOMAIN" -v error_log="$error_log" -v access_log="$access_log" '
        {
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if ($0 == "" || $1 ~ /^#/) next
            if ($1 == "<VirtualHost") {
                if (opened || closed || NF != 2 || $2 != "*:80>") exit 1
                opened = 1
            } else if ($1 == "</VirtualHost>") {
                if (!opened || closed || NF != 1) exit 1
                closed = 1
            } else if (!opened || closed) {
                exit 1
            } else if ($1 == "ServerName") {
                if (++server != 1 || NF != 2 || $2 != domain) exit 1
            } else if ($1 == "ErrorLog") {
                if (++error != 1 || NF != 2 || $2 != error_log) exit 1
            } else if ($1 == "CustomLog") {
                if (++access != 1 || NF != 3 || $2 != access_log || $3 != "combined") exit 1
            } else if ($1 == "RewriteEngine") {
                if (redirect != 0 || NF != 2 || $2 != "on") exit 1
                redirect = 1
            } else if ($1 == "RewriteCond") {
                if (redirect != 1 || NF != 3 || $2 != "%{SERVER_NAME}" || $3 != "=" domain) exit 1
                redirect = 2
            } else if ($1 == "RewriteRule") {
                if (redirect != 2 || NF != 4 || $2 != "^" ||
                    $3 != "https://%{SERVER_NAME}%{REQUEST_URI}" || $4 != "[END,NE,R=permanent]") exit 1
                redirect = 3
            } else {
                exit 1
            }
        }
        END {
            if (!opened || !closed || server != 1 || error != 1 || access != 1 ||
                (redirect != 0 && redirect != 3)) exit 1
        }
    ' "$HTTP_SITE"
}
ensure_http_site() {
    local redirect=$1
    if exists "$HTTP_SITE"; then
        [ -f "$HTTP_SITE" ] && [ ! -L "$HTTP_SITE" ] || fail "Invalid HTTP site: $HTTP_SITE"
        [ "$(stat -c %u "$HTTP_SITE")" = 0 ] || fail "HTTP site is not root-owned: $HTTP_SITE"
        valid_http_site || fail "Existing HTTP site has unexpected directives: $HTTP_SITE"
        return
    fi
    new_temp
    render_http_site "$redirect" > "$TEMP_FILE"
    install -o root -g root -m 0644 "$TEMP_FILE" "$HTTP_SITE"
    APACHE_CHANGED=true
}
find_ssl_sites() {
    local candidate
    ssl_sites=()
    for candidate in /etc/apache2/sites-available/*-le-ssl.conf; do
        [ -f "$candidate" ] || continue
        if awk -v domain="$DOMAIN" '$1 == "ServerName" && $2 == domain { found = 1 } END { exit !found }' "$candidate"; then
            [ ! -L "$candidate" ] && [ "$(stat -c %u "$candidate")" = 0 ] || fail "Conflicting SSL site file: $candidate"
            ssl_sites+=("$candidate")
        fi
    done
}
install_host_packages() {
    local package
    local missing=()
    for package in apache2 certbot python3-certbot-apache logrotate; do
        dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed || missing+=("$package")
    done
    command -v sudo >/dev/null 2>&1 || missing+=(sudo)
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    if ! command -v psql >/dev/null 2>&1 || ! id postgres >/dev/null 2>&1; then
        missing+=(postgresql)
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        apt-get update
        apt-get install -y "${missing[@]}"
    fi
    for package in sudo psql openssl visudo systemctl systemd-analyze curl apache2ctl; do
        command -v "$package" >/dev/null || fail "Missing command after package installation: $package"
    done
    id postgres >/dev/null 2>&1 || fail 'PostgreSQL system user is missing after package installation.'
}

prepare_apache() {
    local module ssl_site cert_file include_count
    local ssl_sites=()
    for module in rewrite proxy proxy_http2 http2 ssl; do
        if ! a2query -m "$module" >/dev/null 2>&1; then a2enmod "$module"; APACHE_CHANGED=true; fi
    done
    ensure_http_site false
    local site_link=/etc/apache2/sites-enabled/$APP_USER.conf
    if exists "$site_link"; then
        [ -L "$site_link" ] && [ "$(readlink -m "$site_link")" = "$HTTP_SITE" ] || fail "Conflicting enabled HTTP site: $site_link"
    fi
    if ! a2query -s "$APP_USER" >/dev/null 2>&1; then a2ensite "$APP_USER"; APACHE_CHANGED=true; fi
    if ! exists "$PROXY_CONF"; then
        write_proxy
        APACHE_CHANGED=true
    else
        [ -f "$PROXY_CONF" ] && [ ! -L "$PROXY_CONF" ] || fail "Invalid proxy config: $PROXY_CONF"
        [ "$(stat -c %u "$PROXY_CONF")" = 0 ] || fail "Proxy config is not root-owned: $PROXY_CONF"
        local old_port
        old_port=$(sed -n 's@.*h2c://127.0.0.1:\([0-9][0-9]*\)/.*@\1@p' "$PROXY_CONF")
        [[ $old_port =~ ^[0-9]+$ ]] || fail "Unrecognized proxy config: $PROXY_CONF"
        new_temp
        render_proxy "$old_port" > "$TEMP_FILE"
        if ! cmp -s "$TEMP_FILE" "$PROXY_CONF" && ! tail -n +2 "$TEMP_FILE" | cmp -s - "$PROXY_CONF"; then
            fail "Existing proxy config differs from expected PDE configuration: $PROXY_CONF"
        fi
        [ "$(stat -c %a "$PROXY_CONF")" = 644 ] || chmod 0644 "$PROXY_CONF"
        if [ "$old_port" != "$PORT" ]; then
            new_temp
            render_proxy "$PORT" > "$TEMP_FILE"
            install -o root -g root -m 0644 "$TEMP_FILE" "$PROXY_CONF"
            APACHE_CHANGED=true
        fi
    fi
    find_ssl_sites
    [ "${#ssl_sites[@]}" -le 1 ] || fail "Multiple Certbot SSL sites claim $DOMAIN."
    ssl_site=${ssl_sites[0]:-}
    cert_file=''
    if [ -n "$ssl_site" ]; then
        cert_file=$(awk 'tolower($1)=="sslcertificatefile" {print $2; exit}' "$ssl_site")
        if { [ -z "$cert_file" ] || ! openssl x509 -in "$cert_file" -noout -checkhost "$DOMAIN" -checkend 0 >/dev/null 2>&1; } \
            && a2query -s "$(basename "$ssl_site" .conf)" >/dev/null 2>&1; then
            site_link=/etc/apache2/sites-enabled/$(basename "$ssl_site")
            [ -L "$site_link" ] && [ "$(readlink -m "$site_link")" = "$ssl_site" ] || fail "Conflicting enabled HTTPS site: $site_link"
            a2dissite "$(basename "$ssl_site")"
            APACHE_CHANGED=true
        fi
    fi
    apache2ctl configtest
    if systemctl is-active --quiet apache2; then
        [ "$APACHE_CHANGED" = false ] || systemctl reload apache2
    else systemctl start apache2; fi
    systemctl is-enabled --quiet apache2 || systemctl enable apache2
    APACHE_CHANGED=false

    if [ -z "$ssl_site" ] || [ -z "$cert_file" ] || ! openssl x509 -in "$cert_file" -noout -checkhost "$DOMAIN" -checkend 0 >/dev/null 2>&1; then
        local args=(--apache --non-interactive --agree-tos --redirect --keep-until-expiring -d "$DOMAIN")
        if [ -n "${CERTBOT_EMAIL:-}" ]; then args+=(--email "$CERTBOT_EMAIL"); else args+=(--register-unsafely-without-email); fi
        certbot "${args[@]}"
        find_ssl_sites
        [ "${#ssl_sites[@]}" -eq 1 ] || fail "Certbot did not leave one SSL site for $DOMAIN."
        ssl_site=${ssl_sites[0]}
    fi
    [ -n "$ssl_site" ] || fail "Certbot SSL site is missing for $DOMAIN"
    [ "$(grep -Ec '^[[:space:]]*<VirtualHost[[:space:]]' "$ssl_site")" -eq 1 ] || fail "Expected one HTTPS virtual host in $ssl_site"
    cert_file=$(awk 'tolower($1)=="sslcertificatefile" {print $2; exit}' "$ssl_site")
    [ -n "$cert_file" ] && openssl x509 -in "$cert_file" -noout -checkhost "$DOMAIN" -checkend 0 >/dev/null 2>&1 || fail "Invalid certificate for $DOMAIN"
    ensure_http_site true
    site_link=/etc/apache2/sites-enabled/$(basename "$ssl_site")
    if exists "$site_link"; then
        [ -L "$site_link" ] && [ "$(readlink -m "$site_link")" = "$ssl_site" ] || fail "Conflicting enabled HTTPS site: $site_link"
    fi
    if ! a2query -s "$(basename "$ssl_site" .conf)" >/dev/null 2>&1; then a2ensite "$(basename "$ssl_site")"; APACHE_CHANGED=true; fi
    include_count=$(awk -v path="$PROXY_CONF" '
        /^[[:space:]]*<VirtualHost[[:space:]]+\*:443>/ { ssl = 1 }
        $1 == "Include" && $2 == path { total++; if (ssl) inside++ }
        /^[[:space:]]*<\/VirtualHost>/ { ssl = 0 }
        END { if (total + 0 == inside + 0) print total + 0; else print "outside" }
    ' "$ssl_site")
    if [ "$include_count" = 0 ]; then
        new_temp
        awk -v include_line="    Include $PROXY_CONF" '/<\/VirtualHost>/ && !done {print include_line; done=1} {print}' "$ssl_site" > "$TEMP_FILE"
        install -o root -g root -m 0644 "$TEMP_FILE" "$ssl_site"
        APACHE_CHANGED=true
    elif [ "$include_count" != 1 ]; then fail "Proxy include is duplicated or outside the HTTPS virtual host: $ssl_site"; fi
    apache2ctl configtest
    if [ "$APACHE_CHANGED" = true ]; then systemctl reload apache2; fi
}
render_proxy() {
    local proxy_port=$1
    cat <<EOF
$MARKER
ErrorLog \${APACHE_LOG_DIR}/$APP_USER-ssl.error.log
CustomLog \${APACHE_LOG_DIR}/$APP_USER-ssl.access.log combined
Protocols h2 http/1.1
RewriteEngine on
RewriteRule "^/(.*)$" "h2c://127.0.0.1:$proxy_port/\$1" [P]
EOF
}
write_proxy() {
    new_temp
    render_proxy "$PORT" > "$TEMP_FILE"
    install -o root -g root -m 0644 "$TEMP_FILE" "$PROXY_CONF"
}

main() {
    if [ "${1:-}" = --help ]; then usage; return; fi
    validate_input
    install_host_packages
    prepare_account
    prepare_database
    prepare_nvm
    prepare_service
    prepare_apache
    sync_env PDE_RUNTIME__BASE_URL "$BASE_URL"
    sync_env TEQFW_WEB__PORT "$PORT"
    echo "Host provisioned for $APP_USER. Run the GitHub Actions deployment workflow."
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
