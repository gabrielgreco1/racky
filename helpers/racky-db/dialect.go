package main

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

// dialect holds everything that differs between the three engines: quoting, placeholders, catalog queries, paging.
type dialect string

const (
	mysqlDialect     dialect = "mysql"
	sqlServerDialect dialect = "sqlserver"
	oracleDialect    dialect = "oracle"
)

type querier interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

func (d dialect) quote(name string) string {
	switch d {
	case mysqlDialect:
		return "`" + strings.ReplaceAll(name, "`", "``") + "`"
	case sqlServerDialect:
		return "[" + strings.ReplaceAll(name, "]", "]]") + "]"
	default:
		return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
	}
}

func (d dialect) qualified(schema, table string) string {
	if schema == "" {
		return d.quote(table)
	}
	return d.quote(schema) + "." + d.quote(table)
}

// ph is the placeholder for the i-th argument (1-based).
func (d dialect) ph(i int) string {
	switch d {
	case sqlServerDialect:
		return fmt.Sprintf("@p%d", i)
	case oracleDialect:
		return fmt.Sprintf(":%d", i)
	default:
		return "?"
	}
}

func (d dialect) pingSQL() string {
	if d == oracleDialect {
		return "SELECT 1 FROM dual"
	}
	return "SELECT 1"
}

// pageSQL reads one page of a table, asking for one row more than limit so the caller can tell there was more.
func (d dialect) pageSQL(schema, table string, limit, offset int, orderBy []string) string {
	var order []string
	for _, c := range orderBy {
		if c != "" {
			order = append(order, d.quote(c))
		}
	}
	from := "SELECT * FROM " + d.qualified(schema, table)
	orderClause := ""
	if len(order) > 0 {
		orderClause = " ORDER BY " + strings.Join(order, ", ")
	}
	switch d {
	case mysqlDialect:
		return fmt.Sprintf("%s%s LIMIT %d OFFSET %d", from, orderClause, limit+1, offset)
	case sqlServerDialect:
		if orderClause == "" {
			orderClause = " ORDER BY (SELECT NULL)"
		}
		return fmt.Sprintf("%s%s OFFSET %d ROWS FETCH NEXT %d ROWS ONLY", from, orderClause, offset, limit+1)
	default:
		return fmt.Sprintf("%s%s OFFSET %d ROWS FETCH NEXT %d ROWS ONLY", from, orderClause, offset, limit+1)
	}
}

var oracleSystemOwners = `'SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','ORDDATA','ORDPLUGINS','OUTLN','DBSNMP','APPQOSSYS','AUDSYS',` +
	`'GSMADMIN_INTERNAL','GSMCATUSER','GSMUSER','LBACSYS','DVSYS','DVF','OJVMSYS','WMSYS','OLAPSYS','SI_INFORMTN_SCHEMA','ORACLE_OCM',` +
	`'REMOTE_SCHEDULER_AGENT','DIP','ANONYMOUS','XS$NULL','GGSYS','DBSFWUSER','SYSBACKUP','SYSDG','SYSKM','SYSRAC','PUBLIC',` +
	`'MDDATA','FLOWS_FILES','EXFSYS','SPATIAL_CSW_ADMIN_USR','SPATIAL_WFS_ADMIN_USR','DGPDB_INT','SYS$UMF'`

// catalog lists schemas and their tables and views with estimated rows (from the engine's own statistics, so it stays cheap).
func (d dialect) catalog(ctx context.Context, q querier) ([]Schema, error) {
	var schemaSQL, tableSQL string
	switch d {
	case mysqlDialect:
		schemaSQL = `SELECT schema_name FROM information_schema.schemata
			WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY schema_name`
		tableSQL = `SELECT table_schema, table_name, table_type, table_rows FROM information_schema.tables
			WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY table_schema, table_name`
	case sqlServerDialect:
		schemaSQL = `SELECT name FROM sys.schemas WHERE name NOT IN ('sys','INFORMATION_SCHEMA','guest') AND name NOT LIKE 'db[_]%' ORDER BY (CASE WHEN name = 'dbo' THEN 0 ELSE 1 END), name`
		tableSQL = `SELECT s.name, o.name, o.type,
				(SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = o.object_id AND p.index_id IN (0, 1))
			FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
			WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0 ORDER BY s.name, o.name`
	default:
		schemaSQL = `SELECT USER FROM dual UNION SELECT DISTINCT owner FROM all_tables WHERE owner NOT IN (` + oracleSystemOwners + `) AND owner NOT LIKE 'APEX\_%' ESCAPE '\'
			UNION SELECT DISTINCT owner FROM all_views WHERE owner NOT IN (` + oracleSystemOwners + `) AND owner NOT LIKE 'APEX\_%' ESCAPE '\'`
		tableSQL = `SELECT owner, table_name, 'TABLE', num_rows FROM all_tables
				WHERE owner NOT IN (` + oracleSystemOwners + `) AND owner NOT LIKE 'APEX\_%' ESCAPE '\' AND dropped = 'NO' AND table_name NOT LIKE 'BIN$%'
			UNION ALL SELECT owner, view_name, 'VIEW', NULL FROM all_views
				WHERE owner NOT IN (` + oracleSystemOwners + `) AND owner NOT LIKE 'APEX\_%' ESCAPE '\'
			ORDER BY 1, 2`
	}
	names, err := stringColumn(ctx, q, schemaSQL)
	if err != nil {
		return nil, err
	}
	rows, err := q.QueryContext(ctx, tableSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	bySchema := map[string][]Table{}
	for rows.Next() {
		var schema, name, kind string
		var est sql.NullInt64
		var estAny any
		if err := rows.Scan(&schema, &name, &kind, &estAny); err != nil {
			return nil, err
		}
		est = toNullInt(estAny)
		t := Table{Name: name, IsView: kind == "VIEW" || kind == "V"}
		if !t.IsView && est.Valid && est.Int64 >= 0 {
			v := est.Int64
			t.EstimatedRows = &v
		}
		bySchema[schema] = append(bySchema[schema], t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []Schema
	if d == oracleDialect { // the connected user first, then the rest alphabetically
		current, _ := stringColumn(ctx, q, "SELECT USER FROM dual")
		sortFirst(names, current)
	}
	for _, n := range names {
		if seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, Schema{Name: n, Tables: orEmpty(bySchema[n])})
	}
	for n, t := range bySchema { // a table in a schema the schema query did not list
		if !seen[n] {
			out = append(out, Schema{Name: n, Tables: t})
		}
	}
	return out, nil
}

func orEmpty(t []Table) []Table {
	if t == nil {
		return []Table{}
	}
	return t
}

func sortFirst(names []string, first []string) {
	if len(first) == 0 {
		return
	}
	for i, n := range names {
		if n == first[0] {
			names[0], names[i] = names[i], names[0]
			return
		}
	}
}

func stringColumn(ctx context.Context, q querier, query string, args ...any) ([]string, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var v sql.NullString
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v.String)
	}
	return out, rows.Err()
}

func toNullInt(v any) sql.NullInt64 {
	switch x := v.(type) {
	case nil:
		return sql.NullInt64{}
	case int64:
		return sql.NullInt64{Int64: x, Valid: true}
	case int32:
		return sql.NullInt64{Int64: int64(x), Valid: true}
	case uint64:
		return sql.NullInt64{Int64: int64(x), Valid: true}
	case int:
		return sql.NullInt64{Int64: int64(x), Valid: true}
	case float64:
		return sql.NullInt64{Int64: int64(x), Valid: true}
	case []byte:
		var n int64
		if _, err := fmt.Sscan(string(x), &n); err == nil {
			return sql.NullInt64{Int64: n, Valid: true}
		}
	case string:
		var n int64
		if _, err := fmt.Sscan(x, &n); err == nil {
			return sql.NullInt64{Int64: n, Valid: true}
		}
	}
	return sql.NullInt64{}
}

// columns lists a table's columns in order, with a short type, nullability and primary-key membership.
func (d dialect) columns(ctx context.Context, q querier, schema, table string) ([]Column, error) {
	var query string
	switch d {
	case mysqlDialect:
		query = `SELECT column_name, column_type, is_nullable, column_key FROM information_schema.columns
			WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position`
	case sqlServerDialect:
		query = `SELECT column_name, data_type, is_nullable, character_maximum_length, numeric_precision, numeric_scale
			FROM information_schema.columns WHERE table_schema = @p1 AND table_name = @p2 ORDER BY ordinal_position`
	default:
		query = `SELECT column_name, data_type, nullable, data_length, data_precision, data_scale, char_length
			FROM all_tab_columns WHERE owner = :1 AND table_name = :2 ORDER BY column_id`
	}
	rows, err := q.QueryContext(ctx, query, schema, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Column
	for rows.Next() {
		vals := make([]any, 7)
		ptrs := make([]any, 7)
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		n := map[dialect]int{mysqlDialect: 4, sqlServerDialect: 6, oracleDialect: 7}[d]
		if err := rows.Scan(ptrs[:n]...); err != nil {
			return nil, err
		}
		c := Column{Name: text(vals[0])}
		nullable := strings.ToUpper(text(vals[2]))
		c.Nullable = nullable == "YES" || nullable == "Y"
		switch d {
		case mysqlDialect:
			c.Type = text(vals[1])
			c.IsKey = text(vals[3]) == "PRI"
		case sqlServerDialect:
			c.Type = sqlServerType(text(vals[1]), toNullInt(vals[3]), toNullInt(vals[4]), toNullInt(vals[5]))
		default:
			c.Type = oracleType(text(vals[1]), toNullInt(vals[3]), toNullInt(vals[4]), toNullInt(vals[5]), toNullInt(vals[6]))
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if d != mysqlDialect && len(out) > 0 {
		keys, err := d.keyColumns(ctx, q, schema, table)
		if err == nil { // the key marks are a nicety: a catalog that refuses this read still lists the columns
			for i := range out {
				out[i].IsKey = keys[out[i].Name]
			}
		}
	}
	return out, nil
}

func (d dialect) keyColumns(ctx context.Context, q querier, schema, table string) (map[string]bool, error) {
	var query string
	if d == sqlServerDialect {
		query = `SELECT k.column_name FROM information_schema.table_constraints tc
			JOIN information_schema.key_column_usage k ON k.constraint_name = tc.constraint_name AND k.constraint_schema = tc.constraint_schema
			WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = @p1 AND tc.table_name = @p2`
	} else {
		query = `SELECT cc.column_name FROM all_constraints c JOIN all_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
			WHERE c.constraint_type = 'P' AND c.owner = :1 AND c.table_name = :2`
	}
	names, err := stringColumn(ctx, q, query, schema, table)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, n := range names {
		out[n] = true
	}
	return out, nil
}

func sqlServerType(base string, length, precision, scale sql.NullInt64) string {
	switch strings.ToLower(base) {
	case "char", "varchar", "nchar", "nvarchar", "binary", "varbinary":
		if length.Valid {
			if length.Int64 < 0 {
				return base + "(max)"
			}
			return fmt.Sprintf("%s(%d)", base, length.Int64)
		}
	case "decimal", "numeric":
		if precision.Valid {
			return fmt.Sprintf("%s(%d,%d)", base, precision.Int64, scale.Int64)
		}
	}
	return base
}

func oracleType(base string, length, precision, scale, charLength sql.NullInt64) string {
	switch strings.ToUpper(base) {
	case "VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR":
		if charLength.Valid && charLength.Int64 > 0 {
			return fmt.Sprintf("%s(%d)", base, charLength.Int64)
		}
	case "RAW":
		if length.Valid {
			return fmt.Sprintf("RAW(%d)", length.Int64)
		}
	case "NUMBER":
		if precision.Valid {
			if scale.Valid && scale.Int64 != 0 {
				return fmt.Sprintf("NUMBER(%d,%d)", precision.Int64, scale.Int64)
			}
			return fmt.Sprintf("NUMBER(%d)", precision.Int64)
		}
	}
	return base
}

// estimate is the engine's own row estimate for one table (nil for views and tables never analyzed).
func (d dialect) estimate(ctx context.Context, q querier, schema, table string) *int64 {
	var query string
	var args []any
	switch d {
	case mysqlDialect:
		query, args = `SELECT table_rows FROM information_schema.tables WHERE table_schema = ? AND table_name = ? AND table_type = 'BASE TABLE'`, []any{schema, table}
	case sqlServerDialect:
		query, args = `SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = OBJECT_ID(@p1) AND p.index_id IN (0, 1)`, []any{d.qualified(schema, table)}
	default:
		query, args = `SELECT num_rows FROM all_tables WHERE owner = :1 AND table_name = :2`, []any{schema, table}
	}
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	if rows.Next() {
		var v any
		if rows.Scan(&v) == nil {
			if n := toNullInt(v); n.Valid && n.Int64 >= 0 {
				return &n.Int64
			}
		}
	}
	return nil
}

// text is a catalog cell (string or bytes depending on the driver) as a string.
func text(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case []byte:
		return string(x)
	}
	return fmt.Sprint(v)
}
