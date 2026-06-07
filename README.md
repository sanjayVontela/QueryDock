# QueryDock

QueryDock is a cross-platform PostgreSQL(for now) workbench built with Flutter. It
provides a database navigator, SQL editor and autocomplete, editable result
grids, schema diagrams, connection protection, and optional AI-assisted query
generation.

## Download

Prebuilt Windows releases are available from the repository's
[Releases](https://github.com/sanjayVontela/db-viewer/releases) page.

1. Download `QueryDock-vX.Y.Z-windows-x64.zip`.
2. Extract the complete ZIP.
3. Run `querydock.exe`.

Windows may display a SmartScreen warning until release binaries are signed
with a trusted code-signing certificate.

## GitHub Copilot Setup

QueryDock can use GitHub Copilot to answer database questions and generate SQL
from the schemas, tables, and scripts you attach as context. This requires an
active GitHub Copilot plan and the separate GitHub Copilot CLI.

### 1. Sign In With GitHub CLI

Install GitHub CLI and sign in:

```powershell
winget install GitHub.cli
gh auth login
```

Copy the authenticated GitHub OAuth token to the Windows clipboard:

```powershell
gh auth token | Set-Clipboard
```

Keep the token private. Do not commit it, include it in screenshots, or share
it with another person.

### 2. Install Copilot CLI

The GitHub CLI and Copilot CLI are separate applications. Install Copilot CLI:

```powershell
winget install GitHub.Copilot
```

Restart QueryDock and your terminal after installation, then verify:

```powershell
copilot --version
```

### 3. Configure QueryDock

1. Open QueryDock.
2. Select **AI > Provider Settings...**.
3. Select **GitHub Copilot**.
4. Paste the token copied from `gh auth token` and save.
5. Open the AI assistant and attach the required schema, table, or SQL script.
6. Enter a request such as `Generate a query that lists the latest orders with customer names`.

The GitHub account must have an active Copilot subscription.
Organization-managed accounts also require the Copilot CLI policy to be
enabled by an administrator.

### Fine-Grained Token Alternative

If the token from GitHub CLI is unavailable, create a dedicated token:

1. Open [GitHub fine-grained personal access tokens](https://github.com/settings/personal-access-tokens/new).
2. Set **Resource owner** to your personal GitHub account, not an organization.
3. Under **Permissions**, select **Account permissions**.
4. Add **Copilot Requests** with write access.
5. Generate and copy the token.

Classic tokens beginning with `ghp_` are not supported. Use a fine-grained
token, normally beginning with `github_pat_`, and paste it into QueryDock's
GitHub Copilot token field.

QueryDock stores the token using the operating system's secure credential
storage. Attached database context can contain sensitive metadata, so review
it before sending a request.

## Development

```powershell
flutter pub get
flutter run -d windows
```

Run the checks before submitting a change:

```powershell
dart analyze
flutter test
```

## Creating A Release

Update the version in `pubspec.yaml`, commit the release, then push a version
tag:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

The release workflow builds and tests QueryDock on GitHub, packages the full
Windows runtime, creates a SHA-256 checksum, and publishes both files under
GitHub Releases.
