-- CrossShow 初始 schema（对应开发文档 v0.1 第 6 节数据模型）。
-- 约定：
--   * 所有时间戳为 RFC 3339 UTC 字符串（UTC，带 Z 后缀）。
--   * 全天事件日期为本地日历时区的 YYYY-MM-DD；end_date_exclusive 不含当日。
--   * 普通事件与全天事件字段互斥，由 CHECK 约束保证。

CREATE TABLE schema_migrations (
    version    INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    applied_at TEXT NOT NULL
);

-- 重复系列。普通事件不关联系列（series_id 为 NULL）。
CREATE TABLE event_series (
    id               TEXT PRIMARY KEY,            -- UUID
    interval_weeks   INTEGER NOT NULL CHECK (interval_weeks IN (1, 2)),
    occurrence_count INTEGER NOT NULL CHECK (occurrence_count >= 1 AND occurrence_count <= 520),
    timezone         TEXT NOT NULL,               -- 系列生成时区（IANA）
    version          INTEGER NOT NULL DEFAULT 1,  -- 任一成员写入时增加
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);

CREATE TABLE events (
    id                 TEXT PRIMARY KEY,          -- UUID
    series_id          TEXT REFERENCES event_series(id),
    occurrence_index   INTEGER,                   -- 系列内从 0 开始的原始序号
    title              TEXT NOT NULL CHECK (length(title) >= 1 AND length(title) <= 200),
    notes              TEXT NOT NULL DEFAULT '' CHECK (length(notes) <= 10000),
    all_day            INTEGER NOT NULL CHECK (all_day IN (0, 1)),
    -- 普通事件：UTC 时间（RFC 3339）；全天事件为 NULL
    start_at           TEXT,
    end_at             TEXT,
    -- 全天事件：包含式开始日期 + 不含的结束日期；普通事件为 NULL
    start_date         TEXT,
    end_date_exclusive TEXT,
    timezone           TEXT NOT NULL,             -- 日历时区（IANA）
    version            INTEGER NOT NULL DEFAULT 1,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL,
    deleted_at         TEXT,                      -- 软删除时间，可空
    -- 普通事件 / 全天事件字段互斥，且起止范围合法
    CHECK (
        (all_day = 0
            AND start_at IS NOT NULL AND end_at IS NOT NULL
            AND start_date IS NULL AND end_date_exclusive IS NULL
            AND end_at > start_at)
        OR
        (all_day = 1
            AND start_date IS NOT NULL AND end_date_exclusive IS NOT NULL
            AND start_at IS NULL AND end_at IS NULL
            AND end_date_exclusive > start_date)
    ),
    -- series_id 与 occurrence_index 必须成对出现
    CHECK (
        (series_id IS NULL AND occurrence_index IS NULL)
        OR (series_id IS NOT NULL AND occurrence_index IS NOT NULL AND occurrence_index >= 0)
    ),
    UNIQUE (series_id, occurrence_index)
);

-- 范围查询（from 含 / to 不含，按日历时区解释后与事件窗口求交）主要走时间字段过滤。
CREATE INDEX idx_events_start_at           ON events (start_at);
CREATE INDEX idx_events_end_at             ON events (end_at);
CREATE INDEX idx_events_start_date         ON events (start_date);
CREATE INDEX idx_events_end_date_exclusive ON events (end_date_exclusive);
CREATE INDEX idx_events_series_id          ON events (series_id, occurrence_index);

-- 写请求幂等：键唯一；request_hash 为方法 + 路径 + 请求体摘要。
-- 相同键 + 相同摘要 → 返回原结果；相同键 + 不同摘要 → 冲突。
-- 与业务变更在同一事务中写入；首版不自动清理。
CREATE TABLE idempotency_records (
    idempotency_key TEXT PRIMARY KEY,
    request_hash    TEXT NOT NULL,
    response_status INTEGER,
    response_body   TEXT,
    created_at      TEXT NOT NULL
);
