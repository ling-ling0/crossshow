package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"crossshow/server/internal/events"
)

// Handler 承载全部 HTTP 端点（文档 7）。
type Handler struct {
	svc *events.Service
	log *slog.Logger
}

func NewHandler(svc *events.Service, log *slog.Logger) *Handler {
	return &Handler{svc: svc, log: log}
}

// Routes 构建路由。Go 1.22+ 方法 + 路径参数模式。
func (h *Handler) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", h.health)
	mux.HandleFunc("GET /api/v1/config", h.config)
	mux.HandleFunc("GET /api/v1/events", h.list)
	mux.HandleFunc("POST /api/v1/events", h.create)
	mux.HandleFunc("GET /api/v1/events/{id}", h.get)
	mux.HandleFunc("PATCH /api/v1/events/{id}", h.patch)
	mux.HandleFunc("DELETE /api/v1/events/{id}", h.deleteEvent)
	mux.HandleFunc("POST /api/v1/events/{id}/series-change-preview", h.preview)
	mux.HandleFunc("POST /api/v1/events/{id}/series-change-commit", h.commit)
	return chain(mux, h.log)
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, []byte(`{"status":"ok"}`))
}

func (h *Handler) config(w http.ResponseWriter, r *http.Request) {
	writeResult(w, http.StatusOK, h.svc.Config())
}

// ---- 请求解析辅助 ----

// idempotency 提取幂等键并计算请求摘要（方法 + 路径 + 查询 + 请求体）。
func idempotency(r *http.Request, body []byte) (events.Idempotency, error) {
	key := r.Header.Get("Idempotency-Key")
	if n := len(key); n < 16 || n > 128 {
		return events.Idempotency{}, &events.ValidationError{
			Field:   "Idempotency-Key",
			Message: "写请求必须携带 16–128 字符的 Idempotency-Key",
		}
	}
	sum := sha256.Sum256([]byte(r.Method + "\n" + r.URL.Path + "\n" + r.URL.RawQuery + "\n" + string(body)))
	return events.Idempotency{Key: key, Hash: hex.EncodeToString(sum[:])}, nil
}

func writeResult(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "INTERNAL", "响应编码失败")
		return
	}
	writeJSON(w, status, body)
}

func (h *Handler) writeServiceErr(w http.ResponseWriter, r *http.Request, err error) {
	var ve *events.ValidationError
	switch {
	case errors.As(err, &ve):
		writeErr(w, http.StatusBadRequest, "VALIDATION_ERROR", ve.Error())
	case errors.Is(err, events.ErrNotFound):
		writeErr(w, http.StatusNotFound, "NOT_FOUND", "事件不存在或已删除")
	case errors.Is(err, events.ErrVersionConflict):
		writeErr(w, http.StatusConflict, "VERSION_CONFLICT", "事件已被其他设备修改")
	case errors.Is(err, events.ErrPreviewExpired):
		writeErr(w, http.StatusConflict, "PREVIEW_EXPIRED", "预览已失效，请重新预览后提交")
	case errors.Is(err, events.ErrIdempotencyConflict):
		writeErr(w, http.StatusConflict, "IDEMPOTENCY_CONFLICT", "相同幂等键配不同请求内容")
	case errors.Is(err, events.ErrBusy):
		writeErr(w, http.StatusServiceUnavailable, "UNAVAILABLE", "服务繁忙，请稍后重试")
	default:
		h.log.Error("internal error", "request_id", requestIDFrom(r.Context()), "err", err)
		writeErr(w, http.StatusInternalServerError, "INTERNAL", "内部错误")
	}
}

// ---- 端点 ----

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	from := r.URL.Query().Get("from")
	to := r.URL.Query().Get("to")
	result, err := h.svc.ListRange(r.Context(), from, to)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	writeResult(w, http.StatusOK, result)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	result, err := h.svc.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	writeResult(w, http.StatusOK, result)
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "VALIDATION_ERROR", "读取请求体失败")
		return
	}
	var in events.CreateInput
	if err := decodeBody(body, &in); err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	idem, err := idempotency(r, body)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	status, out, err := h.svc.Create(r.Context(), in, idem)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	writeJSON(w, status, out)
}

func (h *Handler) patch(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "VALIDATION_ERROR", "读取请求体失败")
		return
	}
	var in events.PatchInput
	if err := decodeBody(body, &in); err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	idem, err := idempotency(r, body)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	status, out, err := h.svc.Patch(r.Context(), r.PathValue("id"), in, idem)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	writeJSON(w, status, out)
}

func (h *Handler) deleteEvent(w http.ResponseWriter, r *http.Request) {
	evStr := r.URL.Query().Get("expected_version")
	expected, err := strconv.ParseInt(evStr, 10, 64)
	if err != nil || expected < 1 {
		writeErr(w, http.StatusBadRequest, "VALIDATION_ERROR", "expected_version 必须为正整数")
		return
	}
	idem, err := idempotency(r, nil)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	status, out, err := h.svc.Delete(r.Context(), r.PathValue("id"), expected, idem)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	writeJSON(w, status, out)
}

func (h *Handler) preview(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "VALIDATION_ERROR", "读取请求体失败")
		return
	}
	var in events.PreviewInput
	if err := decodeBody(body, &in); err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	idem, err := idempotency(r, body)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	status, out, err := h.svc.PreviewSeriesChange(r.Context(), r.PathValue("id"), in, idem)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	writeJSON(w, status, out)
}

func (h *Handler) commit(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "VALIDATION_ERROR", "读取请求体失败")
		return
	}
	var in events.CommitInput
	if err := decodeBody(body, &in); err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	if strings.TrimSpace(in.Token) == "" {
		h.writeServiceErr(w, r, &events.ValidationError{Field: "token", Message: "缺少预览令牌"})
		return
	}
	idem, err := idempotency(r, body)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	status, out, err := h.svc.CommitSeriesChange(r.Context(), r.PathValue("id"), in, idem)
	if err != nil {
		h.writeServiceErr(w, r, err)
		return
	}
	writeJSON(w, status, out)
}

// decodeBody 从已读入内存的请求体解码 JSON（供幂等摘要复用同一份字节）。
func decodeBody(body []byte, v any) error {
	dec := json.NewDecoder(strings.NewReader(string(body)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return &events.ValidationError{Field: "body", Message: "请求体过大"}
		}
		return &events.ValidationError{Field: "body", Message: fmt.Sprintf("请求体不是合法 JSON 或包含未知字段: %v", err)}
	}
	return nil
}
