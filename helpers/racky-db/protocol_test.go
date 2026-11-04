package main

import (
	"errors"
	"net"
	"strings"
	"testing"
)

func parse(t *testing.T, s string) (*Request, error) {
	t.Helper()
	return ParseRequest(strings.NewReader(s))
}

func TestParseRequestDefaultsAndLimits(t *testing.T) {
	r, err := parse(t, `{"op":"rows","engine":"MySQL","dsn":"mysql://u:p@h/db","table":"t","limit":9999999,"offset":-4}`)
	if err != nil {
		t.Fatal(err)
	}
	if r.Engine != "mysql" || r.Limit != 100000 || r.Offset != 0 || r.TimeoutSeconds != 25 {
		t.Fatalf("%+v", r)
	}
	r, _ = parse(t, `{"op":"check","engine":"oracle","dsn":"oracle://u:p@h/s"}`)
	if r.Limit != 100 {
		t.Fatalf("default limit %d", r.Limit)
	}
}

func TestParseRequestRejects(t *testing.T) {
	for name, body := range map[string]string{
		"not json":       `nope`,
		"unknown engine": `{"op":"check","engine":"db2","dsn":"x"}`,
		"unknown op":     `{"op":"drop","engine":"mysql","dsn":"x"}`,
		"no dsn":         `{"op":"check","engine":"mysql"}`,
		"rows no table":  `{"op":"rows","engine":"mysql","dsn":"x"}`,
		"empty query":    `{"op":"query","engine":"mysql","dsn":"x","sql":"  "}`,
	} {
		_, err := parse(t, body)
		var oe *opError
		if !errors.As(err, &oe) || oe.Kind != KindInvalid {
			t.Errorf("%s: want invalid, got %v", name, err)
		}
	}
}

func TestInvalidRequestMessagesNeverEchoTheDSN(t *testing.T) {
	_, err := parse(t, `{"op":"check","engine":"db2","dsn":"mysql://root:hunter2@h/db"}`)
	if strings.Contains(err.Error(), "hunter2") {
		t.Fatal("leak")
	}
	_, err = ParseDSN("mysql", "mysql://root:hunter2@h:99999/db")
	if err == nil || strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("bad port: %v", err)
	}
	_, err = ParseDSN("mysql", "mysql://root:hun ter2@h:99/db%zz")
	if err == nil || strings.Contains(err.Error(), "hunter2") || strings.Contains(err.Error(), "hun ter2") {
		t.Fatalf("unparsable: %v", err)
	}
}

type timeoutErr struct{}

func (timeoutErr) Error() string   { return "read tcp 10.0.0.1:5: i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

var _ net.Error = timeoutErr{}

func TestClassify(t *testing.T) {
	cases := []struct {
		err  error
		kind string
	}{
		{errors.New("Error 1045 (28000): Access denied for user 'root'@'h' (using password: YES)"), KindAuth},
		{errors.New("mssql: login error: Login failed for user 'sa'."), KindAuth},
		{errors.New("ORA-01017: invalid username/password; logon denied"), KindAuth},
		{errors.New("dial tcp 127.0.0.1:3306: connect: connection refused"), KindUnreachable},
		{errors.New("lookup nohost: no such host"), KindUnreachable},
		{errors.New("ORA-12514: TNS:listener does not currently know of service"), KindUnreachable},
		{errors.New("tls: failed to verify certificate: x509: certificate signed by unknown authority"), KindTLS},
		{timeoutErr{}, KindTimeout},
		{errors.New("Error 1146 (42S02): Table 'db.nope' doesn't exist"), KindSQL},
		{invalid("x"), KindInvalid},
	}
	for _, c := range cases {
		if got := classify(c.err).Kind; got != c.kind {
			t.Errorf("%v: got %s want %s", c.err, got, c.kind)
		}
	}
}

func TestScrubRemovesPassword(t *testing.T) {
	got := classify(errors.New("login failed for p@ss/w0rd (p%40ss%2Fw0rd)"), "p@ss/w0rd").Message
	if strings.Contains(got, "p@ss") || strings.Contains(got, "w0rd") {
		t.Fatalf("leak: %s", got)
	}
}

func TestParseDSNPerEngine(t *testing.T) {
	m, err := ParseDSN("mysql", "mysql://app:s3cret%21@db.local:3307/shop?tls=disable")
	if err != nil || !strings.Contains(m.connStr, "app:s3cret!@tcp(db.local:3307)/shop") || !strings.Contains(m.connStr, "tls=false") {
		t.Fatalf("mysql: %v %v", m, err)
	}
	if len(m.secrets) != 1 || m.secrets[0] != "s3cret!" {
		t.Fatalf("secrets %v", m.secrets)
	}
	s, err := ParseDSN("sqlserver", "sqlserver://sa:P%40ss@10.0.0.4:1433?database=sales")
	if err != nil || !strings.Contains(s.connStr, "database=sales") || !strings.Contains(s.connStr, "encrypt=true") {
		t.Fatalf("sqlserver: %v %v", s, err)
	}
	o, err := ParseDSN("oracle", "oracle://scott:tiger@ora.local:1522/FREEPDB1")
	if err != nil || !strings.Contains(o.connStr, "ora.local:1522/FREEPDB1") {
		t.Fatalf("oracle: %v %v", o, err)
	}
	for _, bad := range [][2]string{{"mysql", "postgres://u:p@h/d"}, {"mysql", "mysql://h/d"}, {"oracle", "oracle://u:p@h"}, {"sqlserver", "sqlserver://u:p@/d"}} {
		if _, err := ParseDSN(bad[0], bad[1]); err == nil {
			t.Errorf("%v should fail", bad)
		}
	}
}

func TestDialectPaging(t *testing.T) {
	if got := mysqlDialect.pageSQL("shop", "orders", 100, 200, []string{"id"}); got != "SELECT * FROM `shop`.`orders` ORDER BY `id` LIMIT 101 OFFSET 200" {
		t.Fatal(got)
	}
	if got := sqlServerDialect.pageSQL("dbo", "o]rders", 10, 0, nil); got != "SELECT * FROM [dbo].[o]]rders] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 11 ROWS ONLY" {
		t.Fatal(got)
	}
	if got := oracleDialect.pageSQL("HR", "EMP", 10, 20, []string{"A", "B"}); got != `SELECT * FROM "HR"."EMP" ORDER BY "A", "B" OFFSET 20 ROWS FETCH NEXT 11 ROWS ONLY` {
		t.Fatal(got)
	}
}

func TestFormatValue(t *testing.T) {
	if formatValue(nil, "") != "NULL" || formatValue([]byte("hi"), "VARCHAR") != "hi" || formatValue([]byte{0xde, 0xad}, "VARBINARY") != "0xdead" || formatValue(int64(7), "") != "7" {
		t.Fatal("format")
	}
}
