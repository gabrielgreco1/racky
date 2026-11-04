package main

import (
	"database/sql"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
	_ "github.com/microsoft/go-mssqldb"
	go_ora "github.com/sijms/go-ora/v2"
)

func urlEscape(s string) string { return url.QueryEscape(s) }

// target is what a DSN becomes: the driver, its connection string, and the secrets to scrub from messages.
type target struct {
	driver  string
	connStr string
	secrets []string
}

func parseURL(raw string, schemes ...string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		// Never echo the parse error: it contains the whole DSN, password included.
		return nil, invalid("the connection string is not a valid URL")
	}
	ok := false
	for _, s := range schemes {
		if strings.EqualFold(u.Scheme, s) {
			ok = true
		}
	}
	if !ok {
		return nil, invalid("the connection string must start with " + schemes[0] + "://")
	}
	if u.Hostname() == "" {
		return nil, invalid("the connection string has no host")
	}
	if p := u.Port(); p != "" {
		if n, err := strconv.Atoi(p); err != nil || n < 1 || n > 65535 {
			return nil, invalid("the port \"" + p + "\" is not valid")
		}
	}
	return u, nil
}

func credentials(u *url.URL) (user, pass string, secrets []string) {
	if u.User != nil {
		user = u.User.Username()
		pass, _ = u.User.Password()
	}
	if pass != "" {
		secrets = append(secrets, pass)
	}
	return
}

// ParseDSN turns the request's connection URL into a driver target. Only a short list of options passes through: nothing that
// reads or writes local files, loads plugins or turns on driver tracing.
func ParseDSN(engine, raw string) (*target, error) {
	switch engine {
	case "mysql":
		return parseMySQL(raw)
	case "sqlserver":
		return parseSQLServer(raw)
	case "oracle":
		return parseOracle(raw)
	}
	return nil, invalid("unknown engine")
}

func parseMySQL(raw string) (*target, error) {
	u, err := parseURL(raw, "mysql", "mariadb")
	if err != nil {
		return nil, err
	}
	user, pass, secrets := credentials(u)
	if user == "" {
		return nil, invalid("the connection string has no user")
	}
	port := u.Port()
	if port == "" {
		port = "3306"
	}
	cfg := mysql.NewConfig()
	cfg.User, cfg.Passwd = user, pass
	cfg.Net = "tcp"
	cfg.Addr = hostPort(u.Hostname(), port)
	cfg.DBName = strings.TrimPrefix(u.Path, "/")
	cfg.Timeout = 10 * time.Second
	cfg.TLSConfig = "preferred"
	q := u.Query()
	for _, key := range []string{"tls", "ssl-mode", "sslmode", "ssl"} {
		if v := q.Get(key); v != "" {
			switch strings.ToLower(v) {
			case "false", "disable", "disabled", "0":
				cfg.TLSConfig = "false"
			case "preferred", "prefer", "allow":
				cfg.TLSConfig = "preferred"
			case "require", "required", "skip-verify", "true_skip", "1", "true":
				cfg.TLSConfig = "skip-verify"
				if strings.EqualFold(v, "true") {
					cfg.TLSConfig = "true"
				}
			case "verify-ca", "verify_ca", "verify-full", "verify_identity", "verify-identity":
				cfg.TLSConfig = "true"
			default:
				return nil, invalid("tls=" + v + " is not one of disable, preferred, require, verify-full")
			}
		}
	}
	cfg.Params = map[string]string{}
	for _, key := range []string{"charset", "collation", "allowCleartextPasswords"} {
		if v := q.Get(key); v != "" {
			if key == "allowCleartextPasswords" {
				cfg.AllowCleartextPasswords = v == "true"
			} else {
				cfg.Params[key] = v
			}
		}
	}
	return &target{"mysql", cfg.FormatDSN(), secrets}, nil
}

func hostPort(host, port string) string {
	if strings.Contains(host, ":") { // IPv6
		return "[" + host + "]:" + port
	}
	return host + ":" + port
}

func parseSQLServer(raw string) (*target, error) {
	u, err := parseURL(raw, "sqlserver", "mssql")
	if err != nil {
		return nil, err
	}
	user, pass, secrets := credentials(u)
	if user == "" {
		return nil, invalid("the connection string has no user")
	}
	q := u.Query()
	out := url.Values{}
	if v := q.Get("database"); v != "" {
		out.Set("database", v)
	} else if v := q.Get("databaseName"); v != "" {
		out.Set("database", v)
	}
	// Encrypted by default without checking the certificate (like sslmode=require); the string can ask for more or less.
	out.Set("encrypt", "true")
	out.Set("TrustServerCertificate", "true")
	for _, key := range []string{"encrypt", "TrustServerCertificate", "hostNameInCertificate"} {
		if v := q.Get(key); v != "" {
			out.Set(key, v)
		}
	}
	out.Set("connection timeout", "10")
	out.Set("app name", "Racky")
	host := u.Hostname()
	if p := u.Port(); p != "" {
		host = hostPort(host, p)
	}
	cs := url.URL{Scheme: "sqlserver", User: url.UserPassword(user, pass), Host: host, Path: u.Path, RawQuery: out.Encode()}
	return &target{"sqlserver", cs.String(), secrets}, nil
}

func parseOracle(raw string) (*target, error) {
	u, err := parseURL(raw, "oracle")
	if err != nil {
		return nil, err
	}
	user, pass, secrets := credentials(u)
	if user == "" {
		return nil, invalid("the connection string has no user")
	}
	port := 1521
	if p := u.Port(); p != "" {
		port, _ = strconv.Atoi(p)
	}
	service := strings.TrimPrefix(u.Path, "/")
	q := u.Query()
	opts := map[string]string{"TIMEOUT": "10"}
	for _, key := range []string{"ssl", "ssl verify", "sid"} {
		if v := q.Get(key); v != "" {
			opts[key] = v
		}
	}
	if service == "" && opts["sid"] == "" {
		return nil, invalid("the connection string has no service name (oracle://user:pass@host:1521/SERVICE)")
	}
	return &target{"oracle", go_ora.BuildUrl(u.Hostname(), port, service, user, pass, opts), secrets}, nil
}

func (t *target) open() (*sql.DB, error) {
	db, err := sql.Open(t.driver, t.connStr)
	if err != nil {
		return nil, fmt.Errorf("could not set up the connection")
	}
	db.SetMaxOpenConns(1)
	return db, nil
}
