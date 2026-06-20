# QueryDock DB2 backend

This local Go service lets the Flutter app use IBM Db2 through a small JSON API.

## Run

For CI or local smoke checks without IBM client libraries:

```powershell
cd backend\db2
go test ./...
```

For real Db2 connectivity, install the IBM Db2 CLI/ODBC client, add the Go
driver, then run with the `db2driver` build tag:

```powershell
cd backend\db2
go get github.com/ibmdb/go_ibm_db
go run -tags db2driver .
```

The service listens on `127.0.0.1:8792` by default. Override it with:

```powershell
$env:QUERYDOCK_DB2_ADDR="127.0.0.1:8792"
go run -tags db2driver .
```

Flutter DB2 profiles point at this URL with the "Go backend URL" field.
