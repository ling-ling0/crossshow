#!/usr/bin/env sh
# CrossShow SQLite 一致性备份脚本（开发文档 9.3）。
#
# 使用 SQLite 在线备份接口（.backup），对启用 WAL 的运行中数据库安全，
# 不得直接复制运行中的主数据库文件。保留最近 KEEP 份，超出自动清理。
#
# 建议每天 cron 执行，并定期把 BACKUP_DIR 复制到服务器之外：
#   crontab: 30 3 * * * /opt/crossshow/backup.sh /opt/crossshow/data /opt/crossshow/backups >> /var/log/crossshow-backup.log 2>&1
#
# 依赖：sqlite3（宿主机安装，或改用 docker run 挂载数据卷执行）。
set -eu

DB_PATH="${1:?用法: backup.sh <数据库路径> <备份目录> [保留份数]}"
BACKUP_DIR="${2:?用法: backup.sh <数据库路径> <备份目录> [保留份数]}"
KEEP="${3:-14}"

if [ ! -f "$DB_PATH" ]; then
    echo "[backup] 数据库不存在: $DB_PATH" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET="$BACKUP_DIR/crossshow-$STAMP.db"
TMP="$TARGET.tmp"

# 在线一致性备份（WAL 安全），失败时清理临时文件
sqlite3 "$DB_PATH" ".backup '$TMP'"
mv "$TMP" "$TARGET"

# 完整性检查，损坏即删除并报错
if ! sqlite3 "$TARGET" "PRAGMA integrity_check;" | grep -q "^ok$"; then
    rm -f "$TARGET"
    echo "[backup] 备份完整性检查未通过: $TARGET" >&2
    exit 1
fi

# 保留最近 KEEP 份
ls -1t "$BACKUP_DIR"/crossshow-*.db 2>/dev/null | tail -n +"$((KEEP + 1))" | while IFS= read -r old; do
    rm -f "$old"
    echo "[backup] 清理过期备份: $old"
done

echo "[backup] 完成: $TARGET"
