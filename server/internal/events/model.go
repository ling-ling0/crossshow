// Package events 实现事件与重复系列的领域逻辑。
// 日程计算与校验以服务端为准（开发文档 3.2）。
package events

import (
	"time"
)

// 首版能力常量（开发文档 2.2 / 7）。
const (
	MinTitleLength    = 1
	MaxTitleLength    = 200
	MaxNotesLength    = 10000
	MaxRepeatCount    = 520
	MaxQuerySpanDays  = 93
	PreviewDefaultTTL = 5 * time.Minute
)

// Event 事件的领域表示；时间字段一律 UTC，日期字段为日历时区的 YYYY-MM-DD。
type Event struct {
	ID               string     `json:"id"`
	SeriesID         *string    `json:"series_id"`
	OccurrenceIndex  *int64     `json:"occurrence_index"`
	Title            string     `json:"title"`
	Notes            string     `json:"notes"`
	AllDay           bool       `json:"all_day"`
	StartAt          *time.Time `json:"start_at"`           // 普通事件 UTC；全天为空
	EndAt            *time.Time `json:"end_at"`             // 半开区间 [start, end)
	StartDate        *string    `json:"start_date"`         // 全天开始（含）
	EndDateExclusive *string    `json:"end_date_exclusive"` // 全天结束（不含）
	Timezone         string     `json:"timezone"`
	Version          int64      `json:"version"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
	DeletedAt        *time.Time `json:"deleted_at,omitempty"`
	SeriesVersion    *int64     `json:"series_version"`
}

// 重复类型常量（开发文档 2.1，2026-09-15 新增 daily/weekdays）。
const (
	RepeatDaily    = "daily"    // 每天
	RepeatWeekdays = "weekdays" // 工作日（周一至周五）
	RepeatWeekly   = "weekly"   // 每周
	RepeatBiweekly = "biweekly" // 每双周
)

// Series 重复系列。
type Series struct {
	ID              string    `json:"id"`
	RepeatType      string    `json:"repeat_type"`
	IntervalWeeks   int       `json:"interval_weeks"` // weekly=1 / biweekly=2；daily/weekdays 恒为 1（占位）
	OccurrenceCount int       `json:"occurrence_count"`
	Timezone        string    `json:"timezone"`
	Version         int64     `json:"version"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// RepeatSpec 创建时的重复规格；次数包含首次。
// type 为新契约；interval_weeks（1=每周，2=每双周）为旧契约，type 缺省时用于兼容。
type RepeatSpec struct {
	Type          string `json:"type"`
	IntervalWeeks int    `json:"interval_weeks"`
	Count         int    `json:"count"`
}

// ResolveType 归一化重复类型。
func (r *RepeatSpec) ResolveType() (string, error) {
	if r.Type != "" {
		switch r.Type {
		case RepeatDaily, RepeatWeekdays, RepeatWeekly, RepeatBiweekly:
			return r.Type, nil
		default:
			return "", invalid("repeat.type", "重复类型仅支持 daily（每天）、weekdays（工作日）、weekly（每周）、biweekly（每双周）")
		}
	}
	switch r.IntervalWeeks {
	case 1:
		return RepeatWeekly, nil
	case 2:
		return RepeatBiweekly, nil
	}
	return "", invalid("repeat.type", "缺少重复类型（type 或 interval_weeks）")
}

// Changes 批量（本次及以后）修改的字段集合；仅出现的字段参与传播。
type Changes struct {
	Title            *string    `json:"title"`
	Notes            *string    `json:"notes"`
	StartAt          *time.Time `json:"start_at"`
	EndAt            *time.Time `json:"end_at"`
	StartDate        *string    `json:"start_date"`
	EndDateExclusive *string    `json:"end_date_exclusive"`
}

// HasAny 是否至少出现了一个字段。
func (c *Changes) HasAny() bool {
	if c == nil {
		return false
	}
	return c.Title != nil || c.Notes != nil || c.StartAt != nil ||
		c.EndAt != nil || c.StartDate != nil || c.EndDateExclusive != nil
}

// CreateInput POST /api/v1/events 请求体。
type CreateInput struct {
	Title            string      `json:"title"`
	Notes            string      `json:"notes"`
	AllDay           bool        `json:"all_day"`
	StartAt          *time.Time  `json:"start_at"`
	EndAt            *time.Time  `json:"end_at"`
	StartDate        *string     `json:"start_date"`
	EndDateExclusive *string     `json:"end_date_exclusive"`
	Timezone         string      `json:"timezone"`
	Repeat           *RepeatSpec `json:"repeat"`
}

// PatchInput PATCH /api/v1/events/{id} 请求体；仅出现的字段被修改。
type PatchInput struct {
	ExpectedVersion  *int64     `json:"expected_version"`
	Title            *string    `json:"title"`
	Notes            *string    `json:"notes"`
	StartAt          *time.Time `json:"start_at"`
	EndAt            *time.Time `json:"end_at"`
	StartDate        *string    `json:"start_date"`
	EndDateExclusive *string    `json:"end_date_exclusive"`
}

// PreviewInput POST /api/v1/events/{id}/series-change-preview 请求体。
type PreviewInput struct {
	Action          string   `json:"action"` // update | delete
	ExpectedVersion int64    `json:"expected_version"`
	Changes         *Changes `json:"changes"`
}

// CommitInput POST /api/v1/events/{id}/series-change-commit 请求体。
type CommitInput struct {
	Token string `json:"token"`
}

// Idempotency 幂等键与请求摘要（由 HTTP 层计算）。
type Idempotency struct {
	Key  string
	Hash string
}

// ---- 响应结构（对应 api/openapi.yaml） ----

type ConfigResult struct {
	Timezone     string       `json:"timezone"`
	Capabilities Capabilities `json:"capabilities"`
	ServerTime   time.Time    `json:"server_time"`
}

type Capabilities struct {
	MaxRepeatCount   int `json:"max_repeat_count"`
	MaxQuerySpanDays int `json:"max_query_span_days"`
	MinTitleLength   int `json:"min_title_length"`
	MaxTitleLength   int `json:"max_title_length"`
	MaxNotesLength   int `json:"max_notes_length"`
}

type ListResult struct {
	Events     []Event   `json:"events"`
	ServerTime time.Time `json:"server_time"`
}

type CreateResult struct {
	EventIDs   []string  `json:"event_ids"`
	SeriesID   *string   `json:"series_id"`
	Events     []Event   `json:"events"`
	ServerTime time.Time `json:"server_time"`
}

type EventMutationResult struct {
	Event      Event     `json:"event"`
	ServerTime time.Time `json:"server_time"`
}

type SeriesInfo struct {
	ID                 string `json:"id"`
	RepeatType         string `json:"repeat_type"`
	IntervalWeeks      int    `json:"interval_weeks"`
	OccurrenceCount    int    `json:"occurrence_count"`
	Timezone           string `json:"timezone"`
	Version            int64  `json:"version"`
	RemainingAfterView int64  `json:"remaining_after_index"`
}

type EventDetailResult struct {
	Event  Event       `json:"event"`
	Series *SeriesInfo `json:"series"`
}

type PreviewResult struct {
	AffectedCount int       `json:"affected_count"`
	Digest        string    `json:"digest"`
	Token         string    `json:"token"`
	ExpiresAt     time.Time `json:"expires_at"`
	ServerTime    time.Time `json:"server_time"`
}

type CommitResult struct {
	Events     []Event   `json:"events"`
	ServerTime time.Time `json:"server_time"`
}
