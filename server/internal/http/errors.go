// Package httpapi 提供 HTTP 路由、中间件与错误映射。
// 目录名 internal/http 遵循开发文档 3.4；包名用 httpapi 避免与标准库冲突。
package httpapi

import (
	"encoding/json"
	"net/http"
)

// API 错误统一格式：{"error":{"code","message","details"}}（文档 7）。

type apiError struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details"`
}

type errorEnvelope struct {
	Error apiError `json:"error"`
}

func writeErr(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(errorEnvelope{Error: apiError{
		Code:    code,
		Message: message,
		Details: map[string]any{},
	}})
}

func writeJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
