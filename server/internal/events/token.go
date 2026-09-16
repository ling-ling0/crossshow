package events

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// 预览令牌：payload JSON + HMAC-SHA256 签名，无状态、有时效。
// 秘钥每次进程启动随机生成——重启后旧令牌全部失效，属预期的安全行为。
// 提交不得用新内容替换令牌绑定的内容（开发文档 5.3 / 7）。

type previewClaims struct {
	SeriesID    string   `json:"s"`
	SelEventID  string   `json:"se"`
	SelIndex    int64    `json:"si"`
	Action      string   `json:"a"`
	Changes     *Changes `json:"c,omitempty"`
	AffectedIDs []string `json:"ids"`
	SeriesVer   int64    `json:"sv"`
	Exp         int64    `json:"exp"` // Unix 秒
}

func newTokenSecret() []byte {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("生成预览令牌秘钥失败: " + err.Error())
	}
	return b
}

func signToken(secret []byte, c previewClaims) (string, error) {
	payload, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding
	payloadB64 := enc.EncodeToString(payload)
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payloadB64))
	return payloadB64 + "." + enc.EncodeToString(mac.Sum(nil)), nil
}

func verifyToken(secret []byte, token string, now time.Time) (previewClaims, error) {
	var claims previewClaims
	enc := base64.RawURLEncoding
	payload, macPart, ok := cutLast(token, ".")
	if !ok {
		return claims, errors.New("令牌格式非法")
	}
	sig, err := enc.DecodeString(macPart)
	if err != nil {
		return claims, errors.New("令牌签名非法")
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payload)) // 与 signToken 一致：对 base64 文本签名
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return claims, errors.New("令牌签名不匹配")
	}
	raw, err := enc.DecodeString(payload)
	if err != nil {
		return claims, errors.New("令牌负载非法")
	}
	if err := json.Unmarshal(raw, &claims); err != nil {
		return claims, fmt.Errorf("令牌负载解析失败: %w", err)
	}
	if now.Unix() >= claims.Exp {
		return claims, errors.New("令牌已过期")
	}
	return claims, nil
}

func cutLast(s, sep string) (before, after string, found bool) {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '.' {
			return s[:i], s[i+1:], true
		}
	}
	return s, "", false
}
