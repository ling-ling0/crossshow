package events

import (
	"strings"
	"time"
	"unicode/utf8"
)

// DateLayout 全天事件的日期格式。
const DateLayout = "2006-01-02"

// tsLayout 固定精度的 UTC 时间布局。
// 固定宽度保证 SQLite 文本字典序 == 时间序（范围查询依赖此性质）。
const tsLayout = "2006-01-02T15:04:05.000000000Z07:00"

// FormatTS 统一序列化 UTC 时间。
func FormatTS(t time.Time) string { return t.UTC().Format(tsLayout) }

// ParseTS 解析库中的 UTC 时间文本。
func ParseTS(s string) (time.Time, error) {
	t, err := time.Parse(tsLayout, s)
	if err != nil {
		// 兼容无小数秒格式
		if t2, err2 := time.Parse(time.RFC3339Nano, s); err2 == nil {
			return t2.UTC(), nil
		}
		return time.Time{}, err
	}
	return t.UTC(), nil
}

// ParseDate 解析 YYYY-MM-DD（UTC 午夜，仅用于日期算术）。
func ParseDate(s string) (time.Time, error) {
	return time.ParseInLocation(DateLayout, s, time.UTC)
}

// AddDays 日期字符串加 n 天，返回 YYYY-MM-DD。
func AddDays(date string, n int) (string, error) {
	d, err := ParseDate(date)
	if err != nil {
		return "", err
	}
	return d.AddDate(0, 0, n).Format(DateLayout), nil
}

// DaysBetween 两个日期间的天数（b - a）。
func DaysBetween(a, b string) (int, error) {
	da, err := ParseDate(a)
	if err != nil {
		return 0, err
	}
	db, err := ParseDate(b)
	if err != nil {
		return 0, err
	}
	return int(db.Sub(da).Hours() / 24), nil
}

// validateEvent 校验并规范化事件（原地修剪标题、时间转 UTC）。
// 覆盖开发文档 4.3 / 5.1 / 12 的输入规则。
func validateEvent(e *Event, defaultTZ string) error {
	e.Title = strings.TrimSpace(e.Title)
	if n := utf8.RuneCountInString(e.Title); n < MinTitleLength || n > MaxTitleLength {
		return invalid("title", "标题需为 %d–%d 个字符（去除首尾空白后）", MinTitleLength, MaxTitleLength)
	}
	if utf8.RuneCountInString(e.Notes) > MaxNotesLength {
		return invalid("notes", "备注最多 %d 个字符", MaxNotesLength)
	}
	if e.Timezone != defaultTZ {
		return invalid("timezone", "首版仅支持服务端默认时区 %s", defaultTZ)
	}
	if e.IsTodo { // 待办：没有固定时间的记录，不关联任何日期
		if e.AllDay {
			return invalid("all_day", "待办不使用全天标记：is_todo 与 all_day 互斥")
		}
		if e.StartAt != nil || e.EndAt != nil || e.StartDate != nil || e.EndDateExclusive != nil {
			return invalid("is_todo", "待办不接受开始/结束时间或日期字段")
		}
		return nil
	}
	if e.AllDay {
		if e.StartAt != nil || e.EndAt != nil {
			return invalid("start_at", "全天事件不接受时间字段")
		}
		if e.StartDate == nil || e.EndDateExclusive == nil {
			return invalid("start_date", "全天事件必须提供开始日期与结束日期（不含）")
		}
		if _, err := ParseDate(*e.StartDate); err != nil {
			return invalid("start_date", "开始日期格式需为 YYYY-MM-DD")
		}
		if _, err := ParseDate(*e.EndDateExclusive); err != nil {
			return invalid("end_date_exclusive", "结束日期格式需为 YYYY-MM-DD")
		}
		if *e.EndDateExclusive <= *e.StartDate {
			return invalid("end_date_exclusive", "结束日期（不含）必须晚于开始日期")
		}
	} else {
		if e.StartDate != nil || e.EndDateExclusive != nil {
			return invalid("start_date", "普通事件不接受日期字段")
		}
		if e.StartAt == nil || e.EndAt == nil {
			return invalid("start_at", "普通事件必须提供开始与结束时间")
		}
		*e.StartAt = e.StartAt.UTC()
		*e.EndAt = e.EndAt.UTC()
		if !e.EndAt.After(*e.StartAt) {
			return invalid("end_at", "结束时间必须晚于开始时间")
		}
	}
	return nil
}

// validateRepeat 校验重复规格：类型归一化 + 次数范围。
func validateRepeat(r *RepeatSpec) error {
	if _, err := r.ResolveType(); err != nil {
		return err
	}
	if r.Count < 1 || r.Count > MaxRepeatCount {
		return invalid("repeat.count", "重复次数需在 1–%d 之间", MaxRepeatCount)
	}
	return nil
}

// startInstant 事件在日历时区的开始时刻（UTC）。
// 全天事件取开始日期当天的日历零点；用于"是否已开始"判断（开发文档 5.3）。
func (s *Service) startInstant(e Event, loc *time.Location) time.Time {
	if e.AllDay {
		d, err := ParseDate(*e.StartDate)
		if err != nil {
			return time.Time{}
		}
		return time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, loc).UTC()
	}
	return e.StartAt.UTC()
}

// isStarted 进行中或已开始均视为"已开始"（文档 5.3：进行中的事件默认不参与批量修改）。
// 2026-09-15 变更后仅保留语义用途；批量目标集合过滤改用 hasEnded。
func (s *Service) isStarted(e Event, loc *time.Location, now time.Time) bool {
	inst := s.startInstant(e, loc)
	return !inst.After(now)
}

// endInstant 事件在日历时区的结束时刻（UTC）。
// 全天事件取结束日期（不含）当天的日历零点，即结束日的 00:00（等于前一日 24:00）。
func (s *Service) endInstant(e Event, loc *time.Location) time.Time {
	if e.AllDay {
		d, err := ParseDate(*e.EndDateExclusive)
		if err != nil {
			return time.Time{}
		}
		return time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, loc).UTC()
	}
	return e.EndAt.UTC()
}

// hasEnded 事件是否已结束（进行中未结束，可参与批量修改）。
func (s *Service) hasEnded(e Event, loc *time.Location, now time.Time) bool {
	return !s.endInstant(e, loc).After(now)
}
