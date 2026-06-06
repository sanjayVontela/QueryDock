# Production Deployment

The application includes secure credential storage, real PostgreSQL query
cancellation, protected-write confirmation, transactional row editing, and
optimistic conflict detection.

Before distributing a production build:

1. Use a dedicated PostgreSQL role for each environment.
2. Grant production browsing accounts `CONNECT`, `USAGE`, and `SELECT` only.
3. Use a separate, explicitly approved role when writes are required.
4. Require TLS with certificate verification for remote databases.
5. Sign the Windows executable and installer with the organization's
   Authenticode certificate.
6. Connect `FlutterError.onError` and `PlatformDispatcher.onError` to the
   organization's approved crash-reporting service.
7. Keep release symbols in the private build pipeline.
8. Run integration tests against a disposable PostgreSQL instance before each
   release.
9. Review generated SQL and logs to ensure they contain no customer data.
10. Back up and test restore procedures for every database exposed to writes.

The in-app write-protection checkbox is a safety prompt. PostgreSQL role
permissions remain the security boundary.
