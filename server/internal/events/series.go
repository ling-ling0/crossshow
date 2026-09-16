package events

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// ExpandSeries 按重复类型在日历时区的本地日期上生成 count 个独立事件（含首次）。
// 不做固定 UTC 秒数递增：每次 occurrence 保留同一本地墙钟时间（开发文档 5.1）。
// 类型语义：daily +1 天；weekdays 跳过周六周日；weekly/biweekly +7/+14 天。
// first 必须已通过 validateEvent。
func ExpandSeries(first Event, repeatType string, intervalWeeks, count int) ([]Event, error) {
	out := make([]Event, 0, count)
	clone := func(base Event, idx int64) Event {
		e := base
		e.ID = ""
		e.Version = 1
		e.OccurrenceIndex = &idx
		return e
	}

	var firstLocalDate time.Time // 首次发生日的本地日期（零点）
	var durDays int              // 全天事件的天数
	var loc *time.Location
	var wallStart, wallEnd time.Time // 普通事件的本地墙钟起止
	var endDayShift int              // 结束日相对开始日的天数（跨午夜为 1+）

	if first.AllDay {
		d, err := ParseDate(*first.StartDate)
		if err != nil {
			return nil, err
		}
		firstLocalDate = d
		ed, err := ParseDate(*first.EndDateExclusive)
		if err != nil {
			return nil, err
		}
		durDays = int(ed.Sub(d).Hours() / 24)
	} else {
		var err error
		loc, err = time.LoadLocation(first.Timezone)
		if err != nil {
			return nil, invalid("timezone", "无法加载时区 %s", first.Timezone)
		}
		ls := first.StartAt.In(loc)
		le := first.EndAt.In(loc)
		firstLocalDate = time.Date(ls.Year(), ls.Month(), ls.Day(), 0, 0, 0, 0, loc)
		wallStart, wallEnd = ls, le
		endDayShift = int(le.Sub(firstLocalDate).Hours() / 24)
	}

	for i := 0; i < count; i++ {
		e := clone(first, int64(i))
		occ := occurrenceLocalDate(firstLocalDate, repeatType, intervalWeeks, i)
		if first.AllDay {
			sd := occ.Format(DateLayout)
			ed := occ.AddDate(0, 0, durDays).Format(DateLayout)
			e.StartDate = &sd
			e.EndDateExclusive = &ed
		} else {
			// time.Date 对超出当月的天数自动规范化到后续月份（含月末、闰年）。
			st := time.Date(occ.Year(), occ.Month(), occ.Day(),
				wallStart.Hour(), wallStart.Minute(), wallStart.Second(), wallStart.Nanosecond(), loc).UTC()
			enDate := occ.AddDate(0, 0, endDayShift)
			en := time.Date(enDate.Year(), enDate.Month(), enDate.Day(),
				wallEnd.Hour(), wallEnd.Minute(), wallEnd.Second(), wallEnd.Nanosecond(), loc).UTC()
			e.StartAt = &st
			e.EndAt = &en
		}
		out = append(out, e)
	}
	return out, nil
}

// occurrenceLocalDate 计算第 i 次（0 基）发生的本地日期。
func occurrenceLocalDate(first time.Time, repeatType string, intervalWeeks, i int) time.Time {
	switch repeatType {
	case RepeatDaily:
		return first.AddDate(0, 0, i)
	case RepeatWeekdays:
		d := first
		for k := 0; k < i; k++ {
			d = nextWeekday(d)
		}
		return d
	default: // weekly / biweekly
		return first.AddDate(0, 0, 7*intervalWeeks*i)
	}
}

// nextWeekday 返回下一个工作日（跳过周六与周日）。
func nextWeekday(d time.Time) time.Time {
	for {
		d = d.AddDate(0, 0, 1)
		if wd := d.Weekday(); wd != time.Saturday && wd != time.Sunday {
			return d
		}
	}
}

// effectiveChanges 返回"实际改变的字段"：仅当请求值与选中实例当前值不同才传播（文档 5.3）。
func effectiveChanges(sel Event, ch *Changes) Changes {
	var eff Changes
	if ch == nil {
		return eff
	}
	if ch.Title != nil && strings.TrimSpace(*ch.Title) != sel.Title {
		eff.Title = ch.Title
	}
	if ch.Notes != nil && *ch.Notes != sel.Notes {
		eff.Notes = ch.Notes
	}
	if !sel.AllDay {
		if ch.StartAt != nil && !ch.StartAt.UTC().Equal(*sel.StartAt) {
			eff.StartAt = ch.StartAt
		}
		if ch.EndAt != nil && !ch.EndAt.UTC().Equal(*sel.EndAt) {
			eff.EndAt = ch.EndAt
		}
	} else {
		if ch.StartDate != nil && *ch.StartDate != *sel.StartDate {
			eff.StartDate = ch.StartDate
		}
		if ch.EndDateExclusive != nil && *ch.EndDateExclusive != *sel.EndDateExclusive {
			eff.EndDateExclusive = ch.EndDateExclusive
		}
	}
	return eff
}

// ValidateChanges 检查批量修改字段与事件类型匹配，并规范化输入。
func ValidateChanges(sel Event, ch *Changes) error {
	if ch == nil {
		return nil
	}
	if sel.AllDay {
		if ch.StartAt != nil || ch.EndAt != nil {
			return invalid("changes", "全天系列不支持批量修改时间字段（首版不切换全天类型，文档 5.3）")
		}
		if ch.StartDate != nil {
			if _, err := ParseDate(*ch.StartDate); err != nil {
				return invalid("changes.start_date", "开始日期格式需为 YYYY-MM-DD")
			}
		}
		if ch.EndDateExclusive != nil {
			if _, err := ParseDate(*ch.EndDateExclusive); err != nil {
				return invalid("changes.end_date_exclusive", "结束日期格式需为 YYYY-MM-DD")
			}
		}
	} else {
		if ch.StartDate != nil || ch.EndDateExclusive != nil {
			return invalid("changes", "普通系列不支持批量修改日期字段")
		}
		if ch.StartAt != nil {
			*ch.StartAt = ch.StartAt.UTC()
		}
		if ch.EndAt != nil {
			*ch.EndAt = ch.EndAt.UTC()
		}
		if ch.Title != nil && strings.TrimSpace(*ch.Title) == "" {
			return invalid("changes.title", "标题不能为空")
		}
	}
	return nil
}

// ApplyBatch 将实际改变的字段按文档 5.3 的传播规则应用到目标集合，
// 返回修改后的目标副本；不修改输入。任一结果非法则整体报错（调用方在事务中回滚）。
//
// 规则：
//   - 标题／备注：目标集合统一设为新值
//   - 普通事件开始时间：按日历时区计算选中实例新旧本地时间差并应用到各目标；
//     未改时长时各实例保留原时长，改了时长则统一采用新时长
//   - 全天日期：按日期偏移修改；天数变化时统一采用新天数
func ApplyBatch(sel Event, eff Changes, targets []Event) ([]Event, error) {
	if sel.AllDay {
		return applyBatchAllDay(sel, eff, targets)
	}
	return applyBatchTimed(sel, eff, targets)
}

func applyBatchTimed(sel Event, eff Changes, targets []Event) ([]Event, error) {
	startChanged := eff.StartAt != nil
	endChanged := eff.EndAt != nil
	if !startChanged && !endChanged && eff.Title == nil && eff.Notes == nil {
		return targets, nil
	}

	var wallDelta time.Duration // 本地时间差（首版默认时区无夏令时，绝对差即本地差）
	var newDur time.Duration
	if startChanged {
		loc, _ := time.LoadLocation(sel.Timezone)
		oldLocal := sel.StartAt.In(loc)
		newLocal := eff.StartAt.In(loc)
		wallDelta = newLocal.Sub(oldLocal)
	}
	if endChanged {
		newSelStart := sel.StartAt
		if startChanged {
			newSelStart = eff.StartAt
		}
		newDur = eff.EndAt.Sub(*newSelStart)
		if newDur <= 0 {
			return nil, invalid("changes.end_at", "新的结束时间必须晚于开始时间")
		}
	}

	out := make([]Event, len(targets))
	for i, t := range targets {
		e := t
		if eff.Title != nil {
			e.Title = strings.TrimSpace(*eff.Title)
		}
		if eff.Notes != nil {
			e.Notes = *eff.Notes
		}
		if startChanged {
			ns := t.StartAt.Add(wallDelta).UTC()
			e.StartAt = &ns
		}
		switch {
		case endChanged:
			ne := e.StartAt.Add(newDur).UTC()
			e.EndAt = &ne
		case startChanged:
			// 未改时长：各实例保留原时长
			dur := t.EndAt.Sub(*t.StartAt)
			ne := e.StartAt.Add(dur).UTC()
			e.EndAt = &ne
		}
		if err := validateEvent(&e, sel.Timezone); err != nil {
			return nil, err
		}
		out[i] = e
	}
	return out, nil
}

func applyBatchAllDay(sel Event, eff Changes, targets []Event) ([]Event, error) {
	startChanged := eff.StartDate != nil
	endChanged := eff.EndDateExclusive != nil
	if !startChanged && !endChanged && eff.Title == nil && eff.Notes == nil {
		return targets, nil
	}

	offset := 0
	if startChanged {
		d, err := DaysBetween(*sel.StartDate, *eff.StartDate)
		if err != nil {
			return nil, err
		}
		offset = d
	}
	selCount, err := DaysBetween(*sel.StartDate, *sel.EndDateExclusive)
	if err != nil {
		return nil, err
	}
	uniformCount := -1
	if endChanged {
		c, err := DaysBetween(effectiveStart(sel, eff.StartDate), *eff.EndDateExclusive)
		if err != nil {
			return nil, err
		}
		if c != selCount { // 天数变化：统一采用新天数；未变化则各实例保留原天数
			if c <= 0 {
				return nil, invalid("changes.end_date_exclusive", "结束日期（不含）必须晚于开始日期")
			}
			uniformCount = c
		}
	}

	out := make([]Event, len(targets))
	for i, t := range targets {
		e := t
		if eff.Title != nil {
			e.Title = strings.TrimSpace(*eff.Title)
		}
		if eff.Notes != nil {
			e.Notes = *eff.Notes
		}
		ownCount, err := DaysBetween(*t.StartDate, *t.EndDateExclusive)
		if err != nil {
			return nil, err
		}
		if startChanged {
			sd, err := AddDays(*t.StartDate, offset)
			if err != nil {
				return nil, err
			}
			e.StartDate = &sd
		}
		count := ownCount
		if uniformCount >= 0 {
			count = uniformCount
		}
		ed, err := AddDays(*e.StartDate, count)
		if err != nil {
			return nil, err
		}
		e.EndDateExclusive = &ed
		if err := validateEvent(&e, sel.Timezone); err != nil {
			return nil, err
		}
		out[i] = e
	}
	return out, nil
}

func effectiveStart(sel Event, newStart *string) string {
	if newStart != nil {
		return *newStart
	}
	return *sel.StartDate
}

// BatchDigest 生成面向用户的中文操作摘要。
func BatchDigest(action string, count int, eff Changes) string {
	if action == "delete" {
		return fmt.Sprintf("将删除 %d 个事件（本次及以后）", count)
	}
	var parts []string
	if eff.Title != nil {
		parts = append(parts, fmt.Sprintf("标题改为「%s」", truncate(*eff.Title, 20)))
	}
	if eff.Notes != nil {
		parts = append(parts, "更新备注")
	}
	if eff.StartAt != nil {
		parts = append(parts, "平移开始时间")
	}
	if eff.EndAt != nil {
		parts = append(parts, "统一时长")
	}
	if eff.StartDate != nil {
		parts = append(parts, "平移日期")
	}
	if eff.EndDateExclusive != nil {
		parts = append(parts, "调整天数")
	}
	suffix := "（本次及以后）"
	if len(parts) == 0 {
		return fmt.Sprintf("未检测到修改%s", suffix)
	}
	return fmt.Sprintf("将修改 %d 个事件：%s%s", count, strings.Join(parts, "；"), suffix)
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// sortEventsByIndex 按 occurrence_index 排序（目标集合顺序确定性）。
func sortEventsByIndex(evts []Event) {
	sort.SliceStable(evts, func(i, j int) bool {
		return *evts[i].OccurrenceIndex < *evts[j].OccurrenceIndex
	})
}
