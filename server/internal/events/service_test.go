package events

// 领域层集成测试：使用真实临时 SQLite（开发文档 12：后端以规则单元测试和
// 真实临时 SQLite 的集成测试为主）。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"crossshow/server/internal/storage"
)

// fakeClock 可拨动的时钟，测试"已开始"边界与预览过期。
type fakeClock struct{ t time.Time }

func (c *fakeClock) Now() time.Time { return c.t }
func (c *fakeClock) Add(d time.Duration) {
	c.t = c.t.Add(d)
}

func newTestService(t *testing.T) (*Service, *fakeClock) {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("打开临时数据库: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if err := storage.Migrate(context.Background(), db.DB); err != nil {
		t.Fatalf("执行迁移: %v", err)
	}
	// 2026-09-14 00:30 上海时间（UTC+8），即 2026-09-13T16:30:00Z
	clock := &fakeClock{t: time.Date(2026, 9, 13, 16, 30, 0, 0, time.UTC)}
	return NewService(db.DB, "Asia/Shanghai", clock.Now), clock
}

// ---- Service 调用辅助：封装 (status, body, err) 三值返回 ----

func svcCreate(t *testing.T, s *Service, in CreateInput) (CreateResult, error) {
	t.Helper()
	key := RandHex()
	status, body, err := s.Create(context.Background(), in, Idempotency{Key: key, Hash: key})
	if err != nil {
		return CreateResult{}, err
	}
	if status != 201 {
		t.Fatalf("创建状态码 = %d, 期望 201", status)
	}
	var res CreateResult
	if err := json.Unmarshal(body, &res); err != nil {
		t.Fatalf("解析创建响应: %v", err)
	}
	return res, nil
}

func mustCreate(t *testing.T, s *Service, in CreateInput) CreateResult {
	t.Helper()
	res, err := svcCreate(t, s, in)
	if err != nil {
		t.Fatalf("创建失败: %v", err)
	}
	return res
}

func callPreview(t *testing.T, s *Service, id string, in PreviewInput) (PreviewResult, error) {
	t.Helper()
	_, body, err := s.PreviewSeriesChange(context.Background(), id, in, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != nil {
		return PreviewResult{}, err
	}
	var res PreviewResult
	if err := json.Unmarshal(body, &res); err != nil {
		t.Fatalf("解析预览响应: %v", err)
	}
	return res, nil
}

func callCommit(s *Service, id, token string) error {
	_, _, err := s.CommitSeriesChange(context.Background(), id, CommitInput{Token: token},
		Idempotency{Key: RandHex(), Hash: RandHex()})
	return err
}

func timedInput(title string, startLocal string, dur time.Duration, repeat *RepeatSpec) CreateInput {
	// startLocal: 上海时间 "2006-01-02 15:04"
	loc, _ := time.LoadLocation("Asia/Shanghai")
	st, err := time.ParseInLocation("2006-01-02 15:04", startLocal, loc)
	if err != nil {
		panic(err)
	}
	en := st.Add(dur)
	return CreateInput{
		Title:    title,
		AllDay:   false,
		StartAt:  &st,
		EndAt:    &en,
		Timezone: "Asia/Shanghai",
		Repeat:   repeat,
	}
}

func allDayInput(title, start, endExcl string, repeat *RepeatSpec) CreateInput {
	sd, ed := start, endExcl
	return CreateInput{
		Title:            title,
		AllDay:           true,
		StartDate:        &sd,
		EndDateExclusive: &ed,
		Timezone:         "Asia/Shanghai",
		Repeat:           repeat,
	}
}

// todoInput 待办（没有固定时间的记录）：不携带任何日期/时间字段。
func todoInput(title string) CreateInput {
	return CreateInput{
		Title:    title,
		Notes:    "",
		AllDay:   false,
		IsTodo:   true,
		Timezone: "Asia/Shanghai",
	}
}

func getEvent(t *testing.T, s *Service, id string) Event {
	t.Helper()
	e, err := dbGetEvent(context.Background(), s.DB, id)
	if err != nil {
		t.Fatalf("读取事件 %s: %v", id, err)
	}
	return e
}

func seriesOf(t *testing.T, s *Service, res CreateResult) []Event {
	t.Helper()
	out := make([]Event, 0, len(res.Events))
	for _, e := range res.Events {
		out = append(out, getEvent(t, s, e.ID))
	}
	return out
}

// ---- 创建与校验（文档 12：事件校验 / 重复 / 日期边界） ----

func TestCreateSingleEvent(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", 90*time.Minute, nil))
	if len(res.EventIDs) != 1 || res.SeriesID != nil {
		t.Fatalf("单次事件不应有系列: %+v", res)
	}
	e := getEvent(t, s, res.EventIDs[0])
	if e.Version != 1 || e.SeriesID != nil {
		t.Fatalf("单次事件字段错误: %+v", e)
	}
	// 上海 09:00 == UTC 01:00
	want := time.Date(2026, 9, 14, 1, 0, 0, 0, time.UTC)
	if !e.StartAt.Equal(want) {
		t.Fatalf("StartAt = %v, 期望 %v", e.StartAt, want)
	}
}

func TestCreateValidation(t *testing.T) {
	s, _ := newTestService(t)
	badTZ := timedInput("x", "2026-09-14 09:00", time.Hour, nil)
	badTZ.Timezone = "America/New_York"
	allDayWithTime := timedInput("x", "2026-09-14 09:00", time.Hour, nil)
	allDayWithTime.AllDay = true
	noDates := allDayInput("x", "2026-09-14", "2026-09-15", nil)
	noDates.EndDateExclusive = nil

	cases := []struct {
		name string
		in   CreateInput
	}{
		{"空标题", timedInput("   ", "2026-09-14 09:00", time.Hour, nil)},
		{"结束早于开始", timedInput("x", "2026-09-14 09:00", -time.Hour, nil)},
		{"结束等于开始（半开区间不允许零时长）", timedInput("x", "2026-09-14 09:00", 0, nil)},
		{"非法时区", badTZ},
		{"全天缺日期", noDates},
		{"全天结束不晚于开始", allDayInput("x", "2026-09-15", "2026-09-15", nil)},
		{"全天带时间字段", allDayWithTime},
		{"重复次数 0", timedInput("x", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 0})},
		{"重复次数超上限", timedInput("x", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: MaxRepeatCount + 1})},
		{"非法间隔", timedInput("x", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 3, Count: 4})},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := svcCreate(t, s, tc.in)
			var ve *ValidationError
			if !errors.As(err, &ve) {
				t.Fatalf("期望 ValidationError, 实际 %v", err)
			}
		})
	}
}

func TestRepeatSeriesExpansion(t *testing.T) {
	s, _ := newTestService(t)

	t.Run("每周16次", func(t *testing.T) {
		res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", 90*time.Minute, &RepeatSpec{IntervalWeeks: 1, Count: 16}))
		if res.SeriesID == nil || len(res.EventIDs) != 16 {
			t.Fatalf("应生成 16 个事件, 实际 %d", len(res.EventIDs))
		}
		list := seriesOf(t, s, res)
		for i, e := range list {
			if e.OccurrenceIndex == nil || *e.OccurrenceIndex != int64(i) {
				t.Fatalf("occurrence_index 错误: %+v", e)
			}
		}
		// 第 16 次 = 15 周后 = 2026-12-28（跨年末仍正确）
		last := list[15]
		want := time.Date(2026, 12, 28, 1, 0, 0, 0, time.UTC)
		if !last.StartAt.Equal(want) {
			t.Fatalf("第16次开始 = %v, 期望 %v（含年末边界）", last.StartAt, want)
		}
		if last.SeriesVersion == nil || *last.SeriesVersion != 1 {
			t.Fatalf("系列版本错误: %+v", last)
		}
	})

	t.Run("每双周", func(t *testing.T) {
		res := mustCreate(t, s, timedInput("双周会", "2026-09-14 10:00", time.Hour, &RepeatSpec{IntervalWeeks: 2, Count: 3}))
		list := seriesOf(t, s, res)
		// 间隔 14 天: 09-14, 09-28, 10-12（跨月）
		wantStarts := []time.Time{
			time.Date(2026, 9, 14, 2, 0, 0, 0, time.UTC),
			time.Date(2026, 9, 28, 2, 0, 0, 0, time.UTC),
			time.Date(2026, 10, 12, 2, 0, 0, 0, time.UTC),
		}
		for i, w := range wantStarts {
			if !list[i].StartAt.Equal(w) {
				t.Fatalf("第%d次 = %v, 期望 %v", i, list[i].StartAt, w)
			}
		}
	})

	t.Run("月末规范化", func(t *testing.T) {
		// 1月31日每周 → 1/31, 2/7（+7 天规范化）
		res := mustCreate(t, s, timedInput("月末", "2026-01-31 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 2}))
		list := seriesOf(t, s, res)
		want2nd := time.Date(2026, 2, 7, 1, 0, 0, 0, time.UTC)
		if !list[1].StartAt.Equal(want2nd) {
			t.Fatalf("月末 +7 天 = %v, 期望 %v", list[1].StartAt, want2nd)
		}
	})

	t.Run("闰日", func(t *testing.T) {
		// 2028-02-22 每周 → 第二次应落在闰日 2028-02-29
		res := mustCreate(t, s, timedInput("闰日", "2028-02-22 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 2}))
		list := seriesOf(t, s, res)
		want := time.Date(2028, 2, 29, 1, 0, 0, 0, time.UTC)
		if !list[1].StartAt.Equal(want) {
			t.Fatalf("2028-02-22 + 7 天 = %v, 期望闰日 %v", list[1].StartAt, want)
		}
	})

	t.Run("全天跨多日系列", func(t *testing.T) {
		res := mustCreate(t, s, allDayInput("培训", "2026-09-28", "2026-10-01", &RepeatSpec{IntervalWeeks: 2, Count: 2}))
		list := seriesOf(t, s, res)
		// 第二次开始 = 09-28 + 14 = 10-12，结束（不含）= 10-15；跨十月边界
		if *list[1].StartDate != "2026-10-12" || *list[1].EndDateExclusive != "2026-10-15" {
			t.Fatalf("全天系列第二次 = %s ~ %s", *list[1].StartDate, *list[1].EndDateExclusive)
		}
	})

	t.Run("每天跨月末", func(t *testing.T) {
		res := mustCreate(t, s, timedInput("日报", "2026-01-31 09:00", 30*time.Minute, &RepeatSpec{Type: RepeatDaily, Count: 3}))
		list := seriesOf(t, s, res)
		want := []time.Time{
			time.Date(2026, 1, 31, 1, 0, 0, 0, time.UTC),
			time.Date(2026, 2, 1, 1, 0, 0, 0, time.UTC),
			time.Date(2026, 2, 2, 1, 0, 0, 0, time.UTC),
		}
		for i, w := range want {
			if !list[i].StartAt.Equal(w) {
				t.Fatalf("第%d天 = %v, 期望 %v", i, list[i].StartAt, w)
			}
		}
	})

	t.Run("工作日跳过周末", func(t *testing.T) {
		// 2026-09-18 是周五：后续 occurrence 应为 9/21（周一）、9/22（周二）
		res := mustCreate(t, s, timedInput("站会", "2026-09-18 09:00", 30*time.Minute, &RepeatSpec{Type: RepeatWeekdays, Count: 4}))
		list := seriesOf(t, s, res)
		wantDays := []string{"2026-09-18", "2026-09-21", "2026-09-22", "2026-09-23"}
		loc, _ := time.LoadLocation("Asia/Shanghai")
		for i, d := range wantDays {
			got := list[i].StartAt.In(loc).Format(DateLayout)
			if got != d {
				t.Fatalf("第%d次 = %s, 期望 %s", i, got, d)
			}
		}
	})

	t.Run("工作日跨周末与月份", func(t *testing.T) {
		// 从周四起连续 4 个工作日：周四、周五、下周一、下周二（跨周且跨月检查）
		res := mustCreate(t, s, timedInput("巡检", "2026-10-01 08:00", time.Hour, &RepeatSpec{Type: RepeatWeekdays, Count: 3}))
		list := seriesOf(t, s, res)
		wantDays := []string{"2026-10-01", "2026-10-02", "2026-10-05"} // 周四、周五、周一
		loc, _ := time.LoadLocation("Asia/Shanghai")
		for i, d := range wantDays {
			got := list[i].StartAt.In(loc).Format(DateLayout)
			if got != d {
				t.Fatalf("第%d次 = %s, 期望 %s", i, got, d)
			}
		}
	})

	t.Run("每天全天事件", func(t *testing.T) {
		res := mustCreate(t, s, allDayInput("值班", "2026-02-27", "2026-03-01", &RepeatSpec{Type: RepeatDaily, Count: 3}))
		list := seriesOf(t, s, res)
		// 首次 2/27~3/1（2 天，跨闰年前平年月末）；后续每天一组
		want := [][2]string{{"2026-02-27", "2026-03-01"}, {"2026-02-28", "2026-03-02"}, {"2026-03-01", "2026-03-03"}}
		for i, w := range want {
			if *list[i].StartDate != w[0] || *list[i].EndDateExclusive != w[1] {
				t.Fatalf("第%d次 = %s~%s, 期望 %s~%s", i, *list[i].StartDate, *list[i].EndDateExclusive, w[0], w[1])
			}
		}
	})

	t.Run("非法重复类型", func(t *testing.T) {
		_, err := svcCreate(t, s, timedInput("x", "2026-09-14 09:00", time.Hour, &RepeatSpec{Type: "monthly", Count: 2}))
		var ve *ValidationError
		if !errors.As(err, &ve) {
			t.Fatalf("期望 ValidationError, 实际 %v", err)
		}
	})

	t.Run("旧契约 interval_weeks 兼容", func(t *testing.T) {
		res := mustCreate(t, s, timedInput("旧客户端", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 2, Count: 2}))
		detail, err := s.Get(context.Background(), res.EventIDs[1])
		if err != nil {
			t.Fatal(err)
		}
		if detail.Series.RepeatType != RepeatBiweekly {
			t.Fatalf("旧参数应归一为 biweekly, 实际 %q", detail.Series.RepeatType)
		}
	})

	t.Run("次数1等于单次但有系列", func(t *testing.T) {
		res := mustCreate(t, s, timedInput("一次", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 1}))
		if res.SeriesID == nil || len(res.EventIDs) != 1 {
			t.Fatal("次数 1 应生成 1 个事件且有系列")
		}
	})
}

// ---- 待办（无固定时间、不关联日期，文档 4.3 待办栏） ----

func TestTodoCreateAndList(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, todoInput("买牛奶"))
	if res.SeriesID != nil || len(res.EventIDs) != 1 {
		t.Fatalf("待办应为单次事件: %+v", res)
	}
	e := getEvent(t, s, res.EventIDs[0])
	if !e.IsTodo || e.AllDay {
		t.Fatalf("待办标记错误: %+v", e)
	}
	if e.StartAt != nil || e.EndAt != nil || e.StartDate != nil || e.EndDateExclusive != nil {
		t.Fatalf("待办不应携带日期/时间字段: %+v", e)
	}
	// 待办不属于任何日期：任意窗口查询都返回
	lst, err := s.ListRange(context.Background(), "2026-09-14", "2026-09-15")
	if err != nil || len(lst.Events) != 1 || !lst.Events[0].IsTodo {
		t.Fatalf("当日窗口应返回待办 (%v)", err)
	}
	lst2, err := s.ListRange(context.Background(), "2027-01-01", "2027-02-01")
	if err != nil || len(lst2.Events) != 1 || !lst2.Events[0].IsTodo {
		t.Fatalf("任意窗口都应返回待办 (%v)", err)
	}
}

func TestTodoValidation(t *testing.T) {
	s, _ := newTestService(t)
	withAllDay := todoInput("x")
	withAllDay.AllDay = true
	withTimes := todoInput("x")
	st := time.Date(2026, 9, 14, 9, 0, 0, 0, time.UTC)
	en := st.Add(time.Hour)
	withTimes.StartAt, withTimes.EndAt = &st, &en
	withDates := todoInput("x")
	sd, ed := "2026-09-14", "2026-09-15"
	withDates.StartDate, withDates.EndDateExclusive = &sd, &ed
	withRepeat := todoInput("x")
	withRepeat.Repeat = &RepeatSpec{IntervalWeeks: 1, Count: 2}

	cases := []struct {
		name string
		in   CreateInput
	}{
		{"待办不使用全天标记", withAllDay},
		{"待办不接受时间字段", withTimes},
		{"待办不接受日期字段", withDates},
		{"待办不支持重复", withRepeat},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := svcCreate(t, s, tc.in)
			var ve *ValidationError
			if !errors.As(err, &ve) {
				t.Fatalf("期望 ValidationError, 实际 %v", err)
			}
		})
	}
}

func TestTodoPatch(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, todoInput("买牛奶"))
	id := res.EventIDs[0]

	// 改标题/备注：正常
	st, _, err := s.Patch(context.Background(), id, PatchInput{
		ExpectedVersion: ptrI64(1), Title: ptrStr("买牛奶和鸡蛋"), Notes: ptrStr("顺路"),
	}, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != nil || st != 200 {
		t.Fatalf("待办改标题失败: %v", err)
	}

	// 待办不接受日期/时间字段 → 400
	newStart := time.Date(2026, 9, 15, 9, 0, 0, 0, time.UTC)
	newEnd := newStart.Add(time.Hour)
	cases := []PatchInput{
		{ExpectedVersion: ptrI64(2), StartDate: ptrStr("2026-09-15")},
		{ExpectedVersion: ptrI64(2), StartAt: &newStart, EndAt: &newEnd},
	}
	for i, in := range cases {
		_, _, err = s.Patch(context.Background(), id, in, Idempotency{Key: RandHex(), Hash: RandHex()})
		var ve *ValidationError
		if !errors.As(err, &ve) {
			t.Fatalf("用例 %d: 期望 ValidationError, 实际 %v", i, err)
		}
	}
	e := getEvent(t, s, id)
	if !e.IsTodo || e.StartDate != nil || e.StartAt != nil {
		t.Fatalf("失败的修改不应改变待办: %+v", e)
	}
}

// ---- 幂等（文档 12：网络） ----

func TestIdempotency(t *testing.T) {
	s, _ := newTestService(t)
	in := timedInput("课程", "2026-09-14 09:00", time.Hour, nil)
	key, hash := "idem-key-0123456789abcdef", "h1"

	st1, b1, err := s.Create(context.Background(), in, Idempotency{Key: key, Hash: hash})
	if err != nil || st1 != 201 {
		t.Fatalf("首次创建失败: %v", err)
	}
	// 相同键 + 相同内容：返回原结果，不重复创建
	st2, b2, err := s.Create(context.Background(), in, Idempotency{Key: key, Hash: hash})
	if err != nil || st2 != 201 {
		t.Fatalf("重放失败: %v", err)
	}
	if string(b1) != string(b2) {
		t.Fatal("重放响应不一致")
	}
	lst, err := s.ListRange(context.Background(), "2026-09-01", "2026-10-01")
	if err != nil || len(lst.Events) != 1 {
		t.Fatalf("重放不应重复创建, 实际 %d 个事件 (%v)", len(lst.Events), err)
	}
	// 相同键 + 不同内容：冲突
	in2 := in
	in2.Title = "别的"
	_, _, err = s.Create(context.Background(), in2, Idempotency{Key: key, Hash: "h2"})
	if err != ErrIdempotencyConflict {
		t.Fatalf("期望 IDEMPOTENCY_CONFLICT, 实际 %v", err)
	}
}

// ---- 版本冲突与单次例外（文档 12：冲突 / 单次例外） ----

func TestPatchVersionConflict(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", time.Hour, nil))
	id := res.EventIDs[0]

	// 设备 A 按 version 1 修改成功
	st, _, err := s.Patch(context.Background(), id, PatchInput{
		ExpectedVersion: ptrI64(1), Title: ptrStr("新标题"),
	}, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != nil || st != 200 {
		t.Fatalf("修改失败: %v", err)
	}
	// 设备 B 仍按 version 1 修改 → 409
	_, _, err = s.Patch(context.Background(), id, PatchInput{
		ExpectedVersion: ptrI64(1), Title: ptrStr("旧标题"),
	}, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != ErrVersionConflict {
		t.Fatalf("期望 VERSION_CONFLICT, 实际 %v", err)
	}
}

func TestDeleteSingleOccurrence(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 4}))
	list := seriesOf(t, s, res)
	target := list[1] // 删除第 2 次

	st, _, err := s.Delete(context.Background(), target.ID, target.Version, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != nil || st != 200 {
		t.Fatalf("删除失败: %v", err)
	}
	// 已删除事件查询返回 404
	if _, err := s.Get(context.Background(), target.ID); err != ErrNotFound {
		t.Fatalf("已删除事件应 404, 实际 %v", err)
	}
	// 其余 3 个不受影响，序号不重排，不补生成新实例（窗口 90 天 ≤ 93）
	lst, err := s.ListRange(context.Background(), "2026-09-01", "2026-11-30")
	if err != nil {
		t.Fatal(err)
	}
	if len(lst.Events) != 3 {
		t.Fatalf("删除后应剩 3 个事件, 实际 %d", len(lst.Events))
	}
	for _, e := range lst.Events {
		if e.ID == target.ID {
			t.Fatal("已删除事件不应出现在范围内查询")
		}
	}
	members, err := dbListSeriesMembers(context.Background(), s.DB, *res.SeriesID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 3 {
		t.Fatalf("系列成员应 3 个, 实际 %d", len(members))
	}
	for _, m := range members {
		if *m.OccurrenceIndex == 1 {
			t.Fatal("序号不应重排")
		}
	}
}

func TestPatchDeleteRace(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, timedInput("竞争", "2026-09-14 09:00", time.Hour, nil))
	id := res.EventIDs[0]
	// 删除成功后，携带新版本的修改请求 → 404（已删除）
	_, _, err := s.Delete(context.Background(), id, 1, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = s.Patch(context.Background(), id, PatchInput{ExpectedVersion: ptrI64(2), Title: ptrStr("x")},
		Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != ErrNotFound {
		t.Fatalf("已删除事件修改应 404, 实际 %v", err)
	}
}

// ---- 本次及以后：目标集合与边界（文档 5.3 / 12：批量） ----

func TestBatchUpdatePropagatesFields(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", 60*time.Minute, &RepeatSpec{IntervalWeeks: 1, Count: 5}))
	list := seriesOf(t, s, res)

	// 单次例外：第 3 次(index 2)改成 12:00、时长 2h、标题"例外"（原 09:00 → +3h）
	alt := list[2]
	altStart := alt.StartAt.Add(3 * time.Hour)
	altEnd := altStart.Add(2 * time.Hour)
	_, _, err := s.Patch(context.Background(), alt.ID, PatchInput{
		ExpectedVersion: ptrI64(alt.Version), Title: ptrStr("例外"),
		StartAt: &altStart, EndAt: &altEnd,
	}, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != nil {
		t.Fatal(err)
	}

	// 从第 2 次(index 1)发起批量：标题改"批量标题"、开始时间 09:00→10:30（+1.5h）
	sel := list[1]
	newStart := sel.StartAt.Add(90 * time.Minute)
	prev, err := callPreview(t, s, sel.ID, PreviewInput{
		Action: "update", ExpectedVersion: sel.Version,
		Changes: &Changes{Title: ptrStr("批量标题"), StartAt: &newStart},
	})
	if err != nil {
		t.Fatal(err)
	}
	if prev.AffectedCount != 4 { // index 1..4，全部未开始
		t.Fatalf("受影响数量 = %d, 期望 4", prev.AffectedCount)
	}
	if err := callCommit(s, sel.ID, prev.Token); err != nil {
		t.Fatal(err)
	}

	after := seriesOf(t, s, res)
	// index 0 不受影响（选中之前）
	if after[0].Title != "课程" || !after[0].StartAt.Equal(*list[0].StartAt) {
		t.Fatalf("选中之前的实例不应被修改: %+v", after[0])
	}
	// index 1..4 标题统一传播
	for i := 1; i < 5; i++ {
		if after[i].Title != "批量标题" {
			t.Fatalf("index %d 标题 = %q", i, after[i].Title)
		}
	}
	// index 1: +1.5h，原时长 1h
	if !after[1].StartAt.Equal(list[1].StartAt.Add(90*time.Minute)) ||
		!after[1].EndAt.Equal(list[1].EndAt.Add(90*time.Minute)) {
		t.Fatalf("index 1 平移错误: %+v", after[1])
	}
	// index 2（例外）：开始也平移 +1.5h，但保留例外时长 2h；标题被批量覆盖（涉及字段）
	if !after[2].StartAt.Equal(altStart.Add(90 * time.Minute)) {
		t.Fatalf("例外开始应平移: %v", after[2].StartAt)
	}
	if dur := after[2].EndAt.Sub(*after[2].StartAt); dur != 2*time.Hour {
		t.Fatalf("例外时长应保留 2h, 实际 %v", dur)
	}
	if after[2].Title != "批量标题" {
		t.Fatal("批量修改应覆盖例外的标题字段")
	}
}

func TestBatchIncludesInProgressEvents(t *testing.T) {
	s, clock := newTestService(t)
	// 现在 = 09-13 16:30Z = 上海 09-14 00:30；系列从 09-14 08:00 上海开始（未来）
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 08:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 3}))
	list := seriesOf(t, s, res)

	// 时钟推进 7 天 8 小时 → 上海 09-21 08:30：index 0 已结束、index 1 进行中、index 2 未来
	clock.Add(7*24*time.Hour + 8*time.Hour)

	// 从已结束的事件发起批量 → 400（保护过去的记录）
	_, _, err := s.PreviewSeriesChange(context.Background(), list[0].ID, PreviewInput{
		Action: "update", ExpectedVersion: list[0].Version, Changes: &Changes{Title: ptrStr("x")},
	}, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err == nil {
		t.Fatal("已结束事件应拒绝批量")
	}

	// 从进行中的事件发起批量：允许，目标 = 进行中(index1) + 未来(index2)
	prev, err := callPreview(t, s, list[1].ID, PreviewInput{
		Action: "update", ExpectedVersion: list[1].Version, Changes: &Changes{Title: ptrStr("当前及以后")},
	})
	if err != nil {
		t.Fatalf("进行中事件应可发起批量: %v", err)
	}
	if prev.AffectedCount != 2 {
		t.Fatalf("受影响数量 = %d, 期望 2（含进行中的当前实例）", prev.AffectedCount)
	}
	if err := callCommit(s, list[1].ID, prev.Token); err != nil {
		t.Fatal(err)
	}
	after := seriesOf(t, s, res)
	// index 0（已结束）不受影响；index 1（进行中）与 index 2 均被修改
	if after[0].Title != "课程" {
		t.Fatalf("已结束实例不应被修改: %q", after[0].Title)
	}
	if after[1].Title != "当前及以后" || after[2].Title != "当前及以后" {
		t.Fatalf("进行中与未来实例应被修改: %q, %q", after[1].Title, after[2].Title)
	}

	// 从未来事件发起：目标集合只有 index 2 自己
	prev2, err := callPreview(t, s, list[2].ID, PreviewInput{
		Action: "update", ExpectedVersion: after[2].Version, Changes: &Changes{Title: ptrStr("仅未来")},
	})
	if err != nil {
		t.Fatal(err)
	}
	if prev2.AffectedCount != 1 {
		t.Fatalf("受影响数量 = %d, 期望 1", prev2.AffectedCount)
	}
}

func TestBatchAllDayDateSemantics(t *testing.T) {
	s, _ := newTestService(t)
	// 现在是上海 09-14 00:30，系列从 09-15 开始（未来，可发起批量）
	res := mustCreate(t, s, allDayInput("培训", "2026-09-15", "2026-09-17", &RepeatSpec{IntervalWeeks: 1, Count: 3}))
	list := seriesOf(t, s, res) // 每次都是 2 天（9/15-16、9/22-23、9/29-30）

	// 批量：选中 index 0，开始 09-15→09-16（+1 天），不改天数 → 各实例保留原 2 天
	sel := list[0]
	newStart := "2026-09-16"
	prev, err := callPreview(t, s, sel.ID, PreviewInput{
		Action: "update", ExpectedVersion: sel.Version,
		Changes: &Changes{StartDate: &newStart},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := callCommit(s, sel.ID, prev.Token); err != nil {
		t.Fatal(err)
	}
	after := seriesOf(t, s, res)
	for i, w := range []string{"2026-09-16", "2026-09-23", "2026-09-30"} {
		if *after[i].StartDate != w || *after[i].EndDateExclusive != addDaysStr(t, w, 2) {
			t.Fatalf("index %d = %s~%s, 期望 %s~%s（保留各自 2 天）",
				i, *after[i].StartDate, *after[i].EndDateExclusive, w, addDaysStr(t, w, 2))
		}
	}

	// 再次批量：改天数 → 统一 3 天（09-16 起 3 天 = end_excl 09-19）
	sel2 := after[0]
	newEnd := "2026-09-19"
	prev2, err := callPreview(t, s, sel2.ID, PreviewInput{
		Action: "update", ExpectedVersion: sel2.Version,
		Changes: &Changes{EndDateExclusive: &newEnd},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := callCommit(s, sel2.ID, prev2.Token); err != nil {
		t.Fatal(err)
	}
	after2 := seriesOf(t, s, res)
	for i := range after2 {
		if days(t, *after2[i].StartDate, *after2[i].EndDateExclusive) != 3 {
			t.Fatalf("index %d 天数 = %d, 期望统一 3", i, days(t, *after2[i].StartDate, *after2[i].EndDateExclusive))
		}
	}
}

func TestBatchDeleteAndNoRenumber(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 4}))
	list := seriesOf(t, s, res)

	// 删除 index 0 单次，再从 index 1 批量删除 index 1..3
	_, _, err := s.Delete(context.Background(), list[0].ID, list[0].Version, Idempotency{Key: RandHex(), Hash: RandHex()})
	if err != nil {
		t.Fatal(err)
	}
	prev, err := callPreview(t, s, list[1].ID, PreviewInput{
		Action: "delete", ExpectedVersion: list[1].Version,
	})
	if err != nil {
		t.Fatal(err)
	}
	if prev.AffectedCount != 3 {
		t.Fatalf("批量删除应影响 3 个, 实际 %d", prev.AffectedCount)
	}
	if err := callCommit(s, list[1].ID, prev.Token); err != nil {
		t.Fatal(err)
	}
	lst, err := s.ListRange(context.Background(), "2026-09-01", "2026-11-30")
	if err != nil {
		t.Fatal(err)
	}
	if len(lst.Events) != 0 {
		t.Fatalf("全部删除后应为空, 实际 %d", len(lst.Events))
	}
}

func TestPreviewInvalidation(t *testing.T) {
	s, clock := newTestService(t)
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 4}))
	list := seriesOf(t, s, res)
	sel := list[1]

	t.Run("其他成员被修改后预览失效", func(t *testing.T) {
		prev, err := callPreview(t, s, sel.ID, PreviewInput{
			Action: "update", ExpectedVersion: sel.Version, Changes: &Changes{Title: ptrStr("x")},
		})
		if err != nil {
			t.Fatal(err)
		}
		// 另一设备修改 index 3 → 系列版本 +1
		_, _, err = s.Patch(context.Background(), list[3].ID, PatchInput{
			ExpectedVersion: ptrI64(list[3].Version), Notes: ptrStr("干扰"),
		}, Idempotency{Key: RandHex(), Hash: RandHex()})
		if err != nil {
			t.Fatal(err)
		}
		if err := callCommit(s, sel.ID, prev.Token); !errors.Is(err, ErrPreviewExpired) {
			t.Fatalf("期望 PREVIEW_EXPIRED, 实际 %v", err)
		}
	})

	t.Run("成员被删除后预览失效", func(t *testing.T) {
		prev, err := callPreview(t, s, sel.ID, PreviewInput{
			Action: "update", ExpectedVersion: sel.Version, Changes: &Changes{Title: ptrStr("y")},
		})
		if err != nil {
			t.Fatal(err)
		}
		_, _, err = s.Delete(context.Background(), list[3].ID, list[3].Version+1, Idempotency{Key: RandHex(), Hash: RandHex()})
		if err != nil {
			t.Fatal(err)
		}
		if err := callCommit(s, sel.ID, prev.Token); !errors.Is(err, ErrPreviewExpired) {
			t.Fatalf("期望 PREVIEW_EXPIRED, 实际 %v", err)
		}
	})

	t.Run("令牌过期后预览失效", func(t *testing.T) {
		prev, err := callPreview(t, s, sel.ID, PreviewInput{
			Action: "update", ExpectedVersion: sel.Version, Changes: &Changes{Title: ptrStr("z")},
		})
		if err != nil {
			t.Fatal(err)
		}
		clock.Add(PreviewDefaultTTL + time.Minute)
		if err := callCommit(s, sel.ID, prev.Token); !errors.Is(err, ErrPreviewExpired) {
			t.Fatalf("期望 PREVIEW_EXPIRED, 实际 %v", err)
		}
	})

	t.Run("失效提交不产生任何修改", func(t *testing.T) {
		e := getEvent(t, s, sel.ID)
		if e.Title != "课程" {
			t.Fatalf("事件标题不应被失效提交改变: %q", e.Title)
		}
	})
}

// ---- 范围查询（文档 7 / 12：日期边界） ----

func TestListRangeSemantics(t *testing.T) {
	s, _ := newTestService(t)
	// 上海 09-14 23:00–次日 01:00（跨午夜）
	mustCreate(t, s, timedInput("夜班", "2026-09-14 23:00", 2*time.Hour, nil))
	// 上海 09-13 22:00–22:30（在 09-14 窗口之外）
	mustCreate(t, s, timedInput("前夜", "2026-09-13 22:00", 30*time.Minute, nil))
	// 全天 09-15 一天（含），即 end_excl = 09-16
	mustCreate(t, s, allDayInput("全天", "2026-09-15", "2026-09-16", nil))

	// 查询 09-14 一天：上海窗口 [09-14 00:00, 09-15 00:00)
	lst, err := s.ListRange(context.Background(), "2026-09-14", "2026-09-15")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, e := range lst.Events {
		got[e.Title] = true
	}
	if !got["夜班"] {
		t.Fatal("跨午夜事件应出现在其本地开始日窗口")
	}
	if got["前夜"] {
		t.Fatal("窗口之外事件不应返回")
	}
	if got["全天"] {
		t.Fatal("全天事件 09-15 不应在 09-14 窗口返回")
	}

	// 查询 09-15 一天：全天事件按日期相交返回
	lst2, err := s.ListRange(context.Background(), "2026-09-15", "2026-09-16")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, e := range lst2.Events {
		if e.Title == "全天" {
			found = true
		}
	}
	if !found {
		t.Fatal("全天事件应按日期相交返回")
	}

	// 跨度超 93 天 → 400
	if _, err := s.ListRange(context.Background(), "2026-01-01", "2026-06-01"); err == nil {
		t.Fatal("超跨度查询应报错")
	}
	// 非法日期 → 400
	if _, err := s.ListRange(context.Background(), "bad", "2026-09-16"); err == nil {
		t.Fatal("非法 from 应报错")
	}
	// from == to：空窗口
	lst3, err := s.ListRange(context.Background(), "2026-09-14", "2026-09-14")
	if err != nil || len(lst3.Events) != 0 {
		t.Fatalf("空窗口应返回空列表 (%v)", err)
	}
}

func TestGetDetailIncludesSeriesInfo(t *testing.T) {
	s, _ := newTestService(t)
	res := mustCreate(t, s, timedInput("课程", "2026-09-14 09:00", time.Hour, &RepeatSpec{IntervalWeeks: 1, Count: 4}))
	detail, err := s.Get(context.Background(), res.EventIDs[2])
	if err != nil {
		t.Fatal(err)
	}
	if detail.Series == nil {
		t.Fatal("系列事件应返回系列信息")
	}
	if detail.Series.IntervalWeeks != 1 || detail.Series.OccurrenceCount != 4 {
		t.Fatalf("系列信息错误: %+v", detail.Series)
	}
	if detail.Series.RemainingAfterView != 2 { // index 2、3 未开始
		t.Fatalf("remaining_after_index = %d, 期望 2", detail.Series.RemainingAfterView)
	}
	// 单次事件无系列信息
	single := mustCreate(t, s, timedInput("单次", "2026-09-20 09:00", time.Hour, nil))
	detail2, err := s.Get(context.Background(), single.EventIDs[0])
	if err != nil {
		t.Fatal(err)
	}
	if detail2.Series != nil {
		t.Fatal("单次事件不应返回系列信息")
	}
}

// ---- 辅助 ----

func ptrStr(s string) *string { return &s }
func ptrI64(v int64) *int64   { return &v }

// RandHex 生成测试用唯一键。
func RandHex() string { return fmt.Sprintf("k%016x", time.Now().UnixNano()) }

func addDaysStr(t *testing.T, d string, n int) string {
	t.Helper()
	s, err := AddDays(d, n)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func days(t *testing.T, a, b string) int {
	t.Helper()
	n, err := DaysBetween(a, b)
	if err != nil {
		t.Fatal(err)
	}
	return n
}
