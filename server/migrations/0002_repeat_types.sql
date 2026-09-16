-- 新增重复类型：每天（daily）、工作日（weekdays）。
-- 采用可空语义友好的默认列方式：给 event_series 增加 repeat_type 列，
-- 避免重建表（events 表外键引用 event_series，表重建需要关闭外键检查）。
-- interval_weeks 保留原 CHECK（值恒为 1 或 2）；daily/weekdays 存 1，
-- 展开逻辑只依据 repeat_type。

ALTER TABLE event_series
    ADD COLUMN repeat_type TEXT NOT NULL DEFAULT 'weekly'
    CHECK (repeat_type IN ('daily', 'weekdays', 'weekly', 'biweekly'));

-- 存量系列按原 interval_weeks 语义归类
UPDATE event_series
SET repeat_type = CASE WHEN interval_weeks = 2 THEN 'biweekly' ELSE 'weekly' END;
