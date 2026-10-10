# waf.farm

waf.farm 服务器管理面板的发行仓库：存放安装脚本与版本化二进制发行包（源码不在此仓）。

## 快速安装

```sh
curl -fsSL https://raw.githubusercontent.com/popcorn-25/waf.farm/main/scripts/install.sh -o install.sh
sh install.sh install
```

## 更新 / 卸载 / 更换软件源

```sh
sh install.sh update
sh install.sh uninstall [--purge]
sh install.sh mirror tuna|official
```

## 发行包

Releases 提供 `waf-farm_<版本>_linux_<架构>.tar.gz` 与同名 `.sha256` 校验文件；安装与更新流程会自动校验完整性。

## 版本说明

- 1.1.0 起包名与安装路径统一为 waf-farm（默认安装到 /home/waf-farm）。
- 1.0.x 为旧 AppPanel 目录结构，已下线，不能直接 update 升级，请全新安装。
