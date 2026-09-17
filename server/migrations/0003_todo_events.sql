-- 新增待办事件（没有固定时间、不关联任何日期的记录）。
-- 待办不携带任何时间/日期字段：all_day = 0，start_at / end_at /
-- start_date / end_date_exclusive 全为空，仅以 is_todo = 1 标记。
-- 原 CHECK 约束不允许全空字段，且 SQLite 不能直接修改 CHECK，
-- 因此按官方流程重建表：建新表 → 拷贝数据 → 删旧表 → 改名 → 重建索引。
-- 存量事件全部置 is_todo = 0，语义不变。

CREATE TABLE events_new (
    id                 TEXT PRIMARY KEY,          -- UUID
    series_id          TEXT REFERENCES event_series(id),
    occurrence_index   INTEGER,                   -- 系列内从 0 开始的原始序号
    title              TEXT NOT NULL CHECK (length(title) >= 1 AND length(title) <= 200),
    notes              TEXT NOT NULL DEFAULT '' CHECK (length(notes) <= 10000),
    all_day            INTEGER NOT NULL CHECK (all_day IN (0, 1)),
    is_todo            INTEGER NOT NULL DEFAULT 0 CHECK (is_todo IN (0, 1)),
    -- 普通事件：UTC 时间（RFC 3339）；全天/待办为 NULL
    start_at           TEXT,
    end_at             TEXT,
    -- 全天事件：包含式开始日期 + 不含的结束日期；普通/待办为 NULL
    start_date         TEXT,
    end_date_exclusive TEXT,
    timezone           TEXT NOT NULL,             -- 日历时区（IANA）
    version            INTEGER NOT NULL DEFAULT 1,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL,
    deleted_at         TEXT,                      -- 软删除时间，可空
    -- 待办 / 普通事件 / 全天事件三态互斥，且起止范围合法
    CHECK (
        (is_todo = 1 AND all_day = 0
            AND start_at IS NULL AND end_at IS NULL
            AND start_date IS NULL AND end_date_exclusive IS NULL)
        OR
        (is_todo = 0 AND all_day = 0
            AND start_at IS NOT NULL AND end_at IS NOT NULL
            AND start_date IS NULL AND end_date_exclusive IS NULL
            AND end_at > start_at)
        OR
        (is_todo = 0 AND all_day = 1
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

INSERT INTO events_new (id, series_id, occurrence_index, title, notes, all_day, is_todo,
                        start_at, end_at, start_date, end_date_exclusive,
                        timezone, version, created_at, updated_at, deleted_at)
SELECT id, series_id, occurrence_index, title, notes, all_day, 0,
       start_at, end_at, start_date, end_date_exclusive,
       timezone, version, created_at, updated_at, deleted_at
FROM events;

DROP TABLE events;
ALTER TABLE events_new RENAME TO events;

CREATE INDEX idx_events_start_at           ON events (start_at);
CREATE INDEX idx_events_end_at             ON events (end_at);
CREATE INDEX idx_events_start_date         ON events (start_date);
CREATE INDEX idx_events_end_date_exclusive ON events (end_date_exclusive);
CREATE INDEX idx_events_series_id          ON events (series_id, occurrence_index);
