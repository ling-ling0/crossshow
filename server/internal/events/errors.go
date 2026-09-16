package events

import (
	"errors"
	"fmt"
)

// 领域错误；HTTP 层据此映射状态码（开发文档 7）。
var (
	ErrNotFound            = errors.New("not found")
	ErrVersionConflict     = errors.New("version conflict")
	ErrPreviewExpired      = errors.New("preview expired")
	ErrIdempotencyConflict = errors.New("idempotency conflict")
	ErrBusy                = errors.New("busy")
)

// ValidationError 输入错误（400 VALIDATION_ERROR）。
type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string {
	if e.Field == "" {
		return e.Message
	}
	return fmt.Sprintf("%s: %s", e.Field, e.Message)
}

func invalid(field, format string, args ...any) *ValidationError {
	return &ValidationError{Field: field, Message: fmt.Sprintf(format, args...)}
}
