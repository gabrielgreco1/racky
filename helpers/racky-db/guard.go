package main

import "strings"

// The guard is the second wall, after the read-only transaction (and the only one on SQL Server, which has no read-only
// transaction). It reads the statement the way the server's lexer would for strings, identifiers and comments, then allows
// exactly one statement that starts with a read keyword.

type lexed struct {
	words     []string // upper-cased bare words outside strings, quoted identifiers and comments
	semicolon bool     // a ';' with more than whitespace after it
}

func lex(engine, sql string) lexed {
	var out lexed
	n := len(sql)
	i := 0
	sawSemicolon := false
	var word strings.Builder
	flush := func() {
		if word.Len() > 0 {
			out.words = append(out.words, strings.ToUpper(word.String()))
			word.Reset()
		}
	}
	for i < n {
		c := sql[i]
		if sawSemicolon && !isSpace(c) && !(c == '-' && i+1 < n && sql[i+1] == '-') && !(c == '/' && i+1 < n && sql[i+1] == '*') {
			out.semicolon = true
		}
		switch {
		case c == '\'' || c == '"' || c == '`' || (c == '[' && engine == "sqlserver"):
			flush()
			closer := c
			if c == '[' {
				closer = ']'
			}
			backslash := engine == "mysql" && c != '`'
			i++
			for i < n {
				if backslash && sql[i] == '\\' {
					i += 2
					continue
				}
				if sql[i] == closer {
					if i+1 < n && sql[i+1] == closer { // doubled quote
						i += 2
						continue
					}
					break
				}
				i++
			}
			i++
		case c == '-' && i+1 < n && sql[i+1] == '-':
			flush()
			for i < n && sql[i] != '\n' {
				i++
			}
		case c == '#' && engine == "mysql":
			flush()
			for i < n && sql[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < n && sql[i+1] == '*':
			flush()
			i += 2
			depth := 1
			for i < n && depth > 0 {
				if sql[i] == '*' && i+1 < n && sql[i+1] == '/' {
					depth--
					i += 2
				} else if engine == "sqlserver" && sql[i] == '/' && i+1 < n && sql[i+1] == '*' {
					depth++
					i += 2
				} else {
					i++
				}
			}
		case c == ';':
			flush()
			sawSemicolon = true
			i++
		case isWordByte(c):
			word.WriteByte(c)
			i++
		default:
			flush()
			i++
		}
	}
	flush()
	return out
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v' }

func isWordByte(c byte) bool {
	return c == '_' || c == '$' || c == '@' || c == '#' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

// Statements that read. MySQL also describes and explains; SQL Server also runs the sp_help family.
var readStart = map[string]map[string]bool{
	"mysql":     {"SELECT": true, "WITH": true, "SHOW": true, "DESCRIBE": true, "DESC": true, "EXPLAIN": true, "TABLE": true, "VALUES": true},
	"oracle":    {"SELECT": true, "WITH": true},
	"sqlserver": {"SELECT": true, "WITH": true, "EXEC": true, "EXECUTE": true},
}

var sqlServerReadProcs = map[string]bool{
	"SP_HELP": true, "SP_HELPINDEX": true, "SP_HELPCONSTRAINT": true, "SP_HELPTEXT": true, "SP_COLUMNS": true, "SP_TABLES": true,
	"SP_FKEYS": true, "SP_PKEYS": true, "SP_STORED_PROCEDURES": true, "SP_SPACEUSED": true, "SP_DATABASES": true,
	"SP_HELPDB": true, "SP_HELP_REVLOGIN_NOT": true,
}

// SQL Server cannot make a transaction read-only, so any word that writes, changes the schema, runs code or opens a file
// anywhere in the statement refuses it (this also stops `WITH x AS (…) DELETE …` and `SELECT … INTO`).
var sqlServerDeny = map[string]bool{
	"INSERT": true, "UPDATE": true, "DELETE": true, "MERGE": true, "DROP": true, "ALTER": true, "CREATE": true, "TRUNCATE": true,
	"GRANT": true, "REVOKE": true, "DENY": true, "EXEC": true, "EXECUTE": true, "INTO": true, "BACKUP": true, "RESTORE": true,
	"SHUTDOWN": true, "KILL": true, "OPENROWSET": true, "OPENQUERY": true, "OPENDATASOURCE": true, "BULK": true, "DBCC": true,
	"RECONFIGURE": true, "WRITETEXT": true, "UPDATETEXT": true, "DECLARE": true, "SET": true, "USE": true,
	"BEGIN": true, "COMMIT": true, "ROLLBACK": true, "SAVE": true, "WAITFOR": true,
}

var mysqlDeny = map[string]bool{"OUTFILE": true, "DUMPFILE": true, "LOAD_FILE": true, "GET_LOCK": true}

var oracleDeny = map[string]bool{"DBMS_LOCK": true, "UTL_FILE": true, "UTL_HTTP": true, "UTL_TCP": true, "UTL_SMTP": true, "DBMS_SCHEDULER": true, "DBMS_JOB": true}

// CheckReadOnly returns nil when the statement is one read statement, or an error that says what is not allowed.
func CheckReadOnly(engine, sql string) error {
	l := lex(engine, sql)
	if len(l.words) == 0 {
		return invalid("Write a query first.")
	}
	if l.semicolon {
		return invalid("Run one statement at a time (remove the text after the semicolon).")
	}
	first := l.words[0]
	allowed, ok := readStart[engine]
	if !ok {
		return invalid("unknown engine")
	}
	if !allowed[first] {
		return invalid("Racky only reads: " + first + " is not allowed. Start with SELECT or WITH.")
	}
	switch engine {
	case "sqlserver":
		if first == "EXEC" || first == "EXECUTE" {
			if len(l.words) < 2 || !sqlServerReadProcs[strings.ToUpper(strings.TrimPrefix(l.words[1], "SYS."))] {
				return invalid("Racky only reads: EXEC is limited to the sp_help family (sp_help, sp_columns, sp_tables…).")
			}
			for _, w := range l.words[2:] {
				if sqlServerDeny[w] {
					return invalid("Racky only reads: " + w + " is not allowed.")
				}
			}
			return nil
		}
		for _, w := range l.words {
			if sqlServerDeny[w] {
				return invalid("Racky only reads: " + w + " is not allowed on SQL Server (it cannot be made read-only).")
			}
		}
	case "mysql":
		for _, w := range l.words {
			if mysqlDeny[w] {
				return invalid("Racky only reads: " + w + " is not allowed.")
			}
		}
	case "oracle":
		for _, w := range l.words {
			if oracleDeny[w] {
				return invalid("Racky only reads: " + w + " is not allowed.")
			}
		}
	}
	return nil
}
