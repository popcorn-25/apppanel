#!/bin/sh
set -eu

# sudo 受限环境下 PATH 可能缺 /usr/sbin 等，导致 runuser/ss 等明明存在却报缺失；
# 先补齐再做任何命令检查。
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Manage a verified binary release. The deployed application lives entirely in
# <install-directory>/apppanel; systemd unit definitions are the only host files.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_reset=$(printf '\033[0m')
  c_blue=$(printf '\033[1;34m')
  c_green=$(printf '\033[1;32m')
  c_yellow=$(printf '\033[1;33m')
  c_red=$(printf '\033[1;31m')
else
  c_reset='' c_blue='' c_green='' c_yellow='' c_red=''
fi

line() { printf '%s\n' '------------------------------------------------------------'; }
info() { printf "${c_blue}[INFO]${c_reset} %s\n" "$*"; }
success() { printf "${c_green}[ OK ]${c_reset} %s\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %s\n" "$*" >&2; }
fail() { printf "${c_red}[FAIL]${c_reset} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${c_blue}==>${c_reset} %s\n" "$*"; }

banner() {
  printf "\n${c_blue}AppPanel${c_reset} 安装与管理脚本\n"
  printf 'GitHub Releases 二进制安装 · SHA-256 完整性校验\n'
  line
}

require_commands() {
  for command in curl tar sha256sum systemctl getent id apt-get runuser env; do
    command -v "$command" >/dev/null 2>&1 || fail "缺少必要命令: $command"
  done
}

ensure_postgresql_client() {
  # 占位空函数：PostgreSQL 服务端版本由面板按需安装（postgresql-<版本> 包自带
  # 同版本客户端），连外部库缺客户端时后端会明确报错“请安装 postgresql-client”。
  # 此处故意不做任何 apt 操作，避免第三方源故障拖死面板安装/更新。
  return
}

if [ "$(id -u)" -ne 0 ]; then
  fail "请使用 root 运行此脚本"
fi

stop_and_disable() {
  systemctl disable --now "$1" >/dev/null 2>&1 || true
}

confirm() {
  [ "${APPPANEL_ASSUME_YES:-0}" = "1" ] && return 0
  printf '%s [y/N] ' "$1" >&2
  read -r answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

prompt_value() {
  label=$1
  default=${2:-}
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  read -r value
  printf '%s\n' "${value:-$default}"
}

prompt_password() {
  while :; do
    printf '登录密码（至少 8 位）: ' >&2
    stty -echo
    read -r password
    stty echo
    printf '\n' >&2
    printf '确认登录密码: ' >&2
    stty -echo
    read -r confirm_password
    stty echo
    printf '\n' >&2
    [ "$password" = "$confirm_password" ] || { echo "两次输入的密码不一致" >&2; continue; }
    [ "${#password}" -ge 8 ] || { echo "密码至少需要 8 位" >&2; continue; }
    printf '%s\n' "$password"
    return
  done
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

validate_parent_dir() {
  value=$(printf '%s' "$1" | sed 's:/*$::')
  [ -n "$value" ] || value=/
  case "$value" in
    /*) ;;
    *) echo "安装目录必须是绝对路径" >&2; exit 1 ;;
  esac
  [ "$value" != "/" ] || { echo "安装目录不能是根目录 /" >&2; exit 1; }
  printf '%s\n' "$value"
}

service_root() {
  sed -n 's/^Environment=APPPANEL_ROOT=//p' /etc/systemd/system/apppanel.service 2>/dev/null | head -n 1
}

github_repository_from_release_url() {
  printf '%s\n' "$1" | sed -n 's#^https://github\.com/\([^/]*\)/\([^/]*\)/releases/download/.*#\1/\2#p'
}

latest_github_release() {
  repository=$1
  response=$(curl -fsSL --retry 3 --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: AppPanel-Installer' \
    "https://api.github.com/repos/$repository/releases/latest") || {
      fail "无法从 GitHub 检测最新版本: $repository"
    }
  tag=$(printf '%s' "$response" | tr '\n' ' ' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$tag" ] || fail "GitHub 最新发行版未包含 tag_name"
  printf '%s\n' "$tag"
}

valid_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$'
}

valid_ipv4() (
  value=$1
  case "$value" in
    *[!0-9.]*|'') return 1 ;;
  esac
  old_ifs=$IFS
  IFS=.
  set -- $value
  IFS=$old_ifs
  [ "$#" -eq 4 ] || return 1
  for octet in "$@"; do
    [ -n "$octet" ] && [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] || return 1
  done
)

public_ipv4() {
  for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
    if candidate=$(curl -4 -fsS --max-time 5 "$endpoint" 2>/dev/null | sed 's/[[:space:]]//g'); then
      if valid_ipv4 "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

kill_port_listeners() {
  # 结束监听指定端口的用户态进程：先 SIGTERM，5 秒后仍在则 SIGKILL。
  # PID 1 与脚本自身永不触碰。成功释放返回 0，仍被占用返回 1。
  port=$1
  pids=$(ss -ltnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9][0-9]*' | cut -d= -f2 | sort -u)
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    case "$pid" in 1|"$$") continue ;; esac
    if [ -r "/proc/$pid/comm" ]; then
      info "结束进程 $pid ($(cat "/proc/$pid/comm"))"
    else
      info "结束进程 $pid"
    fi
    kill "$pid" 2>/dev/null || true
  done
  waits=0
  while [ "$waits" -lt 5 ] && ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; do
    sleep 1
    waits=$((waits + 1))
  done
  survivors=$(ss -ltnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9][0-9]*' | cut -d= -f2 | sort -u)
  # shellcheck disable=SC2086
  for pid in $survivors; do
    case "$pid" in 1|"$$") continue ;; esac
    warn "进程 $pid 未响应终止信号，强制结束"
    kill -9 "$pid" 2>/dev/null || true
  done
  waits=0
  while [ "$waits" -lt 5 ] && ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; do
    sleep 1
    waits=$((waits + 1))
  done
  if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    return 1
  fi
}

ensure_port_available() {
  port=$1
  purpose=${2:-面板}
  command -v ss >/dev/null 2>&1 || return 0
  if ! ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    return 0
  fi
  warn "$purpose 所需端口 $port 已被占用，当前监听进程："
  ss -ltnp "sport = :$port" >&2 || true
  offer_kill=0
  if [ "${APPPANEL_KILL_PORT_CONFLICTS:-0}" = "1" ]; then
    offer_kill=1
  elif [ -t 0 ]; then
    if confirm "是否强制结束上述进程并继续安装？"; then
      offer_kill=1
    fi
  fi
  if [ "$offer_kill" -ne 1 ]; then
    fail "请停止占用端口 $port 的进程，或为 $purpose 选择其他端口"
  fi
  step "强制结束占用端口 $port 的进程"
  if kill_port_listeners "$port"; then
    success "端口 $port 已释放，继续安装"
  else
    ss -ltnp "sport = :$port" >&2 || true
    fail "端口 $port 仍被占用，请手动处理后重试"
  fi
}

validate_panel_port() {
  port=$1
  case "$port" in
    80) fail "端口 80 由 Caddy HTTP 站点服务保留，请为 AppPanel 内部服务选择其他端口" ;;
    443) fail "端口 443 由 Caddy HTTPS 站点服务保留，请为 AppPanel 内部服务选择其他端口" ;;
    2020) fail "端口 2020 由 AppPanel 访问日志服务保留，请为面板内部服务选择其他端口" ;;
  esac
}

write_initial_config() {
  root=$1
  port=$2
  config_file="$root/config.yaml"
  [ -f "$config_file" ] && return

  root_value=$(yaml_escape "$root")
  {
    printf '%s\n' 'app_env: production'
    printf 'http_addr: "0.0.0.0:%s"\n' "$port"
    printf 'data_dir: "%s/data"\n' "$root_value"
    printf 'database_path: "%s/data/apppanel.db"\n' "$root_value"
    printf '%s\n' 'caddy:'
    printf '  admin_url: "unix://%s/run/caddy/admin.sock"\n' "$root_value"
    printf '%s\n' '  timeout: "10s"'
    printf '  panel_upstream: "127.0.0.1:%s"\n' "$port"
    printf '%s\n' '  log_target: "127.0.0.1:2020"'
    printf '  static_root: "%s/sites"\n' "$root_value"
    printf '%s\n' 'log_listen: "127.0.0.1:2020"'
    printf '%s\n' 'session_ttl: "24h"'
    printf '%s\n' 'cookie_secure: false'
  } > "$config_file"
  chown root:root "$config_file"
  chmod 0600 "$config_file"
}

migrate_control_plane_config() {
  root=$1
  config_file="$root/config.yaml"
  [ -f "$config_file" ] || return 0
  if grep -Fq 'admin_url: "http://127.0.0.1:2019"' "$config_file"; then
    temporary=$(mktemp "$root/.config.yaml.XXXXXX")
    sed "s|admin_url: \"http://127.0.0.1:2019\"|admin_url: \"unix://$root/run/caddy/admin.sock\"|" "$config_file" > "$temporary"
    chown root:root "$temporary"
    chmod 0600 "$temporary"
    mv -f "$temporary" "$config_file"
  fi
  chown root:root "$config_file"
  chmod 0600 "$config_file"
}

write_unit() {
  template=$1
  target=$2
  root=$3
  sed "s|%APPPANEL_ROOT%|$root|g" "$template" > "$target"
}

restart_services() {
  step "重启 AppPanel 服务"
  systemctl daemon-reload
  validate_installed_caddy_config
  systemctl enable apppanel-agent caddy apppanel >/dev/null
  for service in apppanel-agent caddy apppanel; do
    restart_install_service "$service"
    success "$service 服务已启动"
  done
}

run_caddy_as_service_user() {
  runuser -u caddy -g caddy -G apppanel -- env \
    APPPANEL_ROOT="$root" \
    HOME="$root/caddy" \
    XDG_DATA_HOME="$root/caddy/data" \
    XDG_CONFIG_HOME="$root/caddy/config" \
    "$root/caddy/caddy" "$@"
}

diagnose_install_service_failure() {
  service=$1
  reason=$2
  install -d -m 0700 -o root -g root "$(dirname "$diagnostic_log")" 2>/dev/null || true
  {
    printf '%s\n' '=== AppPanel 安装失败诊断 ==='
    printf '时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '安装开始: %s\n' "$install_started_at"
    printf '安装目录: %s\n' "$root"
    printf '\n原因: %s\n' "$reason"
    printf '\n--- systemctl status %s ---\n' "$service"
    systemctl status "$service" --no-pager -l -n 0 || true
    printf '\n--- 本次安装期间的 %s 启动错误/警告 ---\n' "$service"
    journalctl -u "$service" --since "$install_started_at" --no-pager -o short-iso --grep='level":"(error|warn)"|Failed|failed|exit-code|permission denied|address already in use' || true
    printf '\n--- %s 最近日志 ---\n' "$service"
    journalctl -u "$service" --since "$install_started_at" --no-pager -o short-iso -n 100 || true
    if [ "$service" = "caddy" ]; then
      printf '\n--- Caddy 二进制 ---\n'
      "$root/caddy/caddy" version || true
      printf '\n--- Caddy 配置校验 ---\n'
      run_caddy_as_service_user validate --config "$root/caddy/Caddyfile" --adapter caddyfile || true
      printf '\n--- 监听端口（80/443/2019） ---\n'
      ss -ltnp '( sport = :80 or sport = :443 or sport = :2019 )' || true
    fi
    if [ "$service" = "apppanel" ]; then
      printf '\n--- AppPanel 配置文件与目录权限 ---\n'
      ls -ld "$root" "$root/bin" "$root/data" "$root/config.yaml" "$root/bin/apppanel" || true
      printf '\n--- AppPanel 监听端口 ---\n'
      ss -ltnp || true
    fi
  } > "$diagnostic_log" 2>&1 || true
  chmod 0600 "$diagnostic_log" 2>/dev/null || true
  echo "安装诊断已保存: $diagnostic_log" >&2
}

wait_for_panel_endpoint() {
  port=$1
  expected=$2
  attempts=${3:-60}
  while [ "$attempts" -gt 0 ]; do
    if ! systemctl is-active --quiet apppanel; then
      diagnose_install_service_failure apppanel "等待面板就绪期间服务退出"
      fail "apppanel 服务在等待就绪期间退出；请提供诊断文件: $diagnostic_log"
    fi
    response=$(curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/api/v1/install/status" 2>/dev/null || true)
    if printf '%s' "$response" | grep -Fq "$expected"; then
      return 0
    fi
    attempts=$((attempts - 1))
    [ "$attempts" -gt 0 ] && sleep 1
  done
  diagnose_install_service_failure apppanel "面板就绪接口在端口 $port 超时"
  fail "面板未在端口 $port 就绪；请提供诊断文件: $diagnostic_log"
}

validate_installed_caddy_config() {
  if ! run_caddy_as_service_user validate --config "$root/caddy/Caddyfile" --adapter caddyfile; then
    diagnose_install_service_failure caddy "Caddy 配置预检失败"
    fail "Caddy 配置预检失败；请提供诊断文件: $diagnostic_log"
  fi
}

restart_install_service() {
  service=$1
  if ! systemctl restart "$service"; then
    diagnose_install_service_failure "$service" "systemctl restart 返回非零"
    fail "服务启动失败: $service；请提供诊断文件: $diagnostic_log"
  fi
  if ! systemctl is-active --quiet "$service"; then
    diagnose_install_service_failure "$service" "systemctl restart 后服务未处于 active 状态"
    fail "服务未进入 active 状态: $service；请提供诊断文件: $diagnostic_log"
  fi
}

bootstrap_admin() {
  root=$1
  port=$2
  login_name=$3
  login_password=$4
  [ -f "$root/data/apppanel.db" ] && return
  command -v curl >/dev/null || return
  info "等待面板服务监听 127.0.0.1:$port"
  wait_for_panel_endpoint "$port" '"installed":false' 60
  account=$(json_escape "$login_name")
  password=$(json_escape "$login_password")
  payload=$(printf '{"dataDir":"%s/data","adminUrl":"unix://%s/run/caddy/admin.sock","panelUpstream":"127.0.0.1:%s","logListen":"127.0.0.1:2020","logTarget":"127.0.0.1:2020","staticRoot":"%s/sites","panelDomain":"","siteName":"AppPanel","adminName":"系统管理员","adminEmail":"%s","adminPassword":"%s","cookieSecure":false}' "$(json_escape "$root")" "$(json_escape "$root")" "$port" "$(json_escape "$root")" "$account" "$password")
  if ! response=$(curl -sS -X POST "http://127.0.0.1:$port/api/v1/install" -H 'Content-Type: application/json' --data "$payload" -w '\n%{http_code}'); then
    fail "管理员初始化请求失败，请检查：journalctl -u apppanel -n 100"
  fi
  http_status=$(printf '%s\n' "$response" | sed -n '$p')
  response_body=$(printf '%s\n' "$response" | sed '$d')
  case "$http_status" in
    2??) ;;
    *) fail "管理员初始化失败（HTTP $http_status）：${response_body:-服务未返回错误详情}" ;;
  esac
  systemctl restart apppanel
  wait_for_panel_endpoint "$port" '"installed":true' 30
  success "管理员已初始化，apppanel 服务已进入运行模式"
}

install_or_update() {
  mode=$1
  release_url=${APPPANEL_RELEASE_URL:-}
  repository=popcorn-25/apppanel
  version=${APPPANEL_VERSION:-}
  version=${version#v}
  panel_port=${APPPANEL_PORT:-}
  admin_login=${APPPANEL_ADMIN:-}
  admin_password=${APPPANEL_PASSWORD:-}
  install_dir=${APPPANEL_INSTALL_DIR:-}

  require_commands

  ensure_postgresql_client

  if [ "$mode" = "install" ]; then
    step "配置安装参数"
    [ -n "$install_dir" ] || install_dir=$(prompt_value "安装目录（AppPanel 将安装到此目录下的 apppanel）" "/home")
    install_dir=$(validate_parent_dir "$install_dir")
    root="$install_dir/apppanel"
    [ ! -e "$root" ] || {
      echo "安装目录已存在: $root" >&2
      echo "若这是未完成的首次安装，请执行：sh install.sh uninstall --purge，然后重新安装" >&2
      exit 1
    }
    [ -n "$panel_port" ] || panel_port=$(prompt_value "AppPanel 内部服务端口" "18081")
    case "$panel_port" in *[!0-9]*|'') echo "端口必须是 1-65535 的整数" >&2; exit 1;; esac
    [ "$panel_port" -ge 1 ] && [ "$panel_port" -le 65535 ] || { echo "端口必须是 1-65535" >&2; exit 1; }
    validate_panel_port "$panel_port"
    ensure_port_available "$panel_port" "面板"
    ensure_port_available 80 "Caddy HTTP"
    ensure_port_available 443 "Caddy HTTPS"
    [ -n "$admin_login" ] || admin_login=$(prompt_value "登录账号（作为邮箱使用）" "admin@localhost")
    [ -n "$admin_login" ] || { echo "登录账号不能为空" >&2; exit 1; }
    [ -n "$admin_password" ] || admin_password=$(prompt_password)
  else
    root=${APPPANEL_ROOT:-}
    [ -n "$root" ] || root=$(service_root)
    [ -n "$root" ] && [ -x "$root/bin/apppanel" ] || { echo "未检测到已安装的 AppPanel；请设置 APPPANEL_ROOT 或选择安装面板" >&2; exit 1; }
  fi

  install_started_at=$(date '+%Y-%m-%d %H:%M:%S')
  diagnostic_log="${APPPANEL_INSTALL_DIAGNOSTIC_LOG:-$root/data/install-diagnostics/install-$(date '+%Y%m%d-%H%M%S').log}"

  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "不支持的 CPU 架构: $(uname -m)" >&2; exit 1 ;;
  esac
  step "检测最新发行版"
  if [ -z "$version" ]; then
    release_tag=$(latest_github_release "$repository")
    version=${release_tag#v}
  else
    release_tag="v$version"
  fi
  valid_version "$version" || fail "发行版本无效: $version"
  if [ -z "$release_url" ]; then
    release_url="https://github.com/$repository/releases/download/$release_tag"
  fi
  if [ "$mode" = "update" ] && [ -f "$root/VERSION" ] && [ "$(cat "$root/VERSION")" = "$version" ]; then
    success "AppPanel 已是最新版本: $version"
    return
  fi

  name="apppanel_${version}_linux_${arch}"
  archive="$name.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  base=${release_url%/}
  info "目标版本: $version"
  info "安装目录: $root"
  step "下载并校验发行包"
  curl -fL --retry 3 --retry-delay 2 "$base/$archive" -o "$tmp/$archive"
  curl -fL --retry 3 --retry-delay 2 "$base/$archive.sha256" -o "$tmp/$archive.sha256"
  (cd "$tmp" && sha256sum -c "$archive.sha256")
  tar -xzf "$tmp/$archive" -C "$tmp"
  package="$tmp/$name"
  [ -f "$package/VERSION" ] || fail "发行包缺少 VERSION"
  [ "$(cat "$package/VERSION")" = "$version" ] || fail "发行包版本与请求版本不一致"
  for path in \
    bin/apppanel \
    bin/apppanel-agent \
    libexec/apppanel-php \
    libexec/apppanel-runtime \
    libexec/apppanel-database \
    libexec/apppanel-docker \
    libexec/apppanel-update \
    systemd/apppanel.service \
    systemd/apppanel-agent.service \
    systemd/caddy.service \
    systemd/apppanel-docker-bridge-guard.service \
    caddy/Caddyfile \
    caddy/caddy \
    caddy/caddy.sha256 \
    caddy/BUILD.json; do
    [ -f "$package/$path" ] || fail "发行包缺少 $path"
  done
  (cd "$package/caddy" && sha256sum -c caddy.sha256) || fail "定制 Caddy 校验失败"
  modules=$("$package/caddy/caddy" list-modules) || fail "无法读取定制 Caddy 模块"
  printf '%s\n' "$modules" | grep -qx 'http.handlers.apppanel_waf' || fail "定制 Caddy 缺少 AppPanel WAF 模块"
  printf '%s\n' "$modules" | grep -qx 'http.handlers.lua_waf' || fail "定制 Caddy 缺少旧配置兼容模块"
  printf '%s\n' "$modules" | grep -qx 'http.handlers.rate_limit' || fail "定制 Caddy 缺少限流模块"
  release_helpers=""
  for source in "$package"/libexec/*; do
    [ -f "$source" ] || continue
    helper=${source##*/}
    printf '%s\n' "$helper" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || fail "发行包包含无效工具名称: $helper"
    release_helpers="$release_helpers $helper"
  done

  if [ "$mode" = "install" ]; then
    step "再次确认服务端口"
    ensure_port_available "$panel_port" "面板"
    ensure_port_available 80 "Caddy HTTP"
    ensure_port_available 443 "Caddy HTTPS"
  fi

  step "安装 AppPanel $version"
  getent group apppanel >/dev/null 2>&1 || groupadd --system --gid 1999 apppanel
  id apppanel >/dev/null 2>&1 || useradd --system --gid apppanel --home-dir "$root" --shell /usr/sbin/nologin apppanel
  getent group apppanel-workload >/dev/null 2>&1 || groupadd --system apppanel-workload
  id apppanel-workload >/dev/null 2>&1 || useradd --system --gid apppanel-workload --home-dir "$root/projects" --shell /usr/sbin/nologin apppanel-workload
  getent group caddy >/dev/null 2>&1 || groupadd --system caddy
  id caddy >/dev/null 2>&1 || useradd --system --gid caddy --home-dir "$root/caddy" --shell /usr/sbin/nologin caddy
  install -d -m 0751 -o root -g apppanel "$root"
  install -d -m 0750 -o root -g root "$root/bin" "$root/libexec"
  install -d -m 0755 -o root -g root "$root/run" "$root/node" "$root/go" "$root/mysql" "$root/mariadb" "$root/docker"
  install -d -m 0700 -o root -g root "$root/data"
  install -d -m 0755 -o root -g apppanel "$root/sites"
  install -d -m 0750 -o apppanel-workload -g apppanel-workload "$root/projects"
  install -d -m 0750 -o root -g caddy "$root/caddy"
  install -d -m 0755 -o root -g root "$root/run/php"
  install -d -m 0700 -o caddy -g caddy "$root/run/caddy"
  install -d -m 0750 -o caddy -g caddy "$root/caddy/data" "$root/caddy/config"
  install -m 0755 "$package/bin/apppanel" "$root/bin/apppanel"
  install -m 0755 "$package/bin/apppanel-agent" "$root/bin/apppanel-agent"
  for helper in $release_helpers; do
    install -m 0755 "$package/libexec/$helper" "$root/libexec/$helper"
  done
  APPPANEL_DATA_DIR="$root/data" "$root/libexec/apppanel-database" migrate-state
  install -m 0640 "$package/caddy/Caddyfile" "$root/caddy/Caddyfile"
  install -m 0750 "$package/caddy/caddy" "$root/caddy/caddy"
  install -m 0644 "$package/caddy/caddy.sha256" "$root/caddy/caddy.sha256"
  install -m 0644 "$package/caddy/BUILD.json" "$root/caddy/BUILD.json"
  chown root:root "$root/bin" "$root/libexec"
  chown root:root "$root/data"
  chown -R root:root "$root/data"
  chown root:apppanel "$root" "$root/sites"
  chown root:caddy "$root/caddy"
  chown -R apppanel-workload:apppanel-workload "$root/projects"
  chown -R caddy:caddy "$root/caddy/data" "$root/caddy/config" "$root/run/caddy"
  chown root:root \
    "$root/bin/apppanel" \
    "$root/bin/apppanel-agent" \
    "$root/caddy/caddy.sha256" \
    "$root/caddy/BUILD.json"
  chown root:caddy "$root/caddy/caddy" "$root/caddy/Caddyfile"
  for helper in $release_helpers; do
    chown root:root "$root/libexec/$helper"
  done
  chmod 0751 "$root"
  chmod 0750 "$root/bin" "$root/libexec" "$root/caddy"
  chmod 0700 "$root/data" "$root/run/caddy"
  if [ "$mode" = "install" ]; then
    write_initial_config "$root" "$panel_port"
  fi
  migrate_control_plane_config "$root"

  write_unit "$package/systemd/apppanel.service" /etc/systemd/system/apppanel.service "$root"
  write_unit "$package/systemd/apppanel-agent.service" /etc/systemd/system/apppanel-agent.service "$root"
  write_unit "$package/systemd/caddy.service" /etc/systemd/system/caddy.service "$root"
  write_unit "$package/systemd/apppanel-docker-bridge-guard.service" /etc/systemd/system/apppanel-docker-bridge-guard.service "$root"
  restart_services
  systemctl enable apppanel-docker-bridge-guard.service >/dev/null 2>&1 || true
  # Docker 由用户在应用商店里按需安装：未安装时该单元无事可做（守护脚本自行跳过），
  # 因此只在 docker 服务存在时才立即启动，避免安装流程因依赖缺失而失败。
  if systemctl cat docker.service >/dev/null 2>&1; then
    systemctl restart apppanel-docker-bridge-guard.service || echo "警告: Docker 网桥自愈未成功，详见 journalctl -u apppanel-docker-bridge-guard" >&2
  fi
  install -m 0644 "$package/VERSION" "$root/VERSION"
  chown root:root "$root/VERSION"
  chmod 0644 "$root/VERSION"
  if [ "$mode" = "install" ]; then
    bootstrap_admin "$root" "$panel_port" "$admin_login" "$admin_password"
    access_host=服务器IP
    if detected_ip=$(public_ipv4); then
      access_host=$detected_ip
    else
      warn "未能自动获取公网 IPv4，请使用服务器实际 IP 访问"
    fi
    line
    success "AppPanel $version 安装完成"
    printf '访问地址: http://%s:%s\n安装目录: %s\n登录账号: %s\n' "$access_host" "$panel_port" "$root" "$admin_login"
    line
  else
    success "AppPanel $version 更新完成"
    info "安装目录: $root"
  fi
  trap - EXIT INT TERM
  rm -rf "$tmp"
}

uninstall_panel() {
  purge=false
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=true ;;
      *) fail "未知卸载参数: $arg" ;;
    esac
  done
  root=${APPPANEL_ROOT:-}
  [ -n "$root" ] || root=$(service_root)
  [ -n "$root" ] || root=/home/apppanel
  warn "卸载默认保留数据、网站、项目和证书。追加 --purge 才会删除安装目录。"
  confirm "将卸载 AppPanel 服务，是否继续？" || { info "已取消"; return; }
  step "停止并移除 AppPanel 服务"
  stop_and_disable apppanel.service
  stop_and_disable apppanel-agent.service
  stop_and_disable caddy.service
  stop_and_disable apppanel-mysql.service
  stop_and_disable apppanel-mariadb.service
  for path in /etc/systemd/system/apppanel-project-*.service; do
    [ -e "$path" ] || continue
    stop_and_disable "$(basename "$path")"
    rm -f "$path"
  done
  rm -f /etc/systemd/system/apppanel.service /etc/systemd/system/apppanel-agent.service /etc/systemd/system/caddy.service /etc/systemd/system/apppanel-mysql.service /etc/systemd/system/apppanel-mariadb.service
  systemctl daemon-reload
  if [ "$purge" = true ]; then
    rm -rf "$root"
    success "AppPanel 已卸载，安装目录已删除: $root"
  else
    success "AppPanel 服务已卸载，安装目录已保留: $root"
  fi
}

# --- APT 发行版官方源切换 ---
# 只改 Debian/Ubuntu 官方套件条目的 URI（支持 one-line 与 DEB822 两种格式），
# 第三方源（Caddy、PGDG、Docker 等）一律不动。路径可用环境变量覆盖以便测试：
# APPPANEL_OS_RELEASE→/etc/os-release，APPPANEL_APT_ETC→/etc/apt，
# APPPANEL_SKIP_APT_UPDATE=1 跳过改后验证。
apt_os_release_file=${APPPANEL_OS_RELEASE:-/etc/os-release}
apt_etc_dir=${APPPANEL_APT_ETC:-/etc/apt}

mirror_choice_label() {
  case "$1" in tuna) printf '清华源' ;; official) printf '官方源' ;; *) printf '%s' "$1" ;; esac
}

mirror_detect_distro() {
  # 输出：<发行版> <代号>，如 "debian trixie"；非 Debian/Ubuntu 返回非零
  distro_id=$(sed -n 's/^ID=//p' "$apt_os_release_file" 2>/dev/null | tr -d '"' | head -n 1)
  distro_codename=$(sed -n 's/^VERSION_CODENAME=//p' "$apt_os_release_file" 2>/dev/null | tr -d '"' | head -n 1)
  case "$distro_id" in debian|ubuntu) ;; *) return 1 ;; esac
  [ -n "$distro_codename" ] || return 1
  printf '%s %s\n' "$distro_id" "$distro_codename"
}

mirror_bases_for() {
  # 用法：mirror_bases_for <debian|ubuntu> <tuna|official>；输出：<主源> <安全源>
  case "$1/$2" in
    debian/tuna) printf 'https://mirrors.tuna.tsinghua.edu.cn/debian/ https://mirrors.tuna.tsinghua.edu.cn/debian-security/\n' ;;
    debian/official) printf 'http://deb.debian.org/debian/ http://security.debian.org/debian-security/\n' ;;
    ubuntu/tuna)
      case "$(uname -m)" in
        x86_64|amd64) printf 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ https://mirrors.tuna.tsinghua.edu.cn/ubuntu/\n' ;;
        *) printf 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/\n' ;;
      esac ;;
    ubuntu/official)
      case "$(uname -m)" in
        x86_64|amd64) printf 'http://archive.ubuntu.com/ubuntu/ http://security.ubuntu.com/ubuntu/\n' ;;
        *) printf 'http://ports.ubuntu.com/ubuntu-ports/ http://ports.ubuntu.com/ubuntu-ports/\n' ;;
      esac ;;
    *) return 1 ;;
  esac
}

mirror_rewrite_oneline() {
  # 用法：mirror_rewrite_oneline <文件> <主源> <安全源> <代号> <官方组件>
  # 三重判定缺一不可：套件是官方套件、URI 路径是发行版仓库路径、组件含官方组件。
  # 这样借用代号作套件的第三方源（Docker/MySQL 等）不会被误伤。
  # 返回：0=有改动，1=无改动，其他=失败
  file=$1; main=$2; sec=$3; codename=$4; comps=$5
  tmpfile=$(mktemp) || return 2
  if awk -v main="$main" -v sec="$sec" -v code="$codename" -v comps="$comps" \
      -v valid="debian debian-security ubuntu ubuntu-ports" '
    function base_for(suite) {
      if (suite == code || suite == code "-updates" || suite == code "-backports") return main
      if (suite == code "-security") return sec
      return ""
    }
    {
      line = $0
      if (match(line, /^[[:space:]]*deb(-src)?[[:space:]]+/)) {
        n = split(line, f)
        idx = 2
        if (f[2] ~ /^\[/) {
          while (idx <= n && f[idx] !~ /\]$/) idx++
          idx++
        }
        nb = base_for(f[idx + 1])
        if (nb != "") {
          upath = f[idx]; sub(/^https?:\/\/[^\/]*\//, "", upath); sub(/\/$/, "", upath)
          nseg = split(upath, seg, "/"); base = seg[nseg]
          if (index(" " valid " ", " " base " ")) {
            for (j = idx + 2; j <= n; j++) {
              if (f[j] ~ /^#/) break
              if (index(" " comps " ", " " f[j] " ")) { ok = 1; break }
            }
          }
        }
        if (nb != "" && ok && f[idx] != nb) {
          f[idx] = nb
          line = f[1]
          for (i = 2; i <= n; i++) line = line " " f[i]
          changed = 1
        }
        ok = 0
      }
      print line
    }
    END { exit changed ? 0 : 1 }
  ' "$file" > "$tmpfile"; then
    cat "$tmpfile" > "$file"
    rm -f "$tmpfile"
    return 0
  fi
  status=$?
  rm -f "$tmpfile"
  return "$status"
}

mirror_rewrite_deb822() {
  # 用法：mirror_rewrite_deb822 <文件> <主源> <安全源> <代号> <官方组件>
  # 判定规则同 mirror_rewrite_oneline；返回值也相同。
  file=$1; main=$2; sec=$3; codename=$4; comps=$5
  tmpfile=$(mktemp) || return 2
  if awk -v main="$main" -v sec="$sec" -v code="$codename" -v comps="$comps" \
      -v valid="debian debian-security ubuntu ubuntu-ports" '
    function flush() {
      if (pcount == 0) return
      nb = ""
      if (has_sec && !has_main) nb = sec
      else if (has_main) nb = main
      for (i = 1; i <= pcount; i++) {
        if (nb != "" && penabled && ptype_deb && pbase_ok && pcomps_ok && puriline[i] != "" && puri[i] != nb) {
          p[i] = "URIs: " nb
          changed = 1
        }
        print p[i]
      }
      pcount = 0; has_main = 0; has_sec = 0; penabled = 1; ptype_deb = 0
      pbase_ok = 0; pcomps_ok = 0
    }
    BEGIN { penabled = 1 }
    /^[[:space:]]*$/ { flush(); print; next }
    {
      pcount++; p[pcount] = $0
      if ($0 ~ /^Types:.*deb/) ptype_deb = 1
      if ($0 ~ /^Enabled:[[:space:]]*no([[:space:]]|$)/) penabled = 0
      if ($0 ~ /^Suites:/) {
        s = $0; sub(/^Suites:[[:space:]]*/, "", s)
        m = split(s, arr)
        for (k = 1; k <= m; k++) {
          if (arr[k] == code || arr[k] == code "-updates" || arr[k] == code "-backports") has_main = 1
          if (arr[k] == code "-security") has_sec = 1
        }
      }
      if ($0 ~ /^Components:/) {
        c = $0; sub(/^Components:[[:space:]]*/, "", c)
        m = split(c, arr)
        for (k = 1; k <= m; k++) {
          if (index(" " comps " ", " " arr[k] " ")) pcomps_ok = 1
        }
      }
      if ($0 ~ /^URIs:/) {
        u = $0; sub(/^URIs:[[:space:]]*/, "", u)
        split(u, ua); puriline[pcount] = 1; puri[pcount] = ua[1]
        upath = ua[1]; sub(/^https?:\/\/[^\/]*\//, "", upath); sub(/\/$/, "", upath)
        nseg = split(upath, seg, "/")
        if (index(" " valid " ", " " seg[nseg] " ")) pbase_ok = 1
      }
    }
    END { flush(); exit changed ? 0 : 1 }
  ' "$file" > "$tmpfile"; then
    cat "$tmpfile" > "$file"
    rm -f "$tmpfile"
    return 0
  fi
  status=$?
  rm -f "$tmpfile"
  return "$status"
}

switch_apt_mirror() {
  choice=${1:-}
  if ! distro_info=$(mirror_detect_distro); then
    fail "仅支持 Debian / Ubuntu 系统（无法从 $apt_os_release_file 识别发行版）"
  fi
  set -- $distro_info
  distro_id=$1; distro_codename=$2
  case "$distro_id" in
    debian) official_comps="main contrib non-free non-free-firmware" ;;
    ubuntu) official_comps="main restricted universe multiverse" ;;
  esac
  apt_files=""
  [ -f "$apt_etc_dir/sources.list" ] && apt_files="$apt_files $apt_etc_dir/sources.list"
  for ext in list sources; do
    for f in "$apt_etc_dir/sources.list.d"/*."$ext"; do
      [ -f "$f" ] || continue
      apt_files="$apt_files $f"
    done
  done
  # shellcheck disable=SC2086
  [ -n "$apt_files" ] || fail "在 $apt_etc_dir 下没有找到 apt 源配置文件"
  current=unknown
  # shellcheck disable=SC2086
  if grep -Rqh "mirrors.tuna.tsinghua.edu.cn" $apt_files 2>/dev/null; then
    current=tuna
  # shellcheck disable=SC2086
  elif grep -Rqh -e "deb.debian.org" -e "security.debian.org" -e "archive.ubuntu.com" \
      -e "security.ubuntu.com" -e "ports.ubuntu.com" $apt_files 2>/dev/null; then
    current=official
  fi
  case "$choice" in
    tuna|official) ;;
    "")
      info "系统版本：$distro_id $distro_codename，当前系统源：$(mirror_choice_label "$current")"
      if [ ! -t 0 ]; then
        fail "非交互模式请直接指定：sh install.sh mirror tuna|official"
      fi
      printf '请选择目标源 [1-2]（1 清华源，2 官方源）: ' >&2
      read -r sel || sel=""
      case "$sel" in 1) choice=tuna ;; 2) choice=official ;; *) fail "未选择有效目标源" ;; esac
      ;;
    *) fail "未知源选项：$choice（可用 tuna / official）" ;;
  esac
  if [ "$choice" = "$current" ]; then
    success "当前已是$(mirror_choice_label "$choice")，无需更换"
    return
  fi
  if ! base_info=$(mirror_bases_for "$distro_id" "$choice"); then
    fail "无法确定 $distro_id 的源地址"
  fi
  set -- $base_info
  main_base=$1; sec_base=$2
  backup_dir="$apt_etc_dir/apppanel-mirror-backup-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir" || fail "无法创建备份目录 $backup_dir"
  changed_files=0
  changed_list=""
  # shellcheck disable=SC2086
  for f in $apt_files; do
    orig=$(mktemp) || fail "无法创建临时文件"
    cp "$f" "$orig"
    case "$f" in
      *.sources) mirror_rewrite_deb822 "$f" "$main_base" "$sec_base" "$distro_codename" "$official_comps" ;;
      *) mirror_rewrite_oneline "$f" "$main_base" "$sec_base" "$distro_codename" "$official_comps" ;;
    esac
    if [ "$?" -gt 1 ]; then
      rm -f "$orig"
      fail "改写 $f 失败"
    fi
    if ! cmp -s "$orig" "$f"; then
      rel=${f#"$apt_etc_dir"/}
      mkdir -p "$backup_dir/$(dirname "$rel")"
      cp "$orig" "$backup_dir/$rel"
      changed_files=$((changed_files + 1))
      changed_list="$changed_list $f"
    fi
    rm -f "$orig"
  done
  if [ "$changed_files" -eq 0 ]; then
    rmdir "$backup_dir" 2>/dev/null || true
    success "没有发现需要更换的官方源条目（第三方源保持不动）"
    return
  fi
  info "改写 $changed_files 个文件：$changed_list"
  info "原文件已备份到 $backup_dir"
  if ! confirm "确认切换为$(mirror_choice_label "$choice")？"; then
    # shellcheck disable=SC2086
    for f in $changed_list; do
      cp "$backup_dir/${f#"$apt_etc_dir"/}" "$f"
    done
    info "已取消，原文件保持不动"
    return
  fi
  if [ "${APPPANEL_SKIP_APT_UPDATE:-0}" != "1" ]; then
    step "验证新源可用性（apt-get update）"
    update_log=$(mktemp) || fail "无法创建临时文件"
    if apt-get update >"$update_log" 2>&1; then
      rm -f "$update_log"
    else
      new_hosts=$(printf '%s\n%s\n' "$main_base" "$sec_base" | sed 's|^https\?://||; s|/.*||' | sort -u)
      hit_new=0
      # shellcheck disable=SC2086
      for h in $new_hosts; do
        if grep -Eq "^(Err|E:).*$h" "$update_log"; then hit_new=1; fi
      done
      if [ "$hit_new" -eq 1 ]; then
        # shellcheck disable=SC2086
        for f in $changed_list; do
          cp "$backup_dir/${f#"$apt_etc_dir"/}" "$f"
        done
        rm -f "$update_log"
        fail "新源不可用，已恢复备份（$backup_dir），请检查网络后重试"
      fi
      warn "apt-get update 报告其他源错误（多为第三方源失效），与本次切换无关："
      grep -E "^(Err|E:)" "$update_log" | head -n 10 >&2 || true
      rm -f "$update_log"
    fi
  fi
  success "已切换为$(mirror_choice_label "$choice")（原文件备份在 $backup_dir）"
}

run_menu_action() {
  # 交互菜单包装：在子 shell 里跑，成功或失败都不退出脚本，结束后回主菜单。
  if ( "$@" ); then
    :
  else
    warn "上一步操作未完成，已返回主菜单"
  fi
  printf '\n按回车返回主菜单...' >&2
  read -r _ || true
}

action=${1:-}
if [ -z "$action" ]; then
  while true; do
    banner
    printf "${c_green}1.${c_reset} 安装面板\n${c_blue}2.${c_reset} 更新面板\n${c_red}3.${c_reset} 卸载面板\n${c_blue}4.${c_reset} 更换系统软件源\n${c_blue}5.${c_reset} 退出\n"
    line
    printf '请输入选项 [1-5]: ' >&2
    read -r action || { info "已退出"; exit 0; }
    case "$action" in
      1) run_menu_action install_or_update install ;;
      2) run_menu_action install_or_update update ;;
      3) run_menu_action uninstall_panel ;;
      4) run_menu_action switch_apt_mirror ;;
      5|q|quit|exit) info "已退出"; exit 0 ;;
      *) warn "无效选项，请输入 1-5" ;;
    esac
  done
else
  shift
  banner
fi
case "$action" in
  1|install) install_or_update install ;;
  2|update) install_or_update update ;;
  3|uninstall) uninstall_panel "$@" ;;
  4|mirror) switch_apt_mirror "$@" ;;
  5|q|quit|exit) info "已退出" ;;
  *) fail "无效选项，请输入 1、2、3 或 4" ;;
esac
