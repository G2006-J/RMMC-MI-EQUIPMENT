#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project_dir="${1:?Usage: prepare-db-test-project.sh <temporary-project-directory>}"
migrations_dir="$project_dir/supabase/migrations"

mkdir -p "$migrations_dir"
cat > "$project_dir/supabase/config.toml" <<'TOML'
project_id = "rmmc-mi-equipment-ci"

[db]
major_version = 17

[db.seed]
enabled = false
TOML

# Preserve source migration files and apply them in the dependency order documented in README.
migrations=(
  202610280001_create_equipment_schema.sql
  202610230002_align_existing_schema.sql
  202610230003_auto_create_student_borrowers.sql
  202610280002_add_account_profile_details.sql
  202610260001_equipment_images_quantity.sql
  202610270001_allow_multiple_equipment_requests.sql
  202610270002_equipment_available_quantities.sql
  202610270003_approved_requests_only_reduce_availability.sql
  202611010001_security_hardening_and_role_access.sql
  202611010002_borrower_request_search_and_account_names.sql
  202611020001_feedback_moderation_and_profile_fields.sql
  202611020002_profile_photos_and_currently_borrowed_workspace.sql
  202611020003_borrowed_and_reservations_admin_view.sql
  202611020004_equipment_tracking_statuses.sql
  202611020005_request_quantities_and_custodian_approvals.sql
  202611020006_active_equipment_tracking_only.sql
  202611030001_borrower_account_approval_and_user_link.sql
  202611030002_request_integrity_and_reservation_expiry.sql
  202611030003_borrowing_release_overdue_and_audit.sql
  202611030004_audit_and_integrity_fixes.sql
  202611030005_notifications_and_borrower_agreement.sql
  202611060001_privacy_consent_deactivation.sql
  202611060002_pending_account_reads_and_anonymization_audit.sql
  202611060003_my_account_state_and_admin_photo_delete.sql
  202611060004_guard_admin_account_actions.sql
)

index=1
for migration in "${migrations[@]}"; do
  source="$repo_root/supabase/migrations/$migration"
  if [[ ! -f "$source" ]]; then
    echo "Missing required migration: $source" >&2
    exit 1
  fi

  timestamp="$(printf '202601010000%02d' "$index")"
  suffix="${migration#*_}"
  cp "$source" "$migrations_dir/${timestamp}_${suffix}"
  index=$((index + 1))
done
