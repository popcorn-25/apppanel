#!/bin/sh
set -eu

# Manage a verified binary release. The deployed application lives entirely in
# <install-directory>/apppanel; systemd unit definitions are the only host files.
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行此脚本" >&2
  exit 1
fi

stop_and_disable() {
  systemctl disable --now "$1" >/dev/null 2>&1 || true
}

confirm() {
  [ "${APPPANEL_ASSUME_YES:-0}" = "1" ] && return 0
  printf '%s [y/N] ' "$1"
  read -r answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

prompt_value() {
  label=$1
  default=${2:-}
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default"
  else
    printf '%s: ' "$label"
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
      echo "无法从 GitHub 检测最新版本: $repository" >&2
      exit 1
    }
  tag=$(printf '%s' "$response" | tr '\n' ' ' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$tag" ] || { echo "GitHub 最新发行版未包含 tag_name" >&2; exit 1; }
  printf '%s\n' "$tag"
}

valid_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$'
}

write_unit() {
  template=$1
  target=$2
  root=$3
  sed "s|%APPPANEL_ROOT%|$root|g" "$template" > "$target"
}

restart_services() {
  systemctl daemon-reload
  systemctl enable apppanel-agent caddy apppanel >/dev/null
  for service in apppanel-agent caddy apppanel; do
    systemctl restart "$service"
    systemctl is-active --quiet "$service" || {
      echo "服务启动失败: $service，请使用 journalctl -u $service -n 100 查看日志" >&2
      exit 1
    }
  done
}

bootstrap_admin() {
  root=$1
  port=$2
  login_name=$3
  login_password=$4
  [ -f "$root/data/apppanel.db" ] && return
  command -v curl >/dev/null || return
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS "http://127.0.0.1:$port/api/v1/install/status" >/dev/null 2>&1 && break
    sleep 1
  done
  account=$(json_escape "$login_name")
  password=$(json_escape "$login_password")
  payload=$(printf '{"dataDir":"%s/data","adminUrl":"http://127.0.0.1:2019","panelUpstream":"127.0.0.1:%s","logListen":"127.0.0.1:2020","logTarget":"127.0.0.1:2020","staticRoot":"%s/sites","panelDomain":"%s","siteName":"AppPanel","adminName":"%s","adminEmail":"%s","adminPassword":"%s","cookieSecure":false}' "$(json_escape "$root")" "$port" "$(json_escape "$root")" "$account" "$account" "$account" "$password")
  curl -fsS -X POST "http://127.0.0.1:$port/api/v1/install" -H 'Content-Type: application/json' --data "$payload" >/dev/null
}

install_or_update() {
  mode=$1
  release_url=${APPPANEL_RELEASE_URL:-}
  repository=popcorn-25/apppanel
  version=${APPPANEL_VERSION:-}
  version=${version#v}
  caddy_version=${CADDY_VERSION:-2.11.4}
  panel_port=${APPPANEL_PORT:-}
  admin_login=${APPPANEL_ADMIN:-}
  admin_password=${APPPANEL_PASSWORD:-}
  install_dir=${APPPANEL_INSTALL_DIR:-}

  if [ "$mode" = "install" ]; then
    [ -n "$install_dir" ] || install_dir=$(prompt_value "安装目录（AppPanel 将安装到此目录下的 apppanel）" "/home")
    install_dir=$(validate_parent_dir "$install_dir")
    root="$install_dir/apppanel"
    [ ! -e "$root" ] || { echo "安装目录已存在: $root" >&2; exit 1; }
    [ -n "$panel_port" ] || panel_port=$(prompt_value "面板端口" "18081")
    case "$panel_port" in *[!0-9]*|'') echo "端口必须是 1-65535 的整数" >&2; exit 1;; esac
    [ "$panel_port" -ge 1 ] && [ "$panel_port" -le 65535 ] || { echo "端口必须是 1-65535" >&2; exit 1; }
    [ -n "$admin_login" ] || admin_login=$(prompt_value "登录账号（作为邮箱使用）" "admin@localhost")
    [ -n "$admin_login" ] || { echo "登录账号不能为空" >&2; exit 1; }
    [ -n "$admin_password" ] || admin_password=$(prompt_password)
  else
    root=${APPPANEL_ROOT:-}
    [ -n "$root" ] || root=$(service_root)
    [ -n "$root" ] && [ -x "$root/bin/apppanel" ] || { echo "未检测到已安装的 AppPanel；请设置 APPPANEL_ROOT 或选择安装面板" >&2; exit 1; }
  fi

  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "不支持的 CPU 架构: $(uname -m)" >&2; exit 1 ;;
  esac
  command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }
  command -v tar >/dev/null || { echo "需要 tar" >&2; exit 1; }
  command -v sha256sum >/dev/null || { echo "需要 sha256sum" >&2; exit 1; }

  if [ -z "$version" ]; then
    release_tag=$(latest_github_release "$repository")
    version=${release_tag#v}
  else
    release_tag="v$version"
  fi
  valid_version "$version" || { echo "发行版本无效: $version" >&2; exit 1; }
  if [ -z "$release_url" ]; then
    release_url="https://github.com/$repository/releases/download/$release_tag"
  fi
  if [ "$mode" = "update" ] && [ -f "$root/VERSION" ] && [ "$(cat "$root/VERSION")" = "$version" ]; then
    echo "AppPanel 已是最新版本: $version"
    return
  fi

  name="apppanel_${version}_linux_${arch}"
  archive="$name.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  base=${release_url%/}
  curl -fL --retry 3 --retry-delay 2 "$base/$archive" -o "$tmp/$archive"
  curl -fL --retry 3 --retry-delay 2 "$base/$archive.sha256" -o "$tmp/$archive.sha256"
  (cd "$tmp" && sha256sum -c "$archive.sha256")
  tar -xzf "$tmp/$archive" -C "$tmp"
  package="$tmp/$name"
  [ -f "$package/VERSION" ] || { echo "发行包缺少 VERSION" >&2; exit 1; }
  [ "$(cat "$package/VERSION")" = "$version" ] || { echo "发行包版本与请求版本不一致" >&2; exit 1; }
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
    caddy/Caddyfile; do
    [ -f "$package/$path" ] || { echo "发行包缺少 $path" >&2; exit 1; }
  done

  getent group apppanel >/dev/null 2>&1 || groupadd --system --gid 1999 apppanel
  id apppanel >/dev/null 2>&1 || useradd --system --gid apppanel --home-dir "$root" --shell /usr/sbin/nologin apppanel
  install -d -m 0750 -o apppanel -g apppanel "$root" "$root/bin" "$root/libexec" "$root/data" "$root/run" "$root/sites" "$root/projects" "$root/node" "$root/go" "$root/mysql" "$root/mariadb" "$root/docker" "$root/caddy"
  install -d -m 0755 "$root/run/php" "$root/caddy/data" "$root/caddy/config"
  chmod 0775 "$root/sites"

  install -m 0755 "$package/bin/apppanel" "$root/bin/apppanel"
  install -m 0755 "$package/bin/apppanel-agent" "$root/bin/apppanel-agent"
  for helper in apppanel-php apppanel-runtime apppanel-database apppanel-docker apppanel-update; do
    install -m 0755 "$package/libexec/$helper" "$root/libexec/$helper"
  done
  install -m 0644 "$package/caddy/Caddyfile" "$root/caddy/Caddyfile"
  if [ ! -x "$root/caddy/caddy" ]; then
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${caddy_version}/caddy_${caddy_version}_linux_${arch}.tar.gz" | tar -xz -C "$root/caddy" caddy
    chmod 0755 "$root/caddy/caddy"
  fi
  chown -R apppanel:apppanel "$root"
  chown root:apppanel "$root" "$root/bin" "$root/libexec" "$root/caddy"
  chown root:root \
    "$root/bin/apppanel" \
    "$root/bin/apppanel-agent" \
    "$root/libexec/apppanel-php" \
    "$root/libexec/apppanel-runtime" \
    "$root/libexec/apppanel-database" \
    "$root/libexec/apppanel-docker" \
    "$root/libexec/apppanel-update" \
    "$root/caddy/caddy" \
    "$root/caddy/Caddyfile"
  chmod 0750 "$root" "$root/bin" "$root/libexec" "$root/caddy"

  write_unit "$package/systemd/apppanel.service" /etc/systemd/system/apppanel.service "$root"
  write_unit "$package/systemd/apppanel-agent.service" /etc/systemd/system/apppanel-agent.service "$root"
  write_unit "$package/systemd/caddy.service" /etc/systemd/system/caddy.service "$root"
  restart_services
  install -m 0644 "$package/VERSION" "$root/VERSION"
  chown root:root "$root/VERSION"
  chmod 0644 "$root/VERSION"
  if [ "$mode" = "install" ]; then
    bootstrap_admin "$root" "$panel_port" "$admin_login" "$admin_password"
    echo "AppPanel $version 安装完成: http://服务器IP:$panel_port"
    echo "安装目录: $root"
    echo "登录账号: $admin_login"
  else
    echo "AppPanel $version 更新完成，apppanel-agent、Caddy 和面板服务均已重启。安装目录: $root"
  fi
  trap - EXIT INT TERM
  rm -rf "$tmp"
}

uninstall_panel() {
  purge=false
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=true ;;
      *) echo "未知卸载参数: $arg" >&2; exit 1 ;;
    esac
  done
  root=${APPPANEL_ROOT:-}
  [ -n "$root" ] || root=$(service_root)
  [ -n "$root" ] || root=/home/apppanel
  confirm "将卸载 AppPanel 服务，是否继续？" || { echo "已取消"; return; }
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
    echo "AppPanel 已卸载，安装目录已删除: $root"
  else
    echo "AppPanel 服务已卸载，安装目录已保留: $root"
  fi
}

action=${1:-}
if [ -z "$action" ]; then
  cat <<'EOF'

AppPanel 管理脚本
1. 安装面板
2. 更新面板
3. 卸载面板
EOF
  printf '请输入选项 [1-3]: '
  read -r action
else
  shift
fi
case "$action" in
  1|install) install_or_update install ;;
  2|update) install_or_update update ;;
  3|uninstall) uninstall_panel "$@" ;;
  *) echo "无效选项，请输入 1、2 或 3" >&2; exit 1 ;;
esac
