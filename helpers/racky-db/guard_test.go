package main

import (
	"strings"
	"testing"
)

func TestGuardAllowsReads(t *testing.T) {
	ok := map[string][]string{
		"mysql": {
			"select * from t", "  SELECT 1;", "WITH a AS (SELECT 1) SELECT * FROM a", "show tables", "DESCRIBE users", "explain select 1",
			"select 'a;b' from t", "select `update` from t", "select 1 -- ; drop table x", "select /* ; */ 1", "select 1 # delete",
			"select \"it\\\"s; ok\"", "SELECT 1;  -- trailing comment",
		},
		"oracle":    {"SELECT * FROM dual", "with a as (select 1 from dual) select * from a", "select 'x'';y' from dual", "select \"DELETE\" from t"},
		"sqlserver": {"SELECT TOP 5 * FROM t", "with a as (select 1 x) select * from a", "select [update] from t", "exec sp_help 'dbo.t'", "EXECUTE sp_columns @table_name = 'x'", "select 'DELETE' as w"},
	}
	for engine, list := range ok {
		for _, sql := range list {
			if err := CheckReadOnly(engine, sql); err != nil {
				t.Errorf("%s: %q should pass: %v", engine, sql, err)
			}
		}
	}
}

func TestGuardRefusesWrites(t *testing.T) {
	bad := map[string][]string{
		"mysql": {
			"insert into t values (1)", "UPDATE t SET a=1", "delete from t", "drop table t", "select 1; drop table t", "select 1;delete from t",
			"select * from t into outfile '/tmp/x'", "select load_file('/etc/passwd')", "call p()", "set @a = 1", "create table x (a int)", "", "   ", "-- only a comment",
			"truncate t", "select 1; /* c */ select 2",
		},
		"oracle": {"insert into t values (1)", "begin null; end;", "delete from t", "select 1 from dual; drop table t", "call p()", "select utl_http.request('http://x') from dual", "merge into t using s on (1=1) when matched then update set a=1", "alter session set x=1"},
		"sqlserver": {
			"insert t values (1)", "with a as (select 1 x) delete from t", "select * into #tmp from t", "exec xp_cmdshell 'dir'", "exec sp_executesql N'drop table t'", "exec sp_help; drop table t",
			"update t set a = 1", "declare @a int; select 1", "select 1; drop table t", "drop table t", "select * from openrowset('x','y','z')", "backup database x to disk='y'", "use master", "waitfor delay '00:00:10'",
			"exec my_proc", "execute", "select 1 from t; exec sp_help", "EXEC sp_help 'x'; DELETE t",
		},
	}
	for engine, list := range bad {
		for _, sql := range list {
			if err := CheckReadOnly(engine, sql); err == nil {
				t.Errorf("%s: %q should be refused", engine, sql)
			}
		}
	}
}

func TestGuardMessagesAreClear(t *testing.T) {
	err := CheckReadOnly("mysql", "DELETE FROM t")
	if err == nil || !strings.Contains(err.Error(), "only reads") || !strings.Contains(err.Error(), "DELETE") {
		t.Fatalf("message: %v", err)
	}
	if oe, ok := err.(*opError); !ok || oe.Kind != KindInvalid {
		t.Fatalf("kind: %#v", err)
	}
}

func TestGuardDoesNotConfuseQuotedWords(t *testing.T) {
	// A column or value called like a keyword is not a keyword.
	if err := CheckReadOnly("sqlserver", "SELECT [into], 'insert' FROM [drop]"); err != nil {
		t.Fatal(err)
	}
	// An unterminated string swallows the rest (the server would too), so nothing hides behind it.
	if err := CheckReadOnly("mysql", "select 'abc; drop table t"); err != nil {
		t.Fatalf("unterminated string is one statement: %v", err)
	}
}
