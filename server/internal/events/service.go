package events

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Service 编排业务事务：幂等记录与业务变更在同一事务中保存（文档 6.3 / 7）。
type Service struct {
	DB          *sql.DB
	DefaultTZ   string
	Now         func() time.Time
	PreviewTTL  time.Duration
	tokenSecret []byte
}

func NewService(db *sql.DB, defaultTZ string, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	return &Service{
		DB:          db,
		DefaultTZ:   defaultTZ,
		Now:         now,
		PreviewTTL:  PreviewDefaultTTL,
		tokenSecret: newTokenSecret(),
	}
}

func (s *Service) loc() *time.Location {
	l, err := time.LoadLocation(s.DefaultTZ)
	if err != nil {
		// 启动时已校验；兜底不 panic
		return time.UTC
	}
	return l
}

// mapErr 统一转换存储错误为领域错误。
func mapErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, ErrNotFound) {
		return ErrNotFound
	}
	var ve *ValidationError
	if errors.As(err, &ve) {
		return ve
	}
	if isBusy(err) {
		return fmt.Errorf("%w: %v", ErrBusy, err)
	}
	return err
}

func isBusy(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "database is locked") ||
		strings.Contains(msg, "SQLITE_BUSY") ||
		strings.Contains(msg, "database table is locked")
}

// runWrite 幂等写事务骨架：
// 命中相同键+相同摘要 → 返回原结果；相同键不同摘要 → 冲突；
// 否则执行业务并在同一事务写入幂等记录后提交。
func (s *Service) runWrite(ctx context.Context, idem Idempotency, fn func(tx *sql.Tx) (int, any, error)) (int, []byte, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, nil, mapErr(err)
	}
	defer tx.Rollback() // Commit 后为无害的 ErrTxDone

	var hash string
	var status int
	var body sql.NullString
	err = tx.QueryRowContext(ctx,
		`SELECT request_hash, response_status, response_body FROM idempotency_records WHERE idempotency_key = ?`,
		idem.Key).Scan(&hash, &status, &body)
	switch {
	case err == nil:
		if hash != idem.Hash {
			return 0, nil, ErrIdempotencyConflict
		}
		return status, []byte(body.String), nil
	case errors.Is(err, sql.ErrNoRows):
		// 首次请求，继续
	default:
		return 0, nil, mapErr(err)
	}

	st, resp, err := fn(tx)
	if err != nil {
		return 0, nil, mapErr(err)
	}
	out, err := json.Marshal(resp)
	if err != nil {
		return 0, nil, mapErr(err)
	}
	_, err = tx.ExecContext(ctx,
		`INSERT INTO idempotency_records (idempotency_key, request_hash, response_status, response_body, created_at)
		 VALUES (?, ?, ?, ?, ?)`,
		idem.Key, idem.Hash, st, string(out), FormatTS(s.Now().UTC()))
	if err != nil {
		return 0, nil, mapErr(err)
	}
	if err := tx.Commit(); err != nil {
		return 0, nil, mapErr(err)
	}
	return st, out, nil
}

// ---- 查询 ----

func (s *Service) Config() ConfigResult {
	return ConfigResult{
		Timezone: s.DefaultTZ,
		Capabilities: Capabilities{
			MaxRepeatCount:   MaxRepeatCount,
			MaxQuerySpanDays: MaxQuerySpanDays,
			MinTitleLength:   MinTitleLength,
			MaxTitleLength:   MaxTitleLength,
			MaxNotesLength:   MaxNotesLength,
		},
		ServerTime: s.Now().UTC(),
	}
}

func (s *Service) Get(ctx context.Context, id string) (EventDetailResult, error) {
	e, err := dbGetEvent(ctx, s.DB, id)
	if err != nil {
		return EventDetailResult{}, mapErr(err)
	}
	if e.DeletedAt != nil {
		return EventDetailResult{}, ErrNotFound
	}
	result := EventDetailResult{Event: e}
	if e.SeriesID != nil && e.OccurrenceIndex != nil {
		series, err := dbGetSeries(ctx, s.DB, *e.SeriesID)
		if err != nil {
			return EventDetailResult{}, mapErr(err)
		}
		members, err := dbListSeriesMembers(ctx, s.DB, *e.SeriesID, *e.OccurrenceIndex)
		if err != nil {
			return EventDetailResult{}, mapErr(err)
		}
		now, loc := s.Now().UTC(), s.loc()
		var remaining int64
		for _, m := range members {
			if !s.hasEnded(m, loc, now) {
				remaining++
			}
		}
		result.Series = &SeriesInfo{
			ID:                 series.ID,
			RepeatType:         series.RepeatType,
			IntervalWeeks:      series.IntervalWeeks,
			OccurrenceCount:    series.OccurrenceCount,
			Timezone:           series.Timezone,
			Version:            series.Version,
			RemainingAfterView: remaining,
		}
	}
	return result, nil
}

func (s *Service) ListRange(ctx context.Context, from, to string) (ListResult, error) {
	fromT, err := ParseDate(from)
	if err != nil {
		return ListResult{}, invalid("from", "from 需为 YYYY-MM-DD")
	}
	toT, err := ParseDate(to)
	if err != nil {
		return ListResult{}, invalid("to", "to 需为 YYYY-MM-DD")
	}
	if toT.Before(fromT) {
		return ListResult{}, invalid("to", "to 必须不早于 from")
	}
	spanDays := int(toT.Sub(fromT).Hours() / 24)
	if spanDays > MaxQuerySpanDays {
		return ListResult{}, invalid("to", "单次查询跨度不能超过 %d 天", MaxQuerySpanDays)
	}
	loc := s.loc()
	ws := time.Date(fromT.Year(), fromT.Month(), fromT.Day(), 0, 0, 0, 0, loc).UTC()
	we := time.Date(toT.Year(), toT.Month(), toT.Day(), 0, 0, 0, 0, loc).UTC()
	list, err := dbListRange(ctx, s.DB, FormatTS(ws), FormatTS(we), from, to)
	if err != nil {
		return ListResult{}, mapErr(err)
	}
	sort.SliceStable(list, func(i, j int) bool {
		ki, kj := s.localStartKey(list[i]), s.localStartKey(list[j])
		if ki != kj {
			return ki < kj
		}
		return list[i].ID < list[j].ID
	})
	return ListResult{Events: list, ServerTime: s.Now().UTC()}, nil
}

// localStartKey 按日历时区的本地开始时间排序（全天为当天零点）。
func (s *Service) localStartKey(e Event) string {
	if e.AllDay && e.StartDate != nil {
		return *e.StartDate + "T00:00"
	}
	if e.StartAt != nil {
		return e.StartAt.In(s.loc()).Format("2006-01-02T15:04:05")
	}
	return ""
}

// ---- 创建 ----

func (s *Service) Create(ctx context.Context, in CreateInput, idem Idempotency) (int, []byte, error) {
	return s.runWrite(ctx, idem, func(tx *sql.Tx) (int, any, error) {
		return s.createTx(ctx, tx, in)
	})
}

func (s *Service) createTx(ctx context.Context, tx *sql.Tx, in CreateInput) (int, any, error) {
	now := s.Now().UTC()
	e := Event{
		ID:               uuid.NewString(),
		Title:            in.Title,
		Notes:            in.Notes,
		AllDay:           in.AllDay,
		IsTodo:           in.IsTodo,
		StartAt:          in.StartAt,
		EndAt:            in.EndAt,
		StartDate:        in.StartDate,
		EndDateExclusive: in.EndDateExclusive,
		Timezone:         in.Timezone,
		Version:          1,
		CreatedAt:        now,
		UpdatedAt:        now,
	}
	if err := validateEvent(&e, s.DefaultTZ); err != nil {
		return 0, nil, err
	}

	if in.IsTodo && in.Repeat != nil { // 待办无固定时间，不参与重复
		return 0, nil, invalid("repeat", "待办不支持重复")
	}

	if in.Repeat == nil { // 单次事件：无 series_id（文档 5.2）
		if err := dbInsertEvent(ctx, tx, e); err != nil {
			return 0, nil, err
		}
		return 201, CreateResult{EventIDs: []string{e.ID}, Events: []Event{e}, ServerTime: now}, nil
	}

	if err := validateRepeat(in.Repeat); err != nil {
		return 0, nil, err
	}
	repeatType, err := in.Repeat.ResolveType()
	if err != nil {
		return 0, nil, err
	}
	// interval_weeks：weekly/biweekly 记录实际间隔；daily/weekdays 恒为 1（占位）
	weeks := in.Repeat.IntervalWeeks
	if in.Repeat.Type != "" || weeks != 1 && weeks != 2 {
		switch repeatType {
		case RepeatBiweekly:
			weeks = 2
		default:
			weeks = 1
		}
	}
	series := Series{
		ID:              uuid.NewString(),
		RepeatType:      repeatType,
		IntervalWeeks:   weeks,
		OccurrenceCount: in.Repeat.Count,
		Timezone:        s.DefaultTZ,
		Version:         1,
		CreatedAt:       now,
		UpdatedAt:       now,
	}
	if err := dbInsertSeries(ctx, tx, series); err != nil {
		return 0, nil, err
	}
	e.SeriesID = &series.ID
	list, err := ExpandSeries(e, repeatType, series.IntervalWeeks, series.OccurrenceCount)
	if err != nil {
		return 0, nil, err
	}
	ids := make([]string, 0, len(list))
	for i := range list {
		list[i].ID = uuid.NewString()
		list[i].SeriesID = &series.ID
		list[i].CreatedAt, list[i].UpdatedAt = now, now
		list[i].SeriesVersion = &series.Version
		if err := dbInsertEvent(ctx, tx, list[i]); err != nil {
			return 0, nil, err
		}
		ids = append(ids, list[i].ID)
	}
	return 201, CreateResult{EventIDs: ids, SeriesID: &series.ID, Events: list, ServerTime: now}, nil
}

// ---- 单次修改 / 删除 ----

func (s *Service) Patch(ctx context.Context, id string, in PatchInput, idem Idempotency) (int, []byte, error) {
	return s.runWrite(ctx, idem, func(tx *sql.Tx) (int, any, error) {
		return s.patchTx(ctx, tx, id, in)
	})
}

func (s *Service) patchTx(ctx context.Context, tx *sql.Tx, id string, in PatchInput) (int, any, error) {
	if in.ExpectedVersion == nil {
		return 0, nil, invalid("expected_version", "缺少 expected_version")
	}
	e, err := dbGetEvent(ctx, tx, id)
	if err != nil {
		return 0, nil, err
	}
	if e.DeletedAt != nil {
		return 0, nil, ErrNotFound
	}
	if *in.ExpectedVersion != e.Version {
		return 0, nil, ErrVersionConflict
	}

	providesTimes := in.StartAt != nil || in.EndAt != nil
	providesDates := in.StartDate != nil || in.EndDateExclusive != nil
	if providesTimes && providesDates {
		return 0, nil, invalid("body", "时间字段与日期字段不能同时提供（类型切换需分别提交）")
	}
	if !providesTimes && !providesDates && in.Title == nil && in.Notes == nil {
		return 0, nil, invalid("body", "至少提供一个修改字段")
	}
	if providesTimes { // 单次切换到普通事件（文档 5.3：单次可切换类型）
		e.AllDay = false
		if in.StartAt != nil {
			e.StartAt = in.StartAt
		}
		if in.EndAt != nil {
			e.EndAt = in.EndAt
		}
		e.StartDate, e.EndDateExclusive = nil, nil
	} else if providesDates { // 单次切换到全天
		e.AllDay = true
		if in.StartDate != nil {
			e.StartDate = in.StartDate
		}
		if in.EndDateExclusive != nil {
			e.EndDateExclusive = in.EndDateExclusive
		}
		e.StartAt, e.EndAt = nil, nil
	}
	if in.Title != nil {
		e.Title = *in.Title
	}
	if in.Notes != nil {
		e.Notes = *in.Notes
	}
	if err := validateEvent(&e, s.DefaultTZ); err != nil {
		return 0, nil, err
	}

	now := s.Now().UTC()
	e.Version++
	e.UpdatedAt = now
	if err := dbUpdateEventColumns(ctx, tx, e); err != nil {
		return 0, nil, err
	}
	if e.SeriesID != nil { // 任一成员写入时系列版本增加（文档 6.1）
		if err := dbBumpSeries(ctx, tx, *e.SeriesID, now); err != nil {
			return 0, nil, err
		}
	}
	e, err = dbGetEvent(ctx, tx, id)
	if err != nil {
		return 0, nil, err
	}
	return 200, EventMutationResult{Event: e, ServerTime: now}, nil
}

func (s *Service) Delete(ctx context.Context, id string, expectedVersion int64, idem Idempotency) (int, []byte, error) {
	return s.runWrite(ctx, idem, func(tx *sql.Tx) (int, any, error) {
		e, err := dbGetEvent(ctx, tx, id)
		if err != nil {
			return 0, nil, err
		}
		if e.DeletedAt != nil {
			return 0, nil, ErrNotFound
		}
		if expectedVersion != e.Version {
			return 0, nil, ErrVersionConflict
		}
		now := s.Now().UTC()
		e.Version++
		e.UpdatedAt = now
		delAt := now
		e.DeletedAt = &delAt
		if err := dbUpdateEventColumns(ctx, tx, e); err != nil {
			return 0, nil, err
		}
		if e.SeriesID != nil {
			if err := dbBumpSeries(ctx, tx, *e.SeriesID, now); err != nil {
				return 0, nil, err
			}
		}
		return 200, EventMutationResult{Event: e, ServerTime: now}, nil
	})
}

// ---- 本次及以后：预览与提交 ----

// targetSet 目标集合 = 同系列 occurrence_index 不小于选中、未删除且未结束的事件
// （进行中未结束，参与批量修改；文档 5.3，2026-09-15 放宽）。
func (s *Service) targetSet(ctx context.Context, q RowQuerier, seriesID string, minIndex int64) ([]Event, error) {
	members, err := dbListSeriesMembers(ctx, q, seriesID, minIndex)
	if err != nil {
		return nil, err
	}
	now, loc := s.Now().UTC(), s.loc()
	var out []Event
	for _, m := range members {
		if !s.hasEnded(m, loc, now) {
			out = append(out, m)
		}
	}
	return out, nil
}

func (s *Service) PreviewSeriesChange(ctx context.Context, id string, in PreviewInput, idem Idempotency) (int, []byte, error) {
	return s.runWrite(ctx, idem, func(tx *sql.Tx) (int, any, error) {
		return s.previewTx(ctx, tx, id, in)
	})
}

func (s *Service) previewTx(ctx context.Context, tx *sql.Tx, id string, in PreviewInput) (int, any, error) {
	if in.Action != "update" && in.Action != "delete" {
		return 0, nil, invalid("action", "action 仅支持 update 或 delete")
	}
	if in.Action == "update" && !in.Changes.HasAny() {
		return 0, nil, invalid("changes", "update 至少提供一个修改字段")
	}
	if in.Action == "delete" && in.Changes != nil {
		return 0, nil, invalid("changes", "delete 不接受 changes")
	}
	e, err := dbGetEvent(ctx, tx, id)
	if err != nil {
		return 0, nil, err
	}
	if e.DeletedAt != nil {
		return 0, nil, ErrNotFound
	}
	if e.SeriesID == nil || e.OccurrenceIndex == nil {
		return 0, nil, invalid("id", "非重复事件不支持「本次及以后」操作")
	}
	if in.ExpectedVersion != e.Version {
		return 0, nil, ErrVersionConflict
	}
	now, loc := s.Now().UTC(), s.loc()
	if s.hasEnded(e, loc, now) {
		// 已结束（过去）的事件仅允许「仅本次」；进行中可发起批量（文档 5.3）
		return 0, nil, invalid("id", "已结束的事件仅支持「仅本次」修改，请选择一个未结束的事件发起批量操作")
	}

	series, err := dbGetSeries(ctx, tx, *e.SeriesID)
	if err != nil {
		return 0, nil, err
	}
	targets, err := s.targetSet(ctx, tx, *e.SeriesID, *e.OccurrenceIndex)
	if err != nil {
		return 0, nil, err
	}
	if len(targets) == 0 {
		return 0, nil, invalid("id", "没有可修改的未来事件")
	}

	var eff Changes
	if in.Action == "update" {
		if err := ValidateChanges(e, in.Changes); err != nil {
			return 0, nil, err
		}
		eff = effectiveChanges(e, in.Changes)
		if _, err := ApplyBatch(e, eff, targets); err != nil { // 预演校验结果合法性
			return 0, nil, err
		}
	}

	ids := make([]string, len(targets))
	for i, t := range targets {
		ids[i] = t.ID
	}
	claims := previewClaims{
		SeriesID:    series.ID,
		SelEventID:  e.ID,
		SelIndex:    *e.OccurrenceIndex,
		Action:      in.Action,
		Changes:     &eff,
		AffectedIDs: ids,
		SeriesVer:   series.Version,
		Exp:         now.Add(s.PreviewTTL).Unix(),
	}
	token, err := signToken(s.tokenSecret, claims)
	if err != nil {
		return 0, nil, err
	}
	return 200, PreviewResult{
		AffectedCount: len(targets),
		Digest:        BatchDigest(in.Action, len(targets), eff),
		Token:         token,
		ExpiresAt:     now.Add(s.PreviewTTL),
		ServerTime:    now,
	}, nil
}

func (s *Service) CommitSeriesChange(ctx context.Context, id string, in CommitInput, idem Idempotency) (int, []byte, error) {
	return s.runWrite(ctx, idem, func(tx *sql.Tx) (int, any, error) {
		return s.commitTx(ctx, tx, id, in)
	})
}

func (s *Service) commitTx(ctx context.Context, tx *sql.Tx, id string, in CommitInput) (int, any, error) {
	now := s.Now().UTC()
	claims, err := verifyToken(s.tokenSecret, in.Token, now)
	if err != nil {
		return 0, nil, fmt.Errorf("%w: %v", ErrPreviewExpired, err)
	}
	if claims.SelEventID != id {
		return 0, nil, fmt.Errorf("%w: 令牌与所选事件不一致", ErrPreviewExpired)
	}
	series, err := dbGetSeries(ctx, tx, claims.SeriesID)
	if err != nil {
		return 0, nil, fmt.Errorf("%w: 系列不存在或已被修改", ErrPreviewExpired)
	}
	if series.Version != claims.SeriesVer { // 版本改变 → 预览失效（文档 5.3）
		return 0, nil, fmt.Errorf("%w: 系列已被其他设备修改", ErrPreviewExpired)
	}

	targets, err := s.targetSet(ctx, tx, claims.SeriesID, claims.SelIndex)
	if err != nil {
		return 0, nil, err
	}
	ids := make([]string, len(targets))
	for i, t := range targets {
		ids[i] = t.ID
	}
	if !equalStrings(ids, claims.AffectedIDs) { // 成员变化 → 预览失效
		return 0, nil, fmt.Errorf("%w: 系列成员已变化", ErrPreviewExpired)
	}

	switch claims.Action {
	case "delete":
		for i := range targets {
			t := targets[i]
			t.Version++
			t.UpdatedAt = now
			delAt := now
			t.DeletedAt = &delAt
			if err := dbUpdateEventColumns(ctx, tx, t); err != nil {
				return 0, nil, err
			}
		}
	case "update":
		if len(targets) == 0 || *targets[0].OccurrenceIndex != claims.SelIndex {
			return 0, nil, fmt.Errorf("%w: 选中事件已不可用", ErrPreviewExpired)
		}
		updated, err := ApplyBatch(targets[0], *claims.Changes, targets)
		if err != nil {
			return 0, nil, err
		}
		for i := range updated {
			updated[i].Version++
			updated[i].UpdatedAt = now
			if err := dbUpdateEventColumns(ctx, tx, updated[i]); err != nil {
				return 0, nil, err
			}
		}
	default:
		return 0, nil, fmt.Errorf("%w: 未知操作 %q", ErrPreviewExpired, claims.Action)
	}

	if err := dbBumpSeries(ctx, tx, series.ID, now); err != nil {
		return 0, nil, err
	}
	out := make([]Event, 0, len(ids))
	for _, tid := range ids {
		e, err := dbGetEvent(ctx, tx, tid)
		if err != nil {
			return 0, nil, err
		}
		out = append(out, e)
	}
	return 200, CommitResult{Events: out, ServerTime: now}, nil
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
