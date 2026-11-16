import { createServerClient } from "@supabase/ssr";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { NextResponse } from "next/server";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function errorResponse(message, status) {
  return NextResponse.json({ error: message }, { status });
}

export async function POST(request) {
  const origin = request.headers.get("origin");
  if (!origin || origin !== new URL(request.url).origin) {
    return errorResponse("This account action must come from the application.", 403);
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return errorResponse("A valid account identifier is required.", 400);
  }
  const targetId = payload?.userId;
  if (typeof targetId !== "string" || !UUID_PATTERN.test(targetId)) {
    return errorResponse("A valid account identifier is required.", 400);
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !publishableKey) {
    return errorResponse("Account deletion is unavailable right now. Please try again later.", 503);
  }
  if (!serviceRoleKey) {
    return errorResponse("Account deletion is unavailable right now. Please try again later.", 503);
  }

  const cookieStore = await cookies();
  const callerClient = createServerClient(url, publishableKey, {
    cookieOptions: {
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
    },
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
      },
    },
  });
  const { data: authData, error: authError } = await callerClient.auth.getUser();
  if (authError || !authData.user) {
    return errorResponse("Sign in with an active administrator account to continue.", 401);
  }

  const { data: actorProfile, error: actorProfileError } = await callerClient
    .from("profiles")
    .select("role, account_status")
    .eq("id", authData.user.id)
    .maybeSingle();
  if (actorProfileError) {
    return errorResponse("Administrator access could not be verified.", 503);
  }
  if (actorProfile?.role !== "admin" || actorProfile.account_status !== "active") {
    return errorResponse("Only an active administrator can permanently delete an account.", 403);
  }
  if (targetId === authData.user.id) {
    return errorResponse("An administrator cannot permanently delete their own account.", 400);
  }

  const adminClient = createSupabaseClient(url, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
  });
  const { data: targetProfile, error: targetProfileError } = await adminClient
    .from("profiles")
    .select("id, role, account_status, full_name, first_name, last_name, email, department, course, gender, profile_photo_path")
    .eq("id", targetId)
    .maybeSingle();
  if (targetProfileError) {
    return errorResponse("The target account could not be loaded.", 503);
  }
  if (!targetProfile) {
    return errorResponse("The account no longer exists.", 404);
  }
  if (targetProfile.account_status !== "inactive") {
    return errorResponse("Deactivate the account before permanently deleting it.", 409);
  }

  const { data: borrower, error: borrowerError } = await adminClient
    .from("borrowers")
    .select("borrower_id, user_id, first_name, middle_name, last_name, email, department, course, gender, profile_photo_path")
    .eq("user_id", targetId)
    .maybeSingle();
  if (borrowerError) {
    return errorResponse("The linked borrower record could not be loaded.", 503);
  }
  if (!borrower) {
    return errorResponse("The linked borrower record is missing; the account was not deleted.", 409);
  }

  const alreadyAnonymized = targetProfile.full_name === "Anonymized account"
    && targetProfile.first_name === "Anonymized"
    && targetProfile.last_name === "User"
    && targetProfile.email === ""
    && targetProfile.department === null
    && targetProfile.course === null
    && targetProfile.gender === null
    && targetProfile.profile_photo_path === null
    && borrower.first_name === "Anonymized"
    && borrower.middle_name === null
    && borrower.last_name === "User"
    && borrower.email === ""
    && borrower.department === null
    && borrower.course === null
    && borrower.gender === null
    && borrower.profile_photo_path === null;

  const photoPaths = [...new Set([targetProfile.profile_photo_path, borrower.profile_photo_path].filter(Boolean))];
  if (photoPaths.some((path) => !path.startsWith(`${targetId}/`))) {
    return errorResponse("The account has an invalid profile photo path; no data was changed.", 409);
  }

  const { data: auditRow, error: auditError } = await adminClient
    .from("phase7_audit_log")
    .insert({
      actor_id: authData.user.id,
      source: "direct_sql",
      event_type: "account_permanently_deleted",
      entity_type: "profile",
      entity_id: targetId,
      filters: { borrowing_and_audit_history_retained: true },
      success: false,
    })
    .select("audit_id")
    .single();
  if (auditError) {
    return errorResponse("The deletion audit could not be recorded; no account data was changed.", 503);
  }

  if (photoPaths.length) {
    const { error: photoError } = await adminClient.storage.from("profile-photos").remove(photoPaths);
    if (photoError) {
      return errorResponse("The profile photo could not be removed; the account was not deleted.", 503);
    }
  }

  if (!alreadyAnonymized) {
    const { data: anonymizedPhotoPath, error: anonymizeError } = await callerClient.rpc(
      "admin_anonymize_inactive_borrower",
      { p_user_id: targetId },
    );
    if (anonymizeError) {
      console.error("Borrower account anonymization failed:", anonymizeError);
      return errorResponse("Personal data could not be anonymized, so the account was not deleted.", 409);
    }
    if (anonymizedPhotoPath && !photoPaths.includes(anonymizedPhotoPath)) {
      if (!anonymizedPhotoPath.startsWith(`${targetId}/`)) {
        return errorResponse("The anonymization returned an invalid photo path; the account remains inactive.", 409);
      }
      const { error: cleanupError } = await adminClient.storage
        .from("profile-photos")
        .remove([anonymizedPhotoPath]);
      if (cleanupError) {
        return errorResponse("Personal data was anonymized, but its profile photo could not be removed; the account remains inactive.", 503);
      }
    }
  }

  const { error: deleteError } = await adminClient.auth.admin.deleteUser(targetId);
  if (deleteError) {
    return errorResponse("Personal data was anonymized, but the login could not be permanently deleted. The account remains inactive.", 503);
  }

  const { error: auditUpdateError } = await adminClient
    .from("phase7_audit_log")
    .update({ success: true })
    .eq("audit_id", auditRow.audit_id);
  return NextResponse.json({
    deleted: true,
    warning: auditUpdateError
      ? "The account was deleted, but the deletion audit could not be marked complete."
      : null,
  });
}
