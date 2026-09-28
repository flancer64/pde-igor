#!/usr/bin/env bash

# Exercise recovery from the files emitted by the original provisioning script.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/create-user.sh"

fixture_dir="$(mktemp -d)"
trap 'rm -rf -- "$fixture_dir"' EXIT
git show b6b38a4:scripts/create-user.sh > "${fixture_dir}/original.sh"

base_url='https://igor.pde.wiredgeese.com'
domain="${base_url#https://}"
port=4028
app_env_exists=true
existing_install=true
certificate_valid=true
test_owner="$(id -un)"
test_group="$(id -gn)"
original_env_file="${fixture_dir}/app.env"

# Fixtures are unprivileged files; production preflight still checks root ownership.
assert_root_owned_regular_file() {
    [ -f "$1" ] && [ ! -L "$1" ]
}

read_env_value() {
    awk -v key="$1" '
        index($0, key "=") == 1 { count++; value = substr($0, length(key) + 2) }
        END { if (count != 1) exit 1; print value }
    ' "$original_env_file"
}

inspect_postgres() {
    pg_role_exists=true
    pg_database_exists=true
    pg_role_can_login=true
    pg_role_marked=false
    pg_database_marked=false
    pg_role_comment_null=true
    pg_database_comment_null=true
    pg_database_owner="$DB_USER"
}

psql() {
    [ "${PGPASSWORD:-}" = "$(read_env_value TEQFW_DB__PASSWORD)" ] || return 1
    printf '%s\n' "$DB_USER"
}

original_heredoc() {
    local function_name="$1" opener="$2"
    printf 'cat <<EOF\n'
    awk -v function_name="${function_name}() {" -v opener="$opener" '
        $0 == function_name { in_function = 1; next }
        in_function && index($0, opener) { in_heredoc = 1; next }
        in_heredoc && $0 == "EOF" { exit }
        in_heredoc { print }
    ' "${fixture_dir}/original.sh"
    printf 'EOF\n'
}

database_password='existing-database-password'
owner_secret='existing-owner-secret'
eval "$(original_heredoc create_environment_file 'cat > "$ENV_FILE" <<EOF')" > "$original_env_file"
grep -Fqx '# Managed by scripts/create-user.sh. Keep this file private.' "$original_env_file"
[ "$(read_env_value TEQFW_WEB__PORT)" = 4028 ]
inspect_postgres_state
[ "$pg_reset_password" = false ]
[ "$pg_fix_database_owner" = false ]

check_migration() {
    local fixture="$1" legacy_renderer="$2" managed_renderer="$3" mode="$4"
    local candidate="${fixture}.candidate"
    [ "$(classify_managed_file "$fixture" "$legacy_renderer" "legacy fixture")" = legacy ]
    "$managed_renderer" > "$candidate"
    commit_rendered_file "$candidate" "$fixture" "$test_owner" "$test_group" "$mode"
    [ "$file_changed" = true ]
    grep -Fqx "$MANAGED_MARKER" "$fixture"
    [ "$(classify_managed_file "$fixture" "$legacy_renderer" "managed fixture")" = managed ]
    "$managed_renderer" > "$candidate"
    commit_rendered_file "$candidate" "$fixture" "$test_owner" "$test_group" "$mode"
    [ "$file_changed" = false ]
}

eval "$(original_heredoc install_systemd_service 'cat > "/etc/systemd/system/')" > "${fixture_dir}/service"
check_migration "${fixture_dir}/service" render_legacy_systemd_service render_systemd_service 0644

eval "$(original_heredoc install_deployment_sudoers 'cat > "$temporary_file" <<EOF')" > "${fixture_dir}/sudoers"
check_migration "${fixture_dir}/sudoers" render_legacy_sudoers_file render_sudoers_file 0440

eval "$(original_heredoc install_logrotate 'cat > "/etc/logrotate.d/')" > "${fixture_dir}/logrotate"
check_migration "${fixture_dir}/logrotate" render_legacy_logrotate_file render_logrotate_file 0644

eval "$(original_heredoc install_apache_and_certbot 'cat > "$http_vhost" <<EOF')" > "${fixture_dir}/http"
is_expected_legacy_http_vhost "${fixture_dir}/http"
sed -i '$d' "${fixture_dir}/http"
cat >> "${fixture_dir}/http" <<EOF
    RewriteEngine on
    RewriteCond %{SERVER_NAME} =${domain}
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>
EOF
is_expected_legacy_http_vhost "${fixture_dir}/http"
render_http_vhost > "${fixture_dir}/http.candidate"
commit_rendered_file "${fixture_dir}/http.candidate" "${fixture_dir}/http" "$test_owner" "$test_group" 0644
[ "$file_changed" = true ]
grep -Fqx "$MANAGED_MARKER" "${fixture_dir}/http"
render_http_vhost > "${fixture_dir}/http.candidate"
commit_rendered_file "${fixture_dir}/http.candidate" "${fixture_dir}/http" "$test_owner" "$test_group" 0644
[ "$file_changed" = false ]

eval "$(original_heredoc install_apache_and_certbot 'cat > "$proxy_config" <<EOF')" > "${fixture_dir}/proxy"
[ "$(classify_managed_file "${fixture_dir}/proxy" render_legacy_proxy_config 'original proxy')" = managed ]
sed -i '1d' "${fixture_dir}/proxy"
[ "$(classify_managed_file "${fixture_dir}/proxy" render_legacy_proxy_config 'unmarked original proxy')" = legacy ]
port=4030
check_migration "${fixture_dir}/proxy" render_legacy_proxy_config render_proxy_config 0644
grep -Fq 'h2c://127.0.0.1:4030/$1' "${fixture_dir}/proxy"

printf 'unrelated configuration\n' > "${fixture_dir}/unrelated"
if (classify_managed_file "${fixture_dir}/unrelated" render_legacy_proxy_config 'unrelated fixture' >/dev/null 2>&1); then
    printf 'An unrelated proxy configuration was incorrectly adopted.\n' >&2
    exit 1
fi

printf 'Original provisioning file recovery: OK\n'
