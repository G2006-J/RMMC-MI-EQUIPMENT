# RMMC-MI Equipment Borrowing System

A browser-first, installable PWA built with Next.js, React, Tailwind CSS, and Supabase. The local development server runs at `http://localhost:5501`.

## Run locally

1. Install Node.js 20.19 or newer.
2. Copy `.env.example` to `.env.local` and set the Supabase project URL and publishable key.
3. In the Supabase project's SQL Editor, create the app's database schema by running [`supabase/migrations/202610280001_create_equipment_schema.sql`](./supabase/migrations/202610280001_create_equipment_schema.sql), followed by [`supabase/migrations/202610230002_align_existing_schema.sql`](./supabase/migrations/202610230002_align_existing_schema.sql), [`supabase/migrations/202610230003_auto_create_student_borrowers.sql`](./supabase/migrations/202610230003_auto_create_student_borrowers.sql), [`supabase/migrations/202610280002_add_account_profile_details.sql`](./supabase/migrations/202610280002_add_account_profile_details.sql), [`supabase/migrations/202610260001_equipment_images_quantity.sql`](./supabase/migrations/202610260001_equipment_images_quantity.sql), [`supabase/migrations/202610270001_allow_multiple_equipment_requests.sql`](./supabase/migrations/202610270001_allow_multiple_equipment_requests.sql), [`supabase/migrations/202610270002_equipment_available_quantities.sql`](./supabase/migrations/202610270002_equipment_available_quantities.sql), [`supabase/migrations/202610270003_approved_requests_only_reduce_availability.sql`](./supabase/migrations/202610270003_approved_requests_only_reduce_availability.sql), [`supabase/migrations/202611010001_security_hardening_and_role_access.sql`](./supabase/migrations/202611010001_security_hardening_and_role_access.sql), [`supabase/migrations/202611010002_borrower_request_search_and_account_names.sql`](./supabase/migrations/202611010002_borrower_request_search_and_account_names.sql), [`supabase/migrations/202611020001_feedback_moderation_and_profile_fields.sql`](./supabase/migrations/202611020001_feedback_moderation_and_profile_fields.sql), and [`supabase/migrations/202611020002_profile_photos_and_currently_borrowed_workspace.sql`](./supabase/migrations/202611020002_profile_photos_and_currently_borrowed_workspace.sql), in that order. Then apply [`supabase/migrations/202611020003_borrowed_and_reservations_admin_view.sql`](./supabase/migrations/202611020003_borrowed_and_reservations_admin_view.sql), [`supabase/migrations/202611020004_equipment_tracking_statuses.sql`](./supabase/migrations/202611020004_equipment_tracking_statuses.sql), and [`supabase/migrations/202611020005_request_quantities_and_custodian_approvals.sql`](./supabase/migrations/202611020005_request_quantities_and_custodian_approvals.sql), in that order. The baseline creates the core tables and a `General` category for a new project; the following migrations add policies and borrowing, feedback, image, quantity, and security workflows. If your project already has these core tables, skip the baseline migration and use the schema-alignment migrations as appropriate. Do **not** run the earlier `202610220001_equipment_borrowing.sql` or `202610230001_equipment_feedback_audit.sql` migrations; they use the app's original, different schema.
   After those migrations, apply [`supabase/migrations/202611030001_borrower_account_approval_and_user_link.sql`](./supabase/migrations/202611030001_borrower_account_approval_and_user_link.sql) and [`supabase/migrations/202611030002_request_integrity_and_reservation_expiry.sql`](./supabase/migrations/202611030002_request_integrity_and_reservation_expiry.sql), in order. The second migration adds serialized request approvals, borrower cancellation, required decline reasons, and reservation pickup expiry.
   Then review and apply [`supabase/migrations/202611030003_borrowing_release_overdue_and_audit.sql`](./supabase/migrations/202611030003_borrowing_release_overdue_and_audit.sql), followed by [`supabase/migrations/202611030004_audit_and_integrity_fixes.sql`](./supabase/migrations/202611030004_audit_and_integrity_fixes.sql). These separate approval from release, record release and return conditions, report damage or loss, add daily overdue checks, and harden audit/integrity rules. Released and overdue items continue reducing available stock; damaged units are tracked out of service without removing the remaining usable quantity, and lost quantities are removed from inventory. To reconcile specific legacy issued rows, an administrator or property custodian should first review `select * from public.preview_legacy_issued_borrowings();`, then pass only selected IDs from that preview, for example `select public.mark_legacy_issued_borrowings_released(array[123, 456]);`. Run [`supabase/tests/borrowing_release_overdue.sql`](./supabase/tests/borrowing_release_overdue.sql) against a local Supabase database after applying both migrations.
4. Install dependencies and start the app:

   ```powershell
   npm install
   npm run dev
   ```

5. In Supabase, configure both the **Magic Link or OTP** and **Confirm signup** email templates to show `{{ .Token }}` (instructions below).
6. Open `http://localhost:5501`, create an account, verify the emailed signup code, and sign in with the emailed one-time code.

### Configure email-code sign-in

The app requests an email OTP with Supabase `signInWithOtp` and verifies it with `verifyOtp`. The email content is controlled by the Supabase project, not by this app. To send a code instead of a clickable sign-in link:

1. Open **Authentication → Email Templates → Magic Link or OTP** in the Supabase Dashboard.
2. Set the subject to `Login Code: {{ .Token }}`.
3. Replace the template body with HTML that includes `{{ .Token }}` and does not include `{{ .ConfirmationURL }}` or a link/button using it. For example:

   ```html
   <h1>Your sign-in code</h1>
   <p>Enter this code in the app to sign in:</p>
   <p style="font-size:32px;font-weight:bold;letter-spacing:8px">{{ .Token }}</p>
   <p>If you did not request this code, you can ignore this email.</p>
   ```

4. Save the template. The app’s sign-in screen will prompt for the code and verify it. If the email still contains a link, check that the saved template no longer references `{{ .ConfirmationURL }}`.

### Configure signup verification codes

Password-based signup uses Supabase `signUp` and verifies the account with `verifyOtp` using the `signup` type. To send a code instead of a confirmation link:

1. Open **Authentication → Email Templates → Confirm signup** in the Supabase Dashboard.
2. Set the subject to `Your verification code: {{ .Token }}`.
3. Replace the template body with HTML that includes `{{ .Token }}` and does not include `{{ .ConfirmationURL }}`. For example:

   ```html
   <h1>Verify your email</h1>
   <p>Enter this code in the app to activate your account:</p>
   <p style="font-size:32px;font-weight:bold;letter-spacing:8px">{{ .Token }}</p>
   <p>If you did not create an account, you can ignore this email.</p>
   ```

4. Save the template. The signup screen will prompt for this code before activating the account.

### Security settings and role access

- Apply the security-hardening, borrower-search, and follow-up migrations below to the same Supabase project used by `.env.local`. Database row-level security and security-definer functions enforce access independently of the visible dashboard. `admin` accounts retain full operations access. `property_custodian` accounts can manage equipment and feedback, search and approve/decline borrower and reservation requests, and edit their own account settings. Reports and member roles remain administrator-only.
- In **Authentication → Settings**, require email confirmation, configure a minimum password length of at least 8 characters, and set conservative email/OTP and password-reset rate limits. The signup form requires eight characters; Supabase Auth must allow the same minimum. Supabase Auth enforces login/email delivery limits on the server; the app also applies a short resend cooldown. Configure SMTP and CAPTCHA in Supabase Auth for production.
- Supabase Auth stores password hashes; this app never stores passwords or Supabase auth sessions in `localStorage`. The Supabase SSR client stores the session in cookies and marks them `Secure` in production. Serve production only over HTTPS.
- The browser uses only the Supabase publishable key. Keep `.env.local` out of source control; `.gitignore` excludes local environment files. Never add a Supabase service-role/secret key to a `NEXT_PUBLIC_*` variable, the browser bundle, or logs.
- Administrators can delete feedback replies; the database restricts this operation to verified, active administrator accounts. Account settings save department and course to the user's profile and linked borrower record.
- Administrators and property custodians can view Equipment tracking for current borrowed and reserved equipment only. Returned and unassigned inventory records are excluded. The workspace separates borrowed and reserved tables and can filter equipment by its database category, status, tag, or location. Entries include the borrower's name, department, location of use, amount, pickup time, return time, and profile photo when available. Profile photos are kept in a private Supabase Storage bucket and served through signed URLs.
- Borrower accounts can request a specific quantity of an item for borrowing or reservation. Database functions validate requested quantities against time-overlapping loans and reservations. Administrators and property custodians can approve or decline both request types.
- Sign-in validates the email/password first using a non-persistent Supabase Auth client. Only after a valid password does the app send the email verification code that creates the normal signed-in session.
- Apply [`supabase/migrations/202611020002_profile_photos_and_currently_borrowed_workspace.sql`](./supabase/migrations/202611020002_profile_photos_and_currently_borrowed_workspace.sql) after the feedback/profile-fields migration, then [`supabase/migrations/202611020003_borrowed_and_reservations_admin_view.sql`](./supabase/migrations/202611020003_borrowed_and_reservations_admin_view.sql), [`supabase/migrations/202611020004_equipment_tracking_statuses.sql`](./supabase/migrations/202611020004_equipment_tracking_statuses.sql), [`supabase/migrations/202611020005_request_quantities_and_custodian_approvals.sql`](./supabase/migrations/202611020005_request_quantities_and_custodian_approvals.sql), followed by [`supabase/migrations/202611020006_active_equipment_tracking_only.sql`](./supabase/migrations/202611020006_active_equipment_tracking_only.sql). The final migration drops and recreates the tracking function to support its return shape, then returns current loans and reservations only, excluding available and returned equipment.
- Database calls use the Supabase query builder and named RPC parameters. React renders submitted text as escaped text, equipment images are size/type checked and re-encoded before upload, and database triggers validate request and inventory fields and limit equipment requests to five per account per 10 minutes.
- This app has no webhook endpoints or custom cross-origin API. If either is added, verify webhook signatures and enforce an explicit origin allowlist before accepting requests. The app sends anti-framing, MIME-sniffing, referrer, and permissions headers.
- Run `npm audit` and `npm run lint` before release. Do not use `npm audit fix --force` without reviewing the resulting major-version changes.

### Run and debug in VS Code

Open this folder in VS Code and press **F5**. The included launch configuration starts the Next.js development server and opens Chrome at `http://localhost:5501`. You can also run `npm run dev` in the VS Code terminal and open that address in any modern browser.

### Use on a phone

This project is a responsive, installable Progressive Web App (PWA), not a separate native iOS/Android project. Open the deployed HTTPS site on your phone and use **Install app** (or Safari’s **Share → Add to Home Screen**) to add it to your home screen. The installed app uses the same sign-in, equipment, borrowing, reservation, and account actions as the browser version. A development server on your computer can be used for browser testing, but phone installation requires the app to be served over HTTPS.

## First administrator

New accounts receive the `staff` role. After creating and confirming your own account, use the Supabase SQL Editor to promote that account:

```sql
update public.profiles
set role = 'admin',
    account_status = 'active',
    updated_at = now()
where id = (
  select id
  from auth.users
  where email = 'your-institutional-email@example.org'
);

update public.borrowers
set status = 'active'
where user_id = (
  select id
  from auth.users
  where email = 'your-institutional-email@example.org'
);
```

`active` is the database's approved account status. Bootstrap the first administrator only after applying the borrower-account approval migration; this sets both the profile and linked borrower to active so the administrator is not left pending.

Only the `admin` role can add, edit, or remove equipment. Equipment changes are recorded in `equipment_audit_log`, and removal is soft-deletion so borrowing history remains intact. `admin` and `property_custodian` roles can review borrowing and reservation requests. Profile role values remain `admin`, `property_custodian`, and `staff`; users cannot change their own role.

## Included workflows

- Supabase email-code sign-in, password-based account registration with signup-code verification, password reset, and cookie refresh.
- New signups automatically receive a pending profile and `student` borrower row with a generated borrower number. An administrator or property custodian must approve the account before the borrower can submit requests.
- Equipment search, category filters, equipment status, storage location, and administrator-only inventory management with a database-backed change history.
- Shared member/admin feedback discussions with replies and administrator-managed status updates.
- Borrowing and reservation requests linked to the existing `borrowers`, `borrowings`, `borrowing_items`, and `equipment` records, with administrator/property-custodian review and return confirmation. Available amounts decrease for active borrowing requests and return after staff confirm the return; overlapping requests are accepted only up to the equipment quantity.
- Borrowings follow `requested → approved → released → returned`; release and return record the responsible staff member, timestamps, condition, and optional private photo. Damage and loss reports require manager resolution. A daily job flags overdue items, shows staff borrower contact details, and blocks borrowers with overdue equipment from submitting borrowing or reservation requests.
- In-app notifications cover request decisions, releases, returns, reservation expiry, account review, and daily due-soon/overdue reminders. Borrowers must accept the currently published, versioned agreement before submitting a request; the seeded agreement is clearly marked as placeholder text.
- Borrowers can cancel pending requests, staff must provide a decline reason, and managers can configure the reservation pickup grace period (1–1440 minutes; 30 minutes by default). Unpicked approved reservations expire automatically.
- Member activity, manager request queues, borrowing history, and CSV report export.
- Installable PWA manifest and an offline page. Private workspace data is never cached by the service worker.

## Notes

- After reviewing the SQL, apply [`supabase/migrations/202611030005_notifications_and_borrower_agreement.sql`](./supabase/migrations/202611030005_notifications_and_borrower_agreement.sql) after migration 004. It builds on `public.notifications`, schedules daily notification/retention maintenance, and adds versioned borrower agreement acceptance. Replace the starter agreement with school-approved text by publishing a new version from the administrator's Members & roles page.
- Run [`supabase/tests/notifications_and_borrower_agreement.sql`](./supabase/tests/notifications_and_borrower_agreement.sql) through the database test workflow after applying the migration.
- The publishable Supabase key is intended for browser use. Never put a Supabase service-role key in `.env.local` or client code.
- Borrowing and reservation requests require an active borrower row linked to the signed-in account by `user_id`.
- If Supabase reports missing tables or functions, ensure the migration ran successfully in the project that matches `.env.local`.
- To create a production build, run `npm run build`, then `npm start`.
#   R M M C - M I - E q u i p m e n t - B o r r o w i n g - S y s t e m  
 