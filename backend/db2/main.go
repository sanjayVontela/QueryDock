package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type server struct {
	mu       sync.Mutex
	sessions map[string]*db2Session
}

type db2Session struct {
	db *sql.DB
}

type connectRequest struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Database string `json:"database"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type sessionRequest struct {
	SessionID string `json:"sessionId"`
}

func main() {
	addr := os.Getenv("QUERYDOCK_DB2_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8792"
	}

	s := &server{sessions: map[string]*db2Session{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/connect", s.connect)
	mux.HandleFunc("/schemas", s.withSession(s.schemas))
	mux.HandleFunc("/tables", s.withSession(s.tables))
	mux.HandleFunc("/table", s.withSession(s.table))
	mux.HandleFunc("/query", s.withSession(s.query))
	mux.HandleFunc("/table-data", s.withSession(s.tableData))
	mux.HandleFunc("/update-rows", s.withSession(s.updateRows))
	mux.HandleFunc("/import-rows", s.withSession(s.importRows))
	mux.HandleFunc("/search", s.withSession(s.search))
	mux.HandleFunc("/autocommit", s.withSession(s.autoCommit))
	mux.HandleFunc("/commit", s.withSession(s.commit))
	mux.HandleFunc("/rollback", s.withSession(s.rollback))
	mux.HandleFunc("/close", s.close)

	log.Printf("QueryDock DB2 backend listening on http://%s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func (s *server) connect(w http.ResponseWriter, r *http.Request) {
	var req connectRequest
	if !decode(w, r, &req) {
		return
	}
	if req.Port == 0 {
		req.Port = 50000
	}
	dsn := fmt.Sprintf(
		"HOSTNAME=%s;PORT=%d;DATABASE=%s;UID=%s;PWD=%s",
		req.Host,
		req.Port,
		req.Database,
		req.Username,
		req.Password,
	)
	db, err := sql.Open("go_ibm_db", dsn)
	if err != nil {
		if strings.Contains(err.Error(), "unknown driver") {
			err = fmt.Errorf(
				"%w. Build the backend with -tags db2driver after installing the IBM Db2 CLI/ODBC client and adding github.com/ibmdb/go_ibm_db",
				err,
			)
		}
		writeError(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		writeError(w, err)
		return
	}

	sessionID := fmt.Sprintf("%d", time.Now().UnixNano())
	s.mu.Lock()
	s.sessions[sessionID] = &db2Session{db: db}
	s.mu.Unlock()
	writeJSON(w, map[string]any{"sessionId": sessionID})
}

func (s *server) withSession(handler func(http.ResponseWriter, *http.Request, *db2Session, map[string]any)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if !decode(w, r, &body) {
			return
		}
		sessionID, _ := body["sessionId"].(string)
		s.mu.Lock()
		session := s.sessions[sessionID]
		s.mu.Unlock()
		if session == nil {
			writeError(w, errors.New("DB2 session not found"))
			return
		}
		handler(w, r, session, body)
	}
}

func (s *server) close(w http.ResponseWriter, r *http.Request) {
	var req sessionRequest
	if !decode(w, r, &req) {
		return
	}
	s.mu.Lock()
	session := s.sessions[req.SessionID]
	delete(s.sessions, req.SessionID)
	s.mu.Unlock()
	if session != nil {
		_ = session.db.Close()
	}
	writeJSON(w, map[string]any{"ok": true})
}

func (s *server) schemas(w http.ResponseWriter, r *http.Request, session *db2Session, _ map[string]any) {
	rows, err := session.db.QueryContext(r.Context(), `
SELECT SCHEMANAME
FROM SYSCAT.SCHEMATA
WHERE SCHEMANAME NOT LIKE 'SYS%'
ORDER BY SCHEMANAME`)
	if err != nil {
		writeError(w, err)
		return
	}
	defer rows.Close()
	var schemas []map[string]any
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			writeError(w, err)
			return
		}
		schemas = append(schemas, map[string]any{
			"name":         strings.TrimSpace(name),
			"tablesLoaded": false,
			"tables":       []any{},
		})
	}
	writeJSON(w, map[string]any{"schemas": schemas})
}

func (s *server) tables(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	schema := strings.ToUpper(stringValue(body, "schema"))
	rows, err := session.db.QueryContext(r.Context(), `
SELECT TABNAME, TYPE, COALESCE(CARD, 0), COALESCE(REMARKS, '')
FROM SYSCAT.TABLES
WHERE TABSCHEMA = ?
  AND TYPE IN ('T', 'V')
ORDER BY TYPE, TABNAME`, schema)
	if err != nil {
		writeError(w, err)
		return
	}
	defer rows.Close()
	var tables []map[string]any
	for rows.Next() {
		var name, typ, remarks string
		var card int64
		if err := rows.Scan(&name, &typ, &card, &remarks); err != nil {
			writeError(w, err)
			return
		}
		tables = append(tables, map[string]any{
			"name":          strings.TrimSpace(name),
			"relationType":  relationType(typ),
			"estimatedRows": card,
			"comment":       strings.TrimSpace(remarks),
			"columnsLoaded": false,
			"columns":       []any{},
			"ddl":           "",
		})
	}
	writeJSON(w, map[string]any{"tables": tables})
}

func (s *server) table(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	schema := strings.ToUpper(stringValue(body, "schema"))
	table := strings.ToUpper(stringValue(body, "table"))
	metadata, err := loadTable(r.Context(), session.db, schema, table)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]any{"table": metadata})
}

func loadTable(ctx context.Context, db *sql.DB, schema string, table string) (map[string]any, error) {
	columnRows, err := db.QueryContext(ctx, `
SELECT COLNAME, TYPENAME, LENGTH, SCALE, NULLS, KEYSEQ, COALESCE(DEFAULT, ''), COALESCE(REMARKS, '')
FROM SYSCAT.COLUMNS
WHERE TABSCHEMA = ? AND TABNAME = ?
ORDER BY COLNO`, schema, table)
	if err != nil {
		return nil, err
	}
	defer columnRows.Close()

	var columns []map[string]any
	for columnRows.Next() {
		var name, typeName, nullable, defaultValue, remarks string
		var length, scale int
		var keySeq sql.NullInt64
		if err := columnRows.Scan(&name, &typeName, &length, &scale, &nullable, &keySeq, &defaultValue, &remarks); err != nil {
			return nil, err
		}
		dataType := strings.TrimSpace(typeName)
		if length > 0 {
			if scale > 0 {
				dataType = fmt.Sprintf("%s(%d,%d)", dataType, length, scale)
			} else {
				dataType = fmt.Sprintf("%s(%d)", dataType, length)
			}
		}
		columns = append(columns, map[string]any{
			"name":         strings.TrimSpace(name),
			"dataType":     dataType,
			"nullable":     nullable == "Y",
			"primaryKey":   keySeq.Valid,
			"defaultValue": strings.TrimSpace(defaultValue),
			"comment":      strings.TrimSpace(remarks),
		})
	}

	return map[string]any{
		"name":          table,
		"ddl":           "",
		"relationType":  "Table",
		"columnsLoaded": true,
		"columns":       columns,
		"constraints":   []any{},
		"indexes":       []any{},
		"foreignKeys":   []any{},
	}, nil
}

func (s *server) query(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	sqlText := stringValue(body, "sql")
	maxRows := intValue(body, "maxRows", 5000)
	var results []queryResult
	for _, statement := range splitStatements(sqlText) {
		result, err := runQuery(r.Context(), session.db, statement, maxRows)
		if err != nil {
			writeError(w, err)
			return
		}
		results = append(results, result)
	}
	writeJSON(w, map[string]any{"results": results})
}

func (s *server) tableData(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	schema := stringValue(body, "schema")
	table := stringValue(body, "table")
	limit := intValue(body, "limit", 500)
	offset := intValue(body, "offset", 0)
	orderBy := stringValue(body, "orderBy")
	ascending := boolValue(body, "ascending", true)
	sqlText := fmt.Sprintf("SELECT * FROM %s.%s", quote(schema), quote(table))
	if orderBy != "" {
		direction := "ASC"
		if !ascending {
			direction = "DESC"
		}
		sqlText += fmt.Sprintf(" ORDER BY %s %s", quote(orderBy), direction)
	}
	sqlText += fmt.Sprintf(" OFFSET %d ROWS FETCH NEXT %d ROWS ONLY", offset, limit)
	result, err := runQuery(r.Context(), session.db, sqlText, limit)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]any{"result": result})
}

func (s *server) updateRows(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	items, _ := body["updates"].([]any)
	var affectedTotal int64
	tx, err := session.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, err)
		return
	}
	for _, item := range items {
		update, ok := item.(map[string]any)
		if !ok {
			continue
		}
		schema := stringValue(update, "schema")
		table := stringValue(update, "table")
		changes, _ := update["changes"].(map[string]any)
		primaryKey, _ := update["primaryKey"].(map[string]any)
		originalValues, _ := update["originalValues"].(map[string]any)
		if schema == "" || table == "" || len(changes) == 0 || len(primaryKey) == 0 {
			continue
		}

		var args []any
		var assignments []string
		for column, value := range changes {
			assignments = append(assignments, quote(column)+" = ?")
			args = append(args, value)
		}
		var predicates []string
		for column, value := range primaryKey {
			if value == nil {
				predicates = append(predicates, quote(column)+" IS NULL")
			} else {
				predicates = append(predicates, quote(column)+" = ?")
				args = append(args, value)
			}
		}
		for column, value := range originalValues {
			if _, isPrimaryKey := primaryKey[column]; isPrimaryKey {
				continue
			}
			if value == nil {
				predicates = append(predicates, quote(column)+" IS NULL")
			} else {
				predicates = append(predicates, quote(column)+" = ?")
				args = append(args, value)
			}
		}
		sqlText := fmt.Sprintf(
			"UPDATE %s.%s SET %s WHERE %s",
			quote(schema),
			quote(table),
			strings.Join(assignments, ", "),
			strings.Join(predicates, " AND "),
		)
		result, err := tx.ExecContext(r.Context(), sqlText, args...)
		if err != nil {
			_ = tx.Rollback()
			writeError(w, err)
			return
		}
		affected, _ := result.RowsAffected()
		if affected != 1 {
			_ = tx.Rollback()
			writeError(w, fmt.Errorf("row changed or was deleted before save: %s.%s", schema, table))
			return
		}
		affectedTotal += affected
	}
	if err := tx.Commit(); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]any{"affectedRows": affectedTotal})
}

func (s *server) importRows(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	schema := stringValue(body, "schema")
	table := stringValue(body, "table")
	rawColumns, _ := body["columns"].([]any)
	rawRows, _ := body["rows"].([]any)
	if schema == "" || table == "" || len(rawColumns) == 0 || len(rawRows) == 0 {
		writeJSON(w, map[string]any{"affectedRows": 0})
		return
	}
	var columns []string
	for _, column := range rawColumns {
		columns = append(columns, quote(fmt.Sprint(column)))
	}
	placeholders := strings.TrimRight(strings.Repeat("?,", len(columns)), ",")
	sqlText := fmt.Sprintf(
		"INSERT INTO %s.%s (%s) VALUES (%s)",
		quote(schema),
		quote(table),
		strings.Join(columns, ", "),
		placeholders,
	)
	tx, err := session.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, err)
		return
	}
	statement, err := tx.PrepareContext(r.Context(), sqlText)
	if err != nil {
		_ = tx.Rollback()
		writeError(w, err)
		return
	}
	defer statement.Close()
	var affectedTotal int64
	for _, rawRow := range rawRows {
		row, _ := rawRow.([]any)
		args := make([]any, len(columns))
		for index := range columns {
			if index < len(row) {
				args[index] = row[index]
			}
		}
		result, err := statement.ExecContext(r.Context(), args...)
		if err != nil {
			_ = tx.Rollback()
			writeError(w, err)
			return
		}
		affected, _ := result.RowsAffected()
		affectedTotal += affected
	}
	if err := tx.Commit(); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]any{"affectedRows": affectedTotal})
}

func (s *server) search(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	query := "%" + strings.ToUpper(stringValue(body, "query")) + "%"
	rows, err := session.db.QueryContext(r.Context(), `
SELECT 'Table', TABSCHEMA, TABNAME, COALESCE(REMARKS, '')
FROM SYSCAT.TABLES
WHERE UPPER(TABNAME) LIKE ? OR UPPER(COALESCE(REMARKS, '')) LIKE ?
FETCH FIRST 250 ROWS ONLY`, query, query)
	if err != nil {
		writeError(w, err)
		return
	}
	defer rows.Close()
	var results []map[string]any
	for rows.Next() {
		var typ, schema, name, detail string
		if err := rows.Scan(&typ, &schema, &name, &detail); err != nil {
			writeError(w, err)
			return
		}
		results = append(results, map[string]any{
			"type":   strings.TrimSpace(typ),
			"schema": strings.TrimSpace(schema),
			"name":   strings.TrimSpace(name),
			"detail": strings.TrimSpace(detail),
		})
	}
	writeJSON(w, map[string]any{"results": results})
}

func (s *server) autoCommit(w http.ResponseWriter, r *http.Request, session *db2Session, body map[string]any) {
	enabled := boolValue(body, "enabled", true)
	value := "0"
	if enabled {
		value = "1"
	}
	_, err := session.db.ExecContext(r.Context(), "CALL SYSPROC.ADMIN_CMD('UPDATE DB CFG USING DFT_SQLMATHWARN "+value+"')")
	if err != nil {
		// Autocommit is owned by database/sql connections; keep the endpoint stable
		// even when a specific Db2 server rejects command-based toggling.
		writeJSON(w, map[string]any{"ok": true})
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func (s *server) commit(w http.ResponseWriter, r *http.Request, session *db2Session, _ map[string]any) {
	_, err := session.db.ExecContext(r.Context(), "COMMIT")
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func (s *server) rollback(w http.ResponseWriter, r *http.Request, session *db2Session, _ map[string]any) {
	_, err := session.db.ExecContext(r.Context(), "ROLLBACK")
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

type queryResult struct {
	Columns         []string `json:"columns"`
	Rows            [][]any  `json:"rows"`
	RowCount        int      `json:"rowCount"`
	AffectedRows    int64    `json:"affectedRows"`
	ElapsedMs       int64    `json:"elapsedMs"`
	RowLimitApplied bool     `json:"rowLimitApplied"`
}

func runQuery(ctx context.Context, db *sql.DB, sqlText string, maxRows int) (queryResult, error) {
	started := time.Now()
	rows, err := db.QueryContext(ctx, sqlText)
	if err == nil {
		defer rows.Close()
		columns, err := rows.Columns()
		if err != nil {
			return queryResult{}, err
		}
		result := queryResult{Columns: columns, ElapsedMs: time.Since(started).Milliseconds()}
		for rows.Next() {
			values := make([]any, len(columns))
			pointers := make([]any, len(columns))
			for i := range values {
				pointers[i] = &values[i]
			}
			if err := rows.Scan(pointers...); err != nil {
				return queryResult{}, err
			}
			if len(result.Rows) < maxRows {
				result.Rows = append(result.Rows, normalize(values))
			} else {
				result.RowLimitApplied = true
			}
		}
		result.RowCount = len(result.Rows)
		return result, rows.Err()
	}

	execResult, execErr := db.ExecContext(ctx, sqlText)
	if execErr != nil {
		return queryResult{}, execErr
	}
	affected, _ := execResult.RowsAffected()
	return queryResult{
		Columns:      []string{"Affected Rows"},
		Rows:         [][]any{{affected}},
		RowCount:     1,
		AffectedRows: affected,
		ElapsedMs:    time.Since(started).Milliseconds(),
	}, nil
}

func normalize(values []any) []any {
	out := make([]any, len(values))
	for i, value := range values {
		switch typed := value.(type) {
		case []byte:
			out[i] = string(typed)
		case time.Time:
			out[i] = typed.Format(time.RFC3339Nano)
		default:
			out[i] = typed
		}
	}
	return out
}

func splitStatements(sqlText string) []string {
	var statements []string
	for _, statement := range strings.Split(sqlText, ";") {
		trimmed := strings.TrimSpace(statement)
		if trimmed != "" {
			statements = append(statements, trimmed)
		}
	}
	return statements
}

func relationType(value string) string {
	if strings.TrimSpace(value) == "V" {
		return "View"
	}
	return "Table"
}

func quote(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `""`) + `"`
}

func decode(w http.ResponseWriter, r *http.Request, target any) bool {
	if r.Method != http.MethodPost {
		writeError(w, errors.New("POST required"))
		return false
	}
	if err := json.NewDecoder(r.Body).Decode(target); err != nil {
		writeError(w, err)
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
}

func stringValue(body map[string]any, key string) string {
	value, _ := body[key].(string)
	return value
}

func intValue(body map[string]any, key string, fallback int) int {
	switch value := body[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	default:
		return fallback
	}
}

func boolValue(body map[string]any, key string, fallback bool) bool {
	value, ok := body[key].(bool)
	if !ok {
		return fallback
	}
	return value
}
