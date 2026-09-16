// CrossShow API 服务入口。
// 配置全部来自环境变量（文档 6.3：服务配置不写入客户端代码）。
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	// 内嵌 tzdata：容器内无需依赖系统时区数据（文档 5.1）
	_ "time/tzdata"

	"crossshow/server/internal/events"
	httpapi "crossshow/server/internal/http"
	"crossshow/server/internal/storage"
)

type config struct {
	ListenAddr      string
	DBPath          string
	DefaultTimezone string
	LogLevel        string
	ShutdownTimeout time.Duration
}

func loadConfig() (config, error) {
	c := config{
		ListenAddr:      envOr("CROSSSHOW_LISTEN_ADDR", ":8080"),
		DBPath:          envOr("CROSSSHOW_DB_PATH", "./data/crossshow.db"),
		DefaultTimezone: envOr("CROSSSHOW_DEFAULT_TIMEZONE", "Asia/Shanghai"),
		LogLevel:        envOr("CROSSSHOW_LOG_LEVEL", "info"),
	}
	t := envOr("CROSSSHOW_SHUTDOWN_TIMEOUT", "15s")
	d, err := time.ParseDuration(t)
	if err != nil || d <= 0 {
		return c, fmt.Errorf("CROSSSHOW_SHUTDOWN_TIMEOUT 非法: %q", t)
	}
	c.ShutdownTimeout = d
	if _, err := time.LoadLocation(c.DefaultTimezone); err != nil {
		return c, fmt.Errorf("CROSSSHOW_DEFAULT_TIMEZONE 非法 IANA 时区: %q", c.DefaultTimezone)
	}
	return c, nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	if err := run(); err != nil {
		slog.Error("启动失败", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	level := slog.LevelInfo
	switch cfg.LogLevel {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(log)

	if err := os.MkdirAll(filepath.Dir(cfg.DBPath), 0o755); err != nil {
		return fmt.Errorf("创建数据目录: %w", err)
	}
	db, err := storage.Open(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()
	if err := storage.Migrate(context.Background(), db.DB); err != nil {
		return fmt.Errorf("执行数据库迁移: %w", err)
	}
	log.Info("数据库就绪", "path", cfg.DBPath)

	svc := events.NewService(db.DB, cfg.DefaultTimezone, time.Now)
	handler := httpapi.NewHandler(svc, log)

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           handler.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Info("服务监听中", "addr", cfg.ListenAddr, "timezone", cfg.DefaultTimezone)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		log.Info("收到退出信号，开始优雅关闭")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("优雅关闭失败", "err", err)
		return err
	}
	log.Info("服务已停止")
	return nil
}
