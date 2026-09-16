// Package migrations 内嵌全部有序迁移脚本。
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
