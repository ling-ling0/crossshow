package httpapi_test

// HTTP 层测试：真实路由 + 临时 SQLite，验证状态码映射与幂等行为。

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"crossshow/server/internal/events"
	httpapi "crossshow/server/internal/http"
	"crossshow/server/internal/storage"
)

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := storage.Migrate(context.Background(), db.DB); err != nil {
		t.Fatal(err)
	}
	svc := events.NewService(db.DB, "Asia/Shanghai", time.Now)
	srv := httptest.NewServer(httpapi.NewHandler(svc, slog.Default()).Routes())
	t.Cleanup(srv.Close)
	return srv
}

func doJSON(t *testing.T, srv *httptest.Server, method, path, key string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, srv.URL+path, rd)
	if err != nil {
		t.Fatal(err)
	}
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &out)
	}
	return resp.StatusCode, out
}

func errCode(t *testing.T, body map[string]any) string {
	t.Helper()
	e, ok := body["error"].(map[string]any)
	if !ok {
		t.Fatalf("响应缺少 error 字段: %v", body)
	}
	code, _ := e["code"].(string)
	return code
}

func TestHealthz(t *testing.T) {
	srv := newServer(t)
	st, body := doJSON(t, srv, "GET", "/healthz", "", nil)
	if st != 200 || body["status"] != "ok" {
		t.Fatalf("healthz = %d %v", st, body)
	}
}

func TestConfig(t *testing.T) {
	srv := newServer(t)
	st, body := doJSON(t, srv, "GET", "/api/v1/config", "", nil)
	if st != 200 {
		t.Fatalf("config = %d", st)
	}
	if body["timezone"] != "Asia/Shanghai" {
		t.Fatalf("默认时区错误: %v", body)
	}
	caps, _ := body["capabilities"].(map[string]any)
	if caps["max_repeat_count"] != float64(520) || caps["max_query_span_days"] != float64(93) {
		t.Fatalf("能力字段错误: %v", caps)
	}
}

func TestCreateAndList(t *testing.T) {
	srv := newServer(t)
	in := map[string]any{
		"title": "课程", "all_day": false,
		"start_at": "2026-09-14T01:00:00Z", "end_at": "2026-09-14T02:30:00Z",
		"timezone": "Asia/Shanghai",
		"repeat":   map[string]any{"interval_weeks": 1, "count": 16},
	}
	st, body := doJSON(t, srv, "POST", "/api/v1/events", "create-key-0123456789ab", in)
	if st != 201 {
		t.Fatalf("创建 = %d %v", st, body)
	}
	ids, _ := body["event_ids"].([]any)
	if len(ids) != 16 {
		t.Fatalf("应生成 16 个, 实际 %d", len(ids))
	}
	// 幂等重放
	st2, body2 := doJSON(t, srv, "POST", "/api/v1/events", "create-key-0123456789ab", in)
	if st2 != 201 {
		t.Fatalf("重放 = %d", st2)
	}
	ids2, _ := body2["event_ids"].([]any)
	if len(ids2) != 16 || ids2[0] != ids[0] {
		t.Fatal("重放应返回相同结果")
	}

	// 范围查询（90 天窗口 ≤ 93 上限；16 周系列共 105 天，窗口内含前 11 次）
	qst, qbody := doJSON(t, srv, "GET", "/api/v1/events?from=2026-09-01&to=2026-11-30", "", nil)
	if qst != 200 {
		t.Fatalf("查询 = %d %v", qst, qbody)
	}
	evts, _ := qbody["events"].([]any)
	if len(evts) != 11 {
		t.Fatalf("窗口内应返回 11 个, 实际 %d", len(evts))
	}

	// 跨度超限 → 400 VALIDATION_ERROR
	bst, bbody := doJSON(t, srv, "GET", "/api/v1/events?from=2026-01-01&to=2026-12-31", "", nil)
	if bst != 400 || errCode(t, bbody) != "VALIDATION_ERROR" {
		t.Fatalf("超跨度 = %d %v", bst, bbody)
	}
}

func TestErrorMapping(t *testing.T) {
	srv := newServer(t)

	// 缺幂等键 → 400
	in := map[string]any{"title": "x", "all_day": false,
		"start_at": "2026-09-14T01:00:00Z", "end_at": "2026-09-14T02:00:00Z", "timezone": "Asia/Shanghai"}
	st, body := doJSON(t, srv, "POST", "/api/v1/events", "", in)
	if st != 400 || errCode(t, body) != "VALIDATION_ERROR" {
		t.Fatalf("缺幂等键 = %d %v", st, body)
	}

	// 相同键不同内容 → 409 IDEMPOTENCY_CONFLICT
	doJSON(t, srv, "POST", "/api/v1/events", "key-conflict-012345678", in)
	in2 := map[string]any{}
	for k, v := range in { // 复制，避免共享 map 引用
		in2[k] = v
	}
	in2["title"] = "y"
	st2, body2 := doJSON(t, srv, "POST", "/api/v1/events", "key-conflict-012345678", in2)
	if st2 != 409 || errCode(t, body2) != "IDEMPOTENCY_CONFLICT" {
		t.Fatalf("幂等冲突 = %d %v", st2, body2)
	}

	// 创建一个事件用于冲突测试
	_, body3 := doJSON(t, srv, "POST", "/api/v1/events", "key-create-01234567890", in)
	id := body3["event_ids"].([]any)[0].(string)

	// PATCH 版本冲突 → 409 VERSION_CONFLICT
	pst, pbody := doJSON(t, srv, "PATCH", "/api/v1/events/"+id, "key-patch-012345678901",
		map[string]any{"expected_version": 99, "title": "nope"})
	if pst != 409 || errCode(t, pbody) != "VERSION_CONFLICT" {
		t.Fatalf("版本冲突 = %d %v", pst, pbody)
	}

	// PATCH 正常（带 expected_version=1）
	pst2, _ := doJSON(t, srv, "PATCH", "/api/v1/events/"+id, "key-patch-012345678902",
		map[string]any{"expected_version": 1, "title": "新标题"})
	if pst2 != 200 {
		t.Fatalf("正常修改 = %d", pst2)
	}

	// DELETE 缺 expected_version → 400
	dst, dbody := doJSON(t, srv, "DELETE", "/api/v1/events/"+id, "key-del-0123456789012", nil)
	if dst != 400 || errCode(t, dbody) != "VALIDATION_ERROR" {
		t.Fatalf("删除缺版本 = %d %v", dst, dbody)
	}

	// DELETE 版本冲突 → 409（版本已到 2）
	dst2, dbody2 := doJSON(t, srv, "DELETE", "/api/v1/events/"+id+"?expected_version=1", "key-del-0123456789013", nil)
	if dst2 != 409 || errCode(t, dbody2) != "VERSION_CONFLICT" {
		t.Fatalf("删除版本冲突 = %d %v", dst2, dbody2)
	}

	// DELETE 成功后再次 GET → 404 NOT_FOUND
	doJSON(t, srv, "DELETE", "/api/v1/events/"+id+"?expected_version=2", "key-del-0123456789014", nil)
	gst, gbody := doJSON(t, srv, "GET", "/api/v1/events/"+id, "", nil)
	if gst != 404 || errCode(t, gbody) != "NOT_FOUND" {
		t.Fatalf("已删除 GET = %d %v", gst, gbody)
	}
}

func TestSeriesChangeEndpoints(t *testing.T) {
	srv := newServer(t)
	in := map[string]any{"title": "课程", "all_day": false,
		"start_at": "2026-09-21T01:00:00Z", "end_at": "2026-09-21T02:00:00Z",
		"timezone": "Asia/Shanghai",
		"repeat":   map[string]any{"interval_weeks": 1, "count": 4}}
	_, cbody := doJSON(t, srv, "POST", "/api/v1/events", "sc-create-012345678901", in)
	ids := cbody["event_ids"].([]any)
	firstID := ids[0].(string)

	// 预览
	pst, pbody := doJSON(t, srv, "POST", "/api/v1/events/"+firstID+"/series-change-preview",
		"sc-preview-012345678901",
		map[string]any{"action": "update", "expected_version": 1,
			"changes": map[string]any{"title": "新课程"}})
	if pst != 200 {
		t.Fatalf("预览 = %d %v", pst, pbody)
	}
	if pbody["affected_count"] != float64(4) {
		t.Fatalf("affected_count = %v", pbody["affected_count"])
	}
	token, _ := pbody["token"].(string)
	if token == "" {
		t.Fatal("预览应返回令牌")
	}

	// 用新内容替换令牌提交 → 令牌签名不匹配 → 409 PREVIEW_EXPIRED
	cst, cbody2 := doJSON(t, srv, "POST", "/api/v1/events/"+firstID+"/series-change-commit",
		"sc-commit-012345678901", map[string]any{"token": token + "x"})
	if cst != 409 || errCode(t, cbody2) != "PREVIEW_EXPIRED" {
		t.Fatalf("篡改令牌 = %d %v", cst, cbody2)
	}

	// 正常提交
	cst2, cbody3 := doJSON(t, srv, "POST", "/api/v1/events/"+firstID+"/series-change-commit",
		"sc-commit-012345678902", map[string]any{"token": token})
	if cst2 != 200 {
		t.Fatalf("提交 = %d %v", cst2, cbody3)
	}
	evts, _ := cbody3["events"].([]any)
	if len(evts) != 4 {
		t.Fatalf("提交应返回 4 个事件, 实际 %d", len(evts))
	}

	// 删除全部：从第一个（现版本 2）预览删除
	pst3, pbody3 := doJSON(t, srv, "POST", "/api/v1/events/"+firstID+"/series-change-preview",
		"sc-preview-012345678902", map[string]any{"action": "delete", "expected_version": 2})
	if pst3 != 200 {
		t.Fatalf("删除预览 = %d %v", pst3, pbody3)
	}
	doJSON(t, srv, "POST", "/api/v1/events/"+firstID+"/series-change-commit",
		"sc-commit-012345678903", map[string]any{"token": pbody3["token"]})
	lst, lbody := doJSON(t, srv, "GET", "/api/v1/events?from=2026-09-01&to=2026-11-30", "", nil)
	if lst != 200 {
		t.Fatal(lst)
	}
	if evts, _ := lbody["events"].([]any); len(evts) != 0 {
		t.Fatalf("批量删除后应为空")
	}
}
