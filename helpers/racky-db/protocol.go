// racky-db: one JSON request on stdin, one JSON response on stdout, then exit.
// It reads MySQL/MariaDB, SQL Server and Oracle for Racky's Data area. It never writes: see guard.go and ops.go.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
)

// Request is the whole input. Dsn carries the secret: it is never logged and never placed in argv.
type Request struct {
	Op      string   `json:"op"`
	Engine  string   `json:"engine"`
	Dsn     string   `json:"dsn"`
	Schema  string   `json:"schema,omitempty"`
	Table   string   `json:"table,omitempty"`
	Limit   int      `json:"limit,omitempty"`
	Offset  int      `json:"offset,omitempty"`
	OrderBy []string `json:"orderBy,omitempty"`
	SQL     string   `json:"sql,omitempty"`
	// TimeoutSeconds is the deadline for the whole operation (connect included). Default 25.
	TimeoutSeconds float64 `json:"timeoutSeconds,omitempty"`
}

type Table struct {
	Name          string `json:"name"`
	IsView        bool   `json:"isView"`
	EstimatedRows *int64 `json:"estimatedRows"`
}

type Schema struct {
	Name   string  `json:"name"`
	Tables []Table `json:"tables"`
}

type Column struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Nullable bool   `json:"nullable"`
	IsKey    bool   `json:"isKey"`
}

type RowCount struct {
	Value int64 `json:"value"`
	Exact bool  `json:"exact"`
}

type Result struct {
	Columns   []string   `json:"columns"`
	Rows      [][]string `json:"rows"`
	Truncated bool       `json:"truncated"`
}

type ErrorBody struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

type Response struct {
	OK       bool       `json:"ok"`
	Error    *ErrorBody `json:"error,omitempty"`
	Schemas  []Schema   `json:"schemas,omitempty"`
	Columns  []Column   `json:"columns,omitempty"`
	RowCount *RowCount  `json:"rowCount,omitempty"`
	Result   *Result    `json:"result,omitempty"`
}

// Error kinds, the same ones the Swift side maps.
const (
	KindUnreachable = "unreachable"
	KindAuth        = "auth"
	KindTLS         = "tls"
	KindTimeout     = "timeout"
	KindSQL         = "sql"
	KindInvalid     = "invalid"
)

type opError struct {
	Kind string
	Msg  string
}

func (e *opError) Error() string { return e.Msg }

func invalid(msg string) error { return &opError{KindInvalid, msg} }

const maxRequestBytes = 1 << 20

// ParseRequest reads and validates one request.
func ParseRequest(r io.Reader) (*Request, error) {
	data, err := io.ReadAll(io.LimitReader(r, maxRequestBytes+1))
	if err != nil {
		return nil, invalid("could not read the request")
	}
	if len(data) > maxRequestBytes {
		return nil, invalid("the request is too large")
	}
	var req Request
	if err := json.Unmarshal(data, &req); err != nil {
		return nil, invalid("the request is not valid JSON")
	}
	req.Engine = strings.ToLower(strings.TrimSpace(req.Engine))
	req.Op = strings.TrimSpace(req.Op)
	switch req.Engine {
	case "mysql", "sqlserver", "oracle":
	default:
		return nil, invalid("unknown engine \"" + req.Engine + "\" (mysql, sqlserver or oracle)")
	}
	switch req.Op {
	case "check", "catalog":
	case "columns", "rowCount", "rows":
		if req.Table == "" {
			return nil, invalid("the table name is missing")
		}
	case "query":
		if strings.TrimSpace(req.SQL) == "" {
			return nil, invalid("write a query first")
		}
	default:
		return nil, invalid("unknown op \"" + req.Op + "\"")
	}
	if strings.TrimSpace(req.Dsn) == "" {
		return nil, invalid("the connection string is missing")
	}
	if req.Limit <= 0 {
		req.Limit = 100
	}
	if req.Limit > 100000 {
		req.Limit = 100000
	}
	if req.Offset < 0 {
		req.Offset = 0
	}
	if req.TimeoutSeconds <= 0 {
		req.TimeoutSeconds = 25
	}
	if req.TimeoutSeconds > 300 {
		req.TimeoutSeconds = 300
	}
	return &req, nil
}

// classify maps any driver error to a kind. The message never carries the secrets passed in.
func classify(err error, secrets ...string) *ErrorBody {
	var oe *opError
	if errors.As(err, &oe) {
		return &ErrorBody{oe.Kind, scrub(oe.Msg, secrets...)}
	}
	msg := err.Error()
	low := strings.ToLower(msg)
	kind := KindSQL
	var nerr net.Error
	switch {
	case errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled):
		return &ErrorBody{KindTimeout, "The server did not answer in time."}
	case containsAny(low, "x509", "tls:", "tls handshake", "certificate", "ssl is not enabled", "ssl handshake", "encryption not supported", "server does not support encryption"):
		kind = KindTLS
	case containsAny(low, "access denied", "login failed", "ora-01017", "ora-28000", "ora-28001", "ora-01045", "authentication failed", "password"):
		kind = KindAuth
	case errors.As(err, &nerr) && nerr.Timeout(), containsAny(low, "i/o timeout", "timed out"):
		kind = KindTimeout
	case errors.As(err, &nerr), containsAny(low, "connection refused", "no such host", "network is unreachable", "no route to host", "connection reset", "unexpected eof", "broken pipe", "ora-12514", "ora-12505", "ora-12541", "ora-12154", "ora-12170", "dial tcp", "lookup "):
		kind = KindUnreachable
	}
	if kind == KindTimeout {
		return &ErrorBody{KindTimeout, "The server did not answer in time."}
	}
	return &ErrorBody{kind, scrub(firstLine(msg), secrets...)}
}

func containsAny(s string, needles ...string) bool {
	for _, n := range needles {
		if strings.Contains(s, n) {
			return true
		}
	}
	return false
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return s
}

// scrub removes every secret (and its URL-encoded form) from a message.
func scrub(msg string, secrets ...string) string {
	for _, s := range secrets {
		if len(s) < 3 {
			continue
		}
		msg = strings.ReplaceAll(msg, s, "***")
		msg = strings.ReplaceAll(msg, urlEscape(s), "***")
	}
	return msg
}

func fail(err error, secrets ...string) Response {
	return Response{OK: false, Error: classify(err, secrets...)}
}
