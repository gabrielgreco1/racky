package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// Live checks against a throwaway server: RACKY_DB_TEST_MYSQL / _SQLSERVER / _ORACLE hold a DSN and the test needs a table
// `customers` (id, name). They are skipped when the variable is not set, so `go test` stays offline.
func TestLiveReadOnlyTransactionRefusesWrites(t *testing.T) {
	for _, engine := range []string{"mysql", "sqlserver", "oracle"} {
		dsn := os.Getenv("RACKY_DB_TEST_" + strings.ToUpper(engine))
		if dsn == "" {
			continue
		}
		t.Run(engine, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			target, err := ParseDSN(engine, dsn)
			if err != nil {
				t.Fatal(err)
			}
			s, err := openSession(ctx, dialect(engine), target)
			if err != nil {
				t.Fatal(err)
			}
			defer s.close()
			// Bypass the guard on purpose: the transaction must refuse by itself where the engine supports it.
			_, err = s.tx.ExecContext(ctx, "INSERT INTO customers (id, name) VALUES (9999, 'x')")
			if engine != "sqlserver" && err == nil {
				t.Fatal("the read-only transaction accepted an INSERT")
			}
			resp := Execute(ctx, s, &Request{Op: "rowCount", Table: "customers", Schema: os.Getenv("RACKY_DB_TEST_SCHEMA")})
			t.Logf("rowCount after attempted write: %+v err=%v", resp.RowCount, resp.Error)
		})
	}
}
