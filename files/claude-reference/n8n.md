# n8n

Read this when an n8n workflow looks broken, a credential error appears, or you're picking a transport for a scheduled job. Not needed otherwise.

## `execute_workflow` misreports credential errors

`mcp__n8n-mcp__execute_workflow` returns "Credentials not found" on HTTP Basic Auth nodes (and other generic credential types) even when the credentials are correctly attached and the same workflow runs fine from the n8n UI. The UI resolves credentials through a different path that the MCP doesn't replicate.

The error is the MCP lying, not a missing credential. Do not loop on it, do not re-create the credential, and do not conclude the workflow is broken.

What actually works:

- Use `executionMode: "production"`. Manual mode fails on generic credentials essentially always; production mode usually resolves them (a production run that reaches the upstream API and returns a real error like `PERMISSION_DENIED` is a success signal, the credential resolved).
- Code nodes and credential-free nodes execute fine in either mode. Isolate the failing step there first.
- Read results with `get_execution` on the execution ID, whichever way the run was triggered.
- If the MCP genuinely can't resolve the credential, test the underlying call directly from Bash (see below) rather than parking the diagnostic.

`googleApi` credentials (BigQuery, Sheets) resolve reliably through the MCP in both modes. The problem is scoped to generic types: Basic Auth, Bearer, header auth.

## `update_workflow` vs `publish_workflow`

| | Generic Basic Auth / Bearer | `googleApi` |
|---|---|---|
| `update_workflow` | preserved | preserved |
| `publish_workflow` | **dropped** | preserved |

`publish_workflow` regenerates node IDs, which breaks generic credential bindings and forces a manual UI re-attach. `update_workflow` on an already-active workflow auto-publishes and keeps the bindings.

Default to `update_workflow` for every iteration. Reserve `publish_workflow` for a final committed version, and expect one re-attach pass after it.

Ignore the `"HTTP Request nodes were skipped during credential auto-assignment"` warning on `update_workflow`. It's wrong; bindings on the active version survive.

## The SFTP node is unusable on n8n Cloud

`n8n-nodes-base.ftp` with `protocol=sftp` hangs indefinitely on connect in n8n Cloud. Upstream `ssh2-sftp-client` v12 regression, [n8n#19523](https://github.com/n8n-io/n8n/issues/19523), no fix shipped as of mid-2026.

It is not an IP allowlist problem: paramiko connects to the same host fine. n8n Cloud also has no static egress IPs, so allowlisting isn't available as a fallback anyway.

Don't ingest over SFTP from n8n Cloud. Use a Cloud Run Job with paramiko plus Cloud Scheduler: secret in Secret Manager, idempotent staging table with a DELETE/INSERT MERGE on a natural key, BQ load jobs rather than streaming inserts (no streaming buffer delay on deletes). That's the template for any SFTP or EDI feed.

## Running credentialed calls yourself

An MCP execution failure is not a reason to hand a command back to Adam. Pull the password from the credentials file and drive the protocol directly:

```bash
curl -u user:pass sftp://host/path/file.csv     # simplest, no extra deps
sshpass -p "$PASS" sftp user@host               # when curl's sftp support is missing
```

`expect` handles prompts curl and sshpass can't script. For anything beyond a one-shot fetch (key auth, directory walks, retries), use `paramiko` in Python; it's also what the Cloud Run Job path uses, so a local paramiko test doubles as a deploy rehearsal.

The only things that go back to Adam: UI-only credential creation in n8n, a genuine judgment call, or something destructive he hasn't approved.
