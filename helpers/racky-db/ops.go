package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	mssql "github.com/microsoft/go-mssqldb"
)

// Tables this size or larger answer rowCount with the engine's estimate; smaller ones are counted exactly.
const countExactBelow = 100_000

// maxCell caps one cell's text so a huge blob or document cannot fill the app's memory.
const maxCell = 20_000

// session is one open connection inside a read-only transaction. Close always rolls back.
type session struct {
	d    dialect
	conn *sql.Conn
	tx   *sql.Tx
	db   *sql.DB
}

func openSession(ctx context.Context, d dialect, t *target) (*session, error) {
	db, err := t.open()
	if err != nil {
		return nil, err
	}
	conn, err := db.Conn(ctx)
	if err != nil {
		db.Close()
		return nil, err
	}
	s := &session{d: d, conn: conn, db: db}
	if d == mysqlDialect {
		// A server-side cap for SELECTs (MySQL in ms, MariaDB in seconds); servers that know neither setting just refuse it.
		_, _ = conn.ExecContext(ctx, "SET SESSION max_execution_time = 20000")
		_, _ = conn.ExecContext(ctx, "SET SESSION max_statement_time = 20")
	}
	opts := &sql.TxOptions{}
	if d == mysqlDialect {
		opts.ReadOnly = true // START TRANSACTION READ ONLY
	}
	tx, err := conn.BeginTx(ctx, opts)
	if err != nil {
		s.close()
		return nil, err
	}
	s.tx = tx
	if d == oracleDialect {
		// Must be the first statement of the transaction.
		if _, err := tx.ExecContext(ctx, "SET TRANSACTION READ ONLY"); err != nil {
			s.close()
			return nil, err
		}
	}
	return s, nil
}

func (s *session) close() {
	if s.tx != nil {
		_ = s.tx.Rollback()
	}
	if s.conn != nil {
		_ = s.conn.Close()
	}
	if s.db != nil {
		_ = s.db.Close()
	}
}

// Execute runs one request against an open session.
func Execute(ctx context.Context, s *session, req *Request) Response {
	d := s.d
	switch req.Op {
	case "check":
		rows, err := s.tx.QueryContext(ctx, d.pingSQL())
		if err != nil {
			return fail(err)
		}
		rows.Close()
		return Response{OK: true}
	case "catalog":
		schemas, err := d.catalog(ctx, s.tx)
		if err != nil {
			return fail(err)
		}
		return Response{OK: true, Schemas: schemas}
	case "columns":
		cols, err := d.columns(ctx, s.tx, req.Schema, req.Table)
		if err != nil {
			return fail(err)
		}
		if cols == nil {
			cols = []Column{}
		}
		return Response{OK: true, Columns: cols}
	case "rowCount":
		if est := d.estimate(ctx, s.tx, req.Schema, req.Table); est != nil && *est >= countExactBelow {
			return Response{OK: true, RowCount: &RowCount{Value: *est, Exact: false}}
		}
		var n int64
		if err := s.tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+d.qualified(req.Schema, req.Table)).Scan(&n); err != nil {
			return fail(err)
		}
		return Response{OK: true, RowCount: &RowCount{Value: n, Exact: true}}
	case "rows":
		res, err := collect(ctx, s.tx, d.pageSQL(req.Schema, req.Table, req.Limit, req.Offset, req.OrderBy), req.Limit)
		if err != nil {
			return fail(err)
		}
		return Response{OK: true, Result: res}
	case "query":
		if err := CheckReadOnly(string(d), req.SQL); err != nil {
			return fail(err)
		}
		res, err := collect(ctx, s.tx, strings.TrimRight(strings.TrimSpace(req.SQL), "; \t\r\n"), req.Limit)
		if err != nil {
			return fail(err)
		}
		return Response{OK: true, Result: res}
	}
	return fail(invalid("unknown op"))
}

// collect reads at most limit rows (one more only marks truncated; the rest is never read).
func collect(ctx context.Context, q querier, query string, limit int) (*Result, error) {
	rows, err := q.QueryContext(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	types, _ := rows.ColumnTypes()
	res := &Result{Columns: cols, Rows: [][]string{}}
	for rows.Next() {
		if len(res.Rows) >= limit {
			res.Truncated = true
			break
		}
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		cells := make([]string, len(cols))
		for i, v := range vals {
			typeName := ""
			if i < len(types) {
				typeName = strings.ToUpper(types[i].DatabaseTypeName())
			}
			cells[i] = formatValue(v, typeName)
		}
		res.Rows = append(res.Rows, cells)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return res, nil
}

func formatValue(v any, typeName string) string {
	var s string
	switch x := v.(type) {
	case nil:
		return "NULL"
	case string:
		s = x
	case []byte:
		switch {
		case typeName == "UNIQUEIDENTIFIER" && len(x) == 16:
			var u mssql.UniqueIdentifier
			if u.Scan(x) == nil {
				s = strings.ToLower(u.String())
			} else {
				s = "0x" + hex.EncodeToString(x)
			}
		case isBinaryType(typeName) || !utf8.Valid(x):
			s = "0x" + hex.EncodeToString(x[:min(len(x), maxCell/2)])
		default:
			s = string(x)
		}
	case bool:
		s = strconv.FormatBool(x)
	case int64:
		s = strconv.FormatInt(x, 10)
	case float64:
		s = strconv.FormatFloat(x, 'g', -1, 64)
	case time.Time:
		s = formatTime(x, typeName)
	default:
		s = fmt.Sprint(x)
	}
	if len(s) > maxCell {
		s = strings.ToValidUTF8(s[:maxCell], "") + "…"
	}
	return s
}

func isBinaryType(t string) bool {
	return strings.Contains(t, "BINARY") || t == "BLOB" || t == "IMAGE" || t == "RAW" || strings.HasSuffix(t, "BLOB") && !strings.Contains(t, "TEXT")
}

func formatTime(t time.Time, typeName string) string {
	if typeName == "DATE" && t.Hour() == 0 && t.Minute() == 0 && t.Second() == 0 && t.Nanosecond() == 0 {
		return t.Format("2006-01-02")
	}
	out := t.Format("2006-01-02 15:04:05")
	if t.Nanosecond() > 0 {
		out += strings.TrimRight(t.Format(".000000000"), "0")
	}
	if typeName == "DATETIMEOFFSET" || typeName == "TIMESTAMPTZ" || strings.Contains(typeName, "TIME ZONE") {
		out += t.Format("-07:00")
	}
	return out
}
