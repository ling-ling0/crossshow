package events

// 事件相关 SQL 访问。与领域类型同包，避免存储层与领域层的模型重复
// （原计划的 internal/storage/events.go 因导入环并入此处；
// internal/storage 仅保留连接与迁移等数据库基础设施）。

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// RowQuerier 兼容 *sql.DB 与 *sql.Tx，事务内外复用同一组查询。
type RowQuerier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

const eventSelect = `
SELECT e.id, e.series_id, e.occurrence_index, e.title, e.notes, e.all_day, e.is_todo,
       e.start_at, e.end_at, e.start_date, e.end_date_exclusive,
       e.timezone, e.version, e.created_at, e.updated_at, e.deleted_at,
       s.version
FROM events e
LEFT JOIN event_series s ON s.id = e.series_id`

type eventRow struct {
	ID               string
	SeriesID         sql.NullString
	OccurrenceIndex  sql.NullInt64
	Title            string
	Notes            string
	AllDay           bool
	IsTodo           bool
	StartAt          sql.NullString
	EndAt            sql.NullString
	StartDate        sql.NullString
	EndDateExclusive sql.NullString
	Timezone         string
	Version          int64
	CreatedAt        string
	UpdatedAt        string
	DeletedAt        sql.NullString
	SeriesVersion    sql.NullInt64
}

func scanEvent(rows interface{ Scan(...any) error }) (Event, error) {
	var r eventRow
	if err := rows.Scan(
		&r.ID, &r.SeriesID, &r.OccurrenceIndex, &r.Title, &r.Notes, &r.AllDay, &r.IsTodo,
		&r.StartAt, &r.EndAt, &r.StartDate, &r.EndDateExclusive,
		&r.Timezone, &r.Version, &r.CreatedAt, &r.UpdatedAt, &r.DeletedAt,
		&r.SeriesVersion,
	); err != nil {
		return Event{}, err
	}
	return r.toEvent()
}

func (r eventRow) toEvent() (Event, error) {
	parse := func(ns sql.NullString) (*time.Time, error) {
		if !ns.Valid {
			return nil, nil
		}
		t, err := ParseTS(ns.String)
		if err != nil {
			return nil, err
		}
		return &t, nil
	}
	startAt, err := parse(r.StartAt)
	if err != nil {
		return Event{}, fmt.Errorf("事件 %s start_at: %w", r.ID, err)
	}
	endAt, err := parse(r.EndAt)
	if err != nil {
		return Event{}, fmt.Errorf("事件 %s end_at: %w", r.ID, err)
	}
	deletedAt, err := parse(r.DeletedAt)
	if err != nil {
		return Event{}, fmt.Errorf("事件 %s deleted_at: %w", r.ID, err)
	}
	createdAt, err := ParseTS(r.CreatedAt)
	if err != nil {
		return Event{}, fmt.Errorf("事件 %s created_at: %w", r.ID, err)
	}
	updatedAt, err := ParseTS(r.UpdatedAt)
	if err != nil {
		return Event{}, fmt.Errorf("事件 %s updated_at: %w", r.ID, err)
	}

	e := Event{
		ID:        r.ID,
		Title:     r.Title,
		Notes:     r.Notes,
		AllDay:    r.AllDay,
		IsTodo:    r.IsTodo,
		Timezone:  r.Timezone,
		Version:   r.Version,
		CreatedAt: createdAt,
		UpdatedAt: updatedAt,
	}
	if r.SeriesID.Valid {
		sid := r.SeriesID.String
		e.SeriesID = &sid
	}
	if r.OccurrenceIndex.Valid {
		v := r.OccurrenceIndex.Int64
		e.OccurrenceIndex = &v
	}
	e.StartAt, e.EndAt = startAt, endAt
	if r.StartDate.Valid {
		v := r.StartDate.String
		e.StartDate = &v
	}
	if r.EndDateExclusive.Valid {
		v := r.EndDateExclusive.String
		e.EndDateExclusive = &v
	}
	e.DeletedAt = deletedAt
	if r.SeriesVersion.Valid {
		v := r.SeriesVersion.Int64
		e.SeriesVersion = &v
	}
	return e, nil
}

func dbInsertSeries(ctx context.Context, q RowQuerier, s Series) error {
	_, err := q.ExecContext(ctx, `
INSERT INTO event_series (id, interval_weeks, repeat_type, occurrence_count, timezone, version, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		s.ID, s.IntervalWeeks, s.RepeatType, s.OccurrenceCount, s.Timezone, s.Version,
		FormatTS(s.CreatedAt), FormatTS(s.UpdatedAt))
	return err
}

func dbInsertEvent(ctx context.Context, q RowQuerier, e Event) error {
	var seriesID, occ, startAt, endAt, startDate, endDate any
	if e.SeriesID != nil {
		seriesID = *e.SeriesID
	}
	if e.OccurrenceIndex != nil {
		occ = *e.OccurrenceIndex
	}
	if e.StartAt != nil {
		startAt = FormatTS(*e.StartAt)
	}
	if e.EndAt != nil {
		endAt = FormatTS(*e.EndAt)
	}
	if e.StartDate != nil {
		startDate = *e.StartDate
	}
	if e.EndDateExclusive != nil {
		endDate = *e.EndDateExclusive
	}
	_, err := q.ExecContext(ctx, `
INSERT INTO events (id, series_id, occurrence_index, title, notes, all_day, is_todo,
                    start_at, end_at, start_date, end_date_exclusive,
                    timezone, version, created_at, updated_at, deleted_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
		e.ID, seriesID, occ, e.Title, e.Notes, e.AllDay, e.IsTodo,
		startAt, endAt, startDate, endDate,
		e.Timezone, e.Version, FormatTS(e.CreatedAt), FormatTS(e.UpdatedAt))
	return err
}

// dbGetEvent 读取单个事件（含系列版本）；deleted_at 非空表示已软删除。
func dbGetEvent(ctx context.Context, q RowQuerier, id string) (Event, error) {
	row := q.QueryRowContext(ctx, eventSelect+` WHERE e.id = ?`, id)
	e, err := scanEvent(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Event{}, ErrNotFound
	}
	if err != nil {
		return Event{}, err
	}
	return e, nil
}

// dbListRange 范围查询：普通事件按 UTC 窗口求交，全天事件按日期求交（文档 7）。
// 待办不关联日期、始终返回。from 含、to 不含；
// ws/we 为窗口边界的 UTC 固定精度文本（字典序即时间序）。
func dbListRange(ctx context.Context, q RowQuerier, ws, we, from, to string) ([]Event, error) {
	rows, err := q.QueryContext(ctx, eventSelect+`
WHERE e.deleted_at IS NULL
  AND (e.is_todo = 1
    OR ((e.all_day = 0 AND e.start_at < ? AND e.end_at > ?)
      OR (e.all_day = 1 AND e.start_date < ? AND e.end_date_exclusive > ?)))`,
		we, ws, to, from)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		e, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// dbListSeriesMembers 读取系列内 occurrence_index >= minIndex 且未删除的成员，
// 按序号升序。"未开始"过滤在领域层按日历时区判断。
func dbListSeriesMembers(ctx context.Context, q RowQuerier, seriesID string, minIndex int64) ([]Event, error) {
	rows, err := q.QueryContext(ctx, eventSelect+`
WHERE e.series_id = ? AND e.occurrence_index >= ? AND e.deleted_at IS NULL
ORDER BY e.occurrence_index`, seriesID, minIndex)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		e, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// dbUpdateEventColumns 全量更新事件的可变列（version 由调用方写入）。
func dbUpdateEventColumns(ctx context.Context, q RowQuerier, e Event) error {
	var startAt, endAt, startDate, endDate, deletedAt any
	if e.StartAt != nil {
		startAt = FormatTS(*e.StartAt)
	}
	if e.EndAt != nil {
		endAt = FormatTS(*e.EndAt)
	}
	if e.StartDate != nil {
		startDate = *e.StartDate
	}
	if e.EndDateExclusive != nil {
		endDate = *e.EndDateExclusive
	}
	if e.DeletedAt != nil {
		deletedAt = FormatTS(*e.DeletedAt)
	}
	res, err := q.ExecContext(ctx, `
UPDATE events SET title = ?, notes = ?, all_day = ?, is_todo = ?, start_at = ?, end_at = ?,
                  start_date = ?, end_date_exclusive = ?, version = ?,
                  updated_at = ?, deleted_at = ?
WHERE id = ?`,
		e.Title, e.Notes, e.AllDay, e.IsTodo, startAt, endAt,
		startDate, endDate, e.Version,
		FormatTS(e.UpdatedAt), deletedAt, e.ID)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func dbGetSeries(ctx context.Context, q RowQuerier, id string) (Series, error) {
	var s Series
	var created, updated string
	err := q.QueryRowContext(ctx, `
SELECT id, interval_weeks, repeat_type, occurrence_count, timezone, version, created_at, updated_at
FROM event_series WHERE id = ?`, id).
		Scan(&s.ID, &s.IntervalWeeks, &s.RepeatType, &s.OccurrenceCount, &s.Timezone, &s.Version, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return Series{}, ErrNotFound
	}
	if err != nil {
		return Series{}, err
	}
	if s.CreatedAt, err = ParseTS(created); err != nil {
		return Series{}, err
	}
	if s.UpdatedAt, err = ParseTS(updated); err != nil {
		return Series{}, err
	}
	return s, nil
}

// dbBumpSeries 任一成员写入时系列版本 +1（文档 6.1）。
func dbBumpSeries(ctx context.Context, q RowQuerier, id string, now time.Time) error {
	_, err := q.ExecContext(ctx,
		`UPDATE event_series SET version = version + 1, updated_at = ? WHERE id = ?`,
		FormatTS(now), id)
	return err
}
