// Package storage 负责 SQLite 连接（WAL、外键、busy timeout）与有序迁移执行。
// 依据开发文档 3.3：启用外键约束、WAL 和合理的 busy timeout；
// 单实例负责写入，短暂锁等待返回可重试错误。
package storage

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"

	_ "modernc.org/sqlite" // 纯 Go SQLite 驱动，静态编译无需 CGO

	"crossshow/server/migrations"
)

type DB struct {
	*sql.DB
}

// Open 打开数据库并设置连接级 PRAGMA。
// 所有时间以 UTC 文本（固定精度 RFC 3339）存储，保证字典序与时间序一致。
func Open(path string) (*DB, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开数据库: %w", err)
	}
	// 单连接串行化写入：首版单进程单实例，消除内部锁竞争（文档 3.3）。
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("连接数据库: %w", err)
	}
	return &DB{DB: db}, nil
}

// Migrate 按文件名序号执行未应用的迁移，每个迁移在独立事务中记录版本。
func Migrate(ctx context.Context, db *sql.DB) error {
	applied := map[int64]bool{}
	var tableCount int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations'`).Scan(&tableCount); err != nil {
		return fmt.Errorf("检查迁移表: %w", err)
	}
	if tableCount > 0 {
		rows, err := db.QueryContext(ctx, `SELECT version FROM schema_migrations`)
		if err != nil {
			return fmt.Errorf("读取迁移版本: %w", err)
		}
		for rows.Next() {
			var v int64
			if err := rows.Scan(&v); err != nil {
				rows.Close()
				return err
			}
			applied[v] = true
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return err
		}
		rows.Close()
	}

	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		return fmt.Errorf("读取内嵌迁移: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		version, err := parseVersion(name)
		if err != nil {
			return fmt.Errorf("迁移文件名 %q: %w", name, err)
		}
		if applied[version] {
			continue
		}
		body, err := fs.ReadFile(migrations.FS, name)
		if err != nil {
			return fmt.Errorf("读取迁移 %q: %w", name, err)
		}
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, string(body)); err != nil {
			tx.Rollback()
			return fmt.Errorf("执行迁移 %q: %w", name, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'))`,
			version, name); err != nil {
			tx.Rollback()
			return fmt.Errorf("记录迁移 %q: %w", name, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("提交迁移 %q: %w", name, err)
		}
	}
	return nil
}

func parseVersion(name string) (int64, error) {
	parts := strings.SplitN(name, "_", 2)
	v, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("无法解析版本序号")
	}
	return v, nil
}
