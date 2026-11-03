# Repository Instructions

- Never rename, edit, or delete a migration that may have been applied to a live database. Fix forward with a new migration.
- Every new database function must set `search_path = ''`, check `auth.uid()` and the caller's role inside the function, and have `EXECUTE` revoked from `public` and `anon`.
- Enable row-level security on every new table and grant only the access required by its policies.
- Do not add npm dependencies without user approval.
- Do not apply a migration that rejects signup for missing privacy consent until the app signup checkbox and metadata are implemented and deployed.
- Treat client-supplied signup consent metadata as a recorded acceptance, not proof of identity.
- Account deactivation must be enforced by RLS and every relevant RPC; revoke active sessions when possible.
- Anonymization must retain borrowing and audit history, clear personal fields and photo paths, and remove profile-photo objects through the Storage API rather than SQL.
- Keep report-only CSP until reviewed, preserve camera access for QR scanning, and avoid exposing provider details in authentication errors.
- Make focused changes, preserve existing behavior, and run `npm test`, `npm run lint`, and `npm run build` after each requested part. Do not claim a check passed unless it completed successfully.