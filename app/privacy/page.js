import Link from "next/link";

export const metadata = { title: "Privacy notice draft | RMMC-MI Equipment" };

export default function PrivacyNoticePage() {
  return (
    <main className="profile-guard privacy-notice">
      <div>
        <p className="eyebrow">Account information</p>
        <h1>Privacy notice draft</h1>
        <p className="privacy-placeholder">PLACEHOLDER TEXT, NOT LEGAL WORDING. Your school must replace and approve this notice, retention schedule, and contact information before production use.</p>

        <h2>Information collected</h2>
        <p>The system stores your name, institutional email, department, course, gender (if provided), profile-photo path, account and consent status, equipment requests, borrowing and return details, notifications, and audit events.</p>

        <h2>Why it is used</h2>
        <p>This information supports account access, equipment requests and approvals, inventory and return tracking, account security, notifications, and operational auditing.</p>

        <h2>Who can see it</h2>
        <p>You can see information associated with your own account. Administrators and property custodians can access account and equipment records needed for their duties; staff can access borrower and transaction details needed to manage requests. Supabase provides the database, authentication, and file storage services configured for this project.</p>

        <h2>How long it is kept</h2>
        <p>PLACEHOLDER RETENTION SCHEDULE: read notifications are automatically deleted after 90 days. Account, borrowing, and audit records do not currently have an automatic deletion schedule; the school must define and publish their retention periods.</p>

        <h2>Questions or deletion requests</h2>
        <p>Contact your school’s designated privacy officer or system administrator at the contact address the school adds here. An approved anonymization request clears profile and borrower personal fields and the stored photo path; borrowing and audit history remains. The administrator removes the photo file separately through storage.</p>

        <Link className="button-secondary" href="/">Back to sign in</Link>
      </div>
    </main>
  );
}