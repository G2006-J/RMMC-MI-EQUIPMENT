"use client";

import {
  Activity,
  ArrowLeftRight,
  ArrowUpRight,
  Bell,
  CalendarDays,
  Check,
  CheckCircle2,
  ClipboardList,
  Clock3,
  Download,
  FileBarChart,
  Filter,
  HardDrive,
  Laptop,
  LogOut,
  Menu,
  MessageSquare,
  Package,
  Plus,
  Search,
  Send,
  Settings,
  ShieldCheck,
  Pencil,
  Trash2,
  UserRound,
  UsersRound,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createClient as createAuthClient } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";
import InstallAppButton from "./install-app-button";

const MEMBER_NAV_ITEMS = [
  { id: "equipment", label: "Equipment", icon: Package },
  { id: "loans", label: "My equipment", icon: ArrowLeftRight },
  { id: "feedback", label: "Feedback", icon: MessageSquare },
  { id: "account", label: "Account settings", icon: Settings },
];

const ADMIN_NAV_ITEMS = [
  { id: "overview", label: "Overview", icon: Activity },
  { id: "equipment", label: "Equipment", icon: Package },
  { id: "currently-borrowed", label: "Equipment tracking", icon: ArrowLeftRight },
  { id: "reports", label: "Reports", icon: FileBarChart },
  { id: "feedback", label: "Feedback", icon: MessageSquare },
  { id: "account", label: "Account settings", icon: Settings },
];

const CUSTODIAN_NAV_ITEMS = [
  { id: "overview", label: "Overview", icon: Activity },
  { id: "equipment", label: "Equipment", icon: Package },
  { id: "currently-borrowed", label: "Equipment tracking", icon: ArrowLeftRight },
  { id: "requests", label: "Requests", icon: ClipboardList },
  { id: "feedback", label: "Feedback", icon: MessageSquare },
  { id: "account", label: "Account settings", icon: Settings },
];

const ADMIN_ITEMS = [
  { id: "requests", label: "Manage requests", icon: ClipboardList },
  { id: "members", label: "Members & roles", icon: UsersRound },
];

const ACTIVE_BORROWING = ["pending", "approved", "checked_out", "return_requested"];

const dateLabel = (value) =>
  value
    ? new Intl.DateTimeFormat("en", { dateStyle: "medium" }).format(new Date(value.length === 10 ? `${value}T00:00:00` : value))
    : "—";

const dateTimeLabel = (value) =>
  value
    ? new Intl.DateTimeFormat("en", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
    : "—";

async function encodeImageToWebp(file, label, maxDimension) {
  if (!(file instanceof File) || file.size === 0) return null;
  if (!new Set(["image/jpeg", "image/png", "image/webp"]).has(file.type)) {
    throw new Error(`Choose a JPEG, PNG, or WebP ${label}.`);
  }
  if (file.size > 5 * 1024 * 1024) throw new Error(`${label} images must be 5 MB or smaller.`);

  let bitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    throw new Error(`The selected ${label} is not a valid image.`);
  }
  if (!bitmap.width || !bitmap.height || bitmap.width * bitmap.height > 20_000_000) {
    bitmap.close();
    throw new Error(`Choose an image with 20 megapixels or fewer.`);
  }

  const scale = Math.min(1, maxDimension / bitmap.width, maxDimension / bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  const context = canvas.getContext("2d");
  if (!context) {
    bitmap.close();
    throw new Error(`The selected ${label} could not be processed.`);
  }
  context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  const encodedImage = await new Promise((resolve) => canvas.toBlob(resolve, "image/webp", 0.9));
  if (!encodedImage || encodedImage.size > 5 * 1024 * 1024) {
    throw new Error(`The processed ${label} is too large to upload.`);
  }
  return encodedImage;
}

function ProfileAvatar({ name, photoUrl, className = "avatar" }) {
  return (
    <span className={className}>
      {photoUrl ? <img src={photoUrl} alt={`${name}'s profile`} /> : <UserRound size={18} aria-hidden="true" />}
    </span>
  );
}

const getErrorMessage = (error) => {
  const message = error?.message || "Something went wrong. Please try again.";
  if (/email rate limit exceeded|too many requests/i.test(message)) {
    return "Supabase has temporarily limited email delivery. Wait before requesting another email. If this continues, ask your administrator to configure SMTP in Supabase Auth settings.";
  }
  if (/error sending confirmation email|error sending.*email/i.test(message)) {
    return "Supabase could not send the confirmation email. Check Authentication → Email → SMTP Settings and the email provider's delivery logs, then try again later.";
  }
  return message;
};

function StatusPill({ value }) {
  const labels = {
    available: "Available",
    out_of_stock: "Out of stock",
    reserved: "Reserved",
    maintenance: "Maintenance",
    retired: "Retired",
    pending: "Pending review",
    approved: "Approved",
    borrowed: "Borrowed",
    checked_out: "On loan",
    return_requested: "Return requested",
    returned: "Returned",
    overdue: "Overdue",
    unavailable: "Unavailable",
    rejected: "Declined",
    cancelled: "Cancelled",
    fulfilled: "Fulfilled",
  };
  return <span className={`pill pill-${value}`}>{labels[value] || value?.replaceAll("_", " ")}</span>;
}

function SignIn({ supabase, configError }) {
  const [mode, setMode] = useState("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [token, setToken] = useState("");
  const [passwordVerified, setPasswordVerified] = useState(false);
  const [isCodeSent, setIsCodeSent] = useState(false);
  const [otpCooldown, setOtpCooldown] = useState(0);
  const [name, setName] = useState("");
  const [department, setDepartment] = useState("");
  const [course, setCourse] = useState("");
  const [gender, setGender] = useState("");
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (otpCooldown <= 0) return undefined;
    const timer = window.setTimeout(() => setOtpCooldown((remaining) => remaining - 1), 1000);
    return () => window.clearTimeout(timer);
  }, [otpCooldown]);

  async function handleSendOtp() {
    if (otpCooldown > 0) throw new Error(`Please wait ${otpCooldown} seconds before requesting another code.`);
    const { error: otpError } = await supabase.auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      options: { shouldCreateUser: false },
    });

    if (otpError) throw otpError;
    setOtpCooldown(60);
    setIsCodeSent(true);
    setNotice(`A one-time code was sent to ${email}.`);
  }

  async function handleVerifyOtp() {
    const { error: otpError } = await supabase.auth.verifyOtp({
      email: email.trim().toLowerCase(),
      token,
      type: mode === "signup" ? "signup" : "email",
    });

    if (otpError) throw otpError;
  }

  async function handleResendCode() {
    if (mode === "signup") {
      const { error: resendError } = await supabase.auth.resend({
        type: "signup",
        email: email.trim().toLowerCase(),
      });

      if (resendError) throw resendError;
      setOtpCooldown(60);
      setNotice(`A verification code was sent to ${email}.`);
      return;
    }

    await handleSendOtp();
  }

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setNotice("");

    try {
      if (!supabase) throw new Error(configError);
      if (mode === "signin") {
        if (isCodeSent) {
          await handleVerifyOtp();
        } else {
          const validationClient = createAuthClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL,
            process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
            { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } },
          );
          const { error: passwordError } = await validationClient.auth.signInWithPassword({
            email: email.trim().toLowerCase(),
            password,
          });
          if (passwordError) throw passwordError;
          const { error: signOutError } = await validationClient.auth.signOut({ scope: "local" });
          if (signOutError) throw signOutError;
          setPasswordVerified(true);
          const { error: otpError } = await supabase.auth.signInWithOtp({
            email: email.trim().toLowerCase(),
            options: { shouldCreateUser: false },
          });
          if (otpError) throw otpError;
          setOtpCooldown(60);
          setIsCodeSent(true);
          setNotice(`Password confirmed. A one-time verification code was sent to ${email}.`);
          setPassword("");
        }
      } else if (mode === "signup") {
        if (isCodeSent) {
          await handleVerifyOtp();
        } else {
          if (password.length < 8) throw new Error("Passwords must contain at least 8 characters.");
          const { data: signupData, error: signUpError } = await supabase.auth.signUp({
            email: email.trim().toLowerCase(),
            password,
            options: { data: {
              display_name: name.trim(),
              department: department.trim(),
              course: course.trim(),
              gender: gender.trim(),
            } },
          });
          if (signUpError) throw signUpError;
          if (signupData.session || signupData.user?.email_confirmed_at) {
            const { error: signOutError } = await supabase.auth.signOut();
            if (signOutError) throw signOutError;
            throw new Error("Email confirmation is disabled in Supabase Auth. Enable it before allowing new accounts.");
          }
          setIsCodeSent(true);
          setNotice(`A verification code was sent to ${email}.`);
        }
      } else if (mode === "reset") {
        const { error: resetError } = await supabase.auth.resetPasswordForEmail(email.trim().toLowerCase(), {
          redirectTo: window.location.origin,
        });
        if (resetError) throw resetError;
        setNotice("If an account exists for that address, a password reset link is on its way.");
      }
    } catch (submissionError) {
      const message = getErrorMessage(submissionError);
      setError(mode === "signin"
        ? `${isCodeSent ? "Invalid or expired code" : passwordVerified ? "Error sending code" : "Sign-in failed"}: ${message}`
        : mode === "signup" && isCodeSent
          ? `Invalid or expired code: ${message}`
          : message);
    } finally {
      setBusy(false);
    }
  }

  async function resendOtp() {
    setBusy(true);
    setError("");
    setNotice("");

    try {
      if (!supabase) throw new Error(configError);
      await handleResendCode();
    } catch (submissionError) {
      setError(`Error sending code: ${getErrorMessage(submissionError)}`);
    } finally {
      setBusy(false);
    }
  }

  function changeMode(nextMode) {
    setMode(nextMode);
    setIsCodeSent(false);
    setOtpCooldown(0);
    setToken("");
    setPasswordVerified(false);
    setError("");
    setNotice("");
  }

  return (
    <main className="auth-page">
      <section className="auth-showcase">
        <a className="auth-brand" href="/" aria-label="RMMC-MI equipment home">
          <span className="brand-mark"><HardDrive size={21} /></span>
          <span>RMMC <b>·</b> MI</span>
        </a>
        <div className="showcase-copy">
          <p className="eyebrow">Equipment, accounted for</p>
          <h1>Better care for the tools that move us forward.</h1>
          <p>One dependable place to find equipment, request what you need, and keep every return on track.</p>
          <div className="showcase-stats">
            <div><strong>01</strong><span>Browse available gear</span></div>
            <div><strong>02</strong><span>Request in a few clicks</span></div>
            <div><strong>03</strong><span>Keep your team moving</span></div>
          </div>
        </div>
        <p className="auth-copyright">RMMC-MI EQUIPMENT SERVICES · SECURE ACCESS</p>
        <div className="showcase-orbit" />
      </section>
      <section className="auth-form-side">
        <div className="auth-mobile-brand">
          <span className="brand-mark"><HardDrive size={20} /></span>
          <span>RMMC <b>·</b> MI</span>
        </div>
        <div className="auth-card">
          <div className="auth-heading">
            <p className="eyebrow">{mode === "signup" ? isCodeSent ? "Verify your email" : "Get started" : mode === "reset" ? "Account recovery" : isCodeSent ? "Check your inbox" : "Welcome back"}</p>
            <h2>{mode === "signup" ? isCodeSent ? "Enter your verification code" : "Create your account" : mode === "reset" ? "Reset your password" : isCodeSent ? "Enter your sign-in code" : "Sign in to your workspace"}</h2>
            <p>{mode === "signup" ? isCodeSent ? `Enter the verification code sent to ${email}.` : "Use your institutional email to request access." : mode === "reset" ? "We’ll email you a secure password reset link." : isCodeSent ? `Enter the verification code sent to ${email} after your password was confirmed.` : "Enter your institutional email and password. We’ll send a verification code after your credentials are confirmed."}</p>
          </div>
          <form className="auth-form" onSubmit={submit}>
            {mode === "signup" && !isCodeSent && (
              <label>
                <span>Full name</span>
                <input autoComplete="name" value={name} onChange={(event) => setName(event.target.value)} placeholder="Your name" maxLength={120} required />
              </label>
            )}
            <label>
              <span>Institutional email</span>
              <input type="email" autoComplete="email" autoCapitalize="none" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="you@rmmc.edu.ph" disabled={isCodeSent && (mode === "signin" || mode === "signup")} required />
            </label>
            {mode === "signin" && !isCodeSent && (
              <label>
                <span>Password</span>
                <input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} required />
              </label>
            )}
            {(mode === "signin" || mode === "signup") && isCodeSent && (
              <label>
                <span>{mode === "signup" ? "Verification code" : "One-time code"}</span>
                <input type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} value={token} onChange={(event) => setToken(event.target.value.replace(/\D/g, "").slice(0, 6))} placeholder="Enter your 6-digit code" required />
              </label>
            )}
            {mode === "signup" && !isCodeSent && (
              <>
                <div className="form-row">
                  <label>
                    <span>Department</span>
                    <input value={department} onChange={(event) => setDepartment(event.target.value)} placeholder="e.g. IT" maxLength={120} required />
                  </label>
                  <label>
                    <span>Course</span>
                    <input value={course} onChange={(event) => setCourse(event.target.value)} placeholder="e.g. BSIT" maxLength={120} required />
                  </label>
                </div>
                <label>
                  <span>Gender</span>
                  <select className="auth-gender-select" value={gender} onChange={(event) => setGender(event.target.value)} required>
                    <option value="">Select gender</option>
                    <option value="Female">Female</option>
                    <option value="Male">Male</option>
                    <option value="Non-binary">Non-binary</option>
                    <option value="Prefer not to say">Prefer not to say</option>
                    <option value="Other">Other</option>
                  </select>
                </label>
                <label>
                  <span>Password</span>
                  <input type="password" autoComplete="new-password" minLength={8} maxLength={128} value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Use at least 8 characters" required />
                </label>
              </>
            )}
            {error && <p className="feedback feedback-error" role="alert">{error}</p>}
            {notice && <p className="feedback feedback-success" role="status">{notice}</p>}
            {configError && <p className="setup-hint">Add your Supabase URL and publishable key in <code>.env.local</code>, then restart the dev server.</p>}
            {mode === "signin" && (
              <div className="auth-options">
                <span>Protected by Supabase authentication</span>
                {isCodeSent
                  ? <button type="button" onClick={resendOtp} disabled={busy || otpCooldown > 0}>{otpCooldown > 0 ? `Resend in ${otpCooldown}s` : "Resend code"}</button>
                  : <button type="button" onClick={() => changeMode("reset")}>Forgot password?</button>}
              </div>
            )}
            {mode === "signup" && isCodeSent && (
              <div className="auth-options">
                <span>Check your inbox for the verification code.</span>
                <button type="button" onClick={resendOtp} disabled={busy || otpCooldown > 0}>{otpCooldown > 0 ? `Resend in ${otpCooldown}s` : "Resend code"}</button>
              </div>
            )}
            <button className="auth-submit" disabled={busy || Boolean(configError)} type="submit">
              {busy ? "Please wait…" : mode === "signup" ? isCodeSent ? "Verify code" : "Create account" : mode === "reset" ? "Send reset link" : isCodeSent ? "Verify code" : "Continue securely"}
              <ArrowUpRight size={16} />
            </button>
          </form>
          <p className="auth-switch">
            {mode === "signin" && isCodeSent
              ? <button type="button" onClick={() => { setIsCodeSent(false); setPasswordVerified(false); setToken(""); setError(""); setNotice(""); }}>Use a different email</button>
              : mode === "reset"
                ? <button type="button" onClick={() => changeMode("signin")}>Back to sign in</button>
                : <>
                  {mode === "signin" ? "New to the system?" : "Already have an account?"}
                  <button type="button" onClick={() => changeMode(mode === "signin" ? "signup" : "signin")}>
                    {mode === "signin" ? "Request access" : "Sign in"}
                  </button>
                </>}
          </p>
          <p className="auth-terms">Use of this system is subject to your institution’s equipment policies.</p>
          <InstallAppButton />
        </div>
      </section>
    </main>
  );
}

function EmptyState({ title, copy, action, onAction }) {
  return (
    <div className="empty-panel">
      <span><Package size={21} /></span>
      <h2>{title}</h2>
      <p>{copy}</p>
      {action && <button className="button-primary" onClick={onAction}>{action}</button>}
    </div>
  );
}

function EquipmentCard({ item, onBorrow, onReserve, canRequest = true }) {
  const canBorrow = ["available", "checked_out"].includes(item.status) && item.available_quantity > 0;
  const canReserve = ["available", "checked_out"].includes(item.status) && item.quantity > 0;
  return (
    <article className="equipment-card">
      <div className={`equipment-art art-${(item.category || "general").toLowerCase().replace(/[^a-z0-9]+/g, "-")}`}>
        {item.image_url ? <img src={item.image_url} alt="" /> : <Laptop size={42} strokeWidth={1.2} />}
        <StatusPill value={item.quantity === 0 || item.available_quantity === 0 ? "out_of_stock" : item.status} />
      </div>
      <div className="card-body">
        <div className="card-category">{item.category || "General"}</div>
        <h2>{item.name}</h2>
        <div className="item-meta">
          <span>{item.asset_tag}</span><i /><span>{item.location || "Storage not set"}</span>
        </div>
        <p className="item-quantity">Available amount: <strong>{item.available_quantity ?? "—"} / {item.quantity}</strong></p>
        {item.description && <p className="item-description">{item.description}</p>}
        {canRequest && <div className="card-actions">
          <button className="button-primary" disabled={!canBorrow} onClick={() => onBorrow(item)}>
            {canBorrow ? "Request to borrow" : item.available_quantity === null ? "Availability unavailable" : item.quantity === 0 || item.available_quantity === 0 ? "Out of stock" : item.status === "maintenance" ? "Under maintenance" : "Unavailable"}
          </button>
          {canReserve && <button className="button-icon" aria-label={`Reserve ${item.name}`} title="Reserve" onClick={() => onReserve(item)}><CalendarDays size={17} /></button>}
        </div>}
      </div>
    </article>
  );
}

export default function Home() {
  const [supabase, setSupabase] = useState(null);
  const [configError, setConfigError] = useState("");
  const [user, setUser] = useState(null);
  const [profile, setProfile] = useState(null);
  const [equipment, setEquipment] = useState([]);
  const [categoryOptions, setCategoryOptions] = useState([]);
  const [borrowings, setBorrowings] = useState([]);
  const [currentlyBorrowed, setCurrentlyBorrowed] = useState([]);
  const [reservations, setReservations] = useState([]);
  const [members, setMembers] = useState([]);
  const [equipmentAudit, setEquipmentAudit] = useState([]);
  const [feedbackThreads, setFeedbackThreads] = useState([]);
  const [borrowerId, setBorrowerId] = useState(null);
  const [recoveryMode, setRecoveryMode] = useState(false);
  const [view, setView] = useState("overview");
  const [search, setSearch] = useState("");
  const [searchShortcut, setSearchShortcut] = useState("Ctrl K");
  const searchInputRef = useRef(null);
  const [category, setCategory] = useState("All equipment");
  const [modal, setModal] = useState(null);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [mobileNav, setMobileNav] = useState(false);
  const [profileMenuOpen, setProfileMenuOpen] = useState(false);

  useEffect(() => {
    try {
      setSupabase(createClient());
    } catch (clientError) {
      setConfigError(getErrorMessage(clientError));
      setLoading(false);
    }
  }, []);

  const loadData = useCallback(async (client, currentUser) => {
    if (!client || !currentUser) return;
    setLoading(true);
    setError("");

    const profileResult = await client.from("profiles").select("*").eq("id", currentUser.id).maybeSingle();
    if (profileResult.error || !profileResult.data) {
      setProfile(null);
      setEquipment([]);
      setCategoryOptions([]);
      setBorrowings([]);
      setCurrentlyBorrowed([]);
      setReservations([]);
      setMembers([]);
      setEquipmentAudit([]);
      setFeedbackThreads([]);
      setBorrowerId(null);
      setError(profileResult.error
        ? `Your profile role could not be loaded: ${profileResult.error.message}`
        : "No profile was found for the signed-in account.");
      setLoading(false);
      return;
    }

    const currentProfile = {
      ...profileResult.data,
      display_name: profileResult.data.display_name || profileResult.data.full_name || "",
      department: profileResult.data.department || "",
    };
    const isAdminUser = currentProfile.role === "admin";
    const isCustodianUser = currentProfile.role === "property_custodian";
    const isEquipmentManager = isAdminUser || isCustodianUser;
    setProfile(currentProfile);

    const borrowingQuery = client.from("borrowings")
      .select("*, borrowers(borrower_id, first_name, middle_name, last_name, email, department), borrowing_items(*, equipment(equipment_id, asset_code, equipment_name, category_id, storage_location, availability_status, categories(category_name)))")
      .order("created_at", { ascending: false });
    const scopedBorrowingQuery = isCustodianUser
      ? borrowingQuery.in("transaction_status", ["pending", "approved", "borrowed"])
      : borrowingQuery;
    const reservationQuery = client.from("reservations")
      .select("*, equipment(equipment_id, asset_code, equipment_name, categories(category_name)), borrowers(borrower_id, first_name, middle_name, last_name, email)")
      .order("created_at", { ascending: false });
    const scopedReservationQuery = isCustodianUser
      ? reservationQuery.eq("status", "pending")
      : reservationQuery;

    const [equipmentResult, categoryResult, borrowingResult, availableQuantitiesResult, borrowerResult, reservationResult, feedbackResult, repliesResult, currentlyBorrowedResult] = await Promise.all([
      client.from("equipment").select("*, categories(category_name)").is("deleted_at", null).order("equipment_name"),
      client.from("categories").select("category_id, category_name").order("category_name"),
      scopedBorrowingQuery,
      client.rpc("equipment_available_quantities"),
      isCustodianUser ? Promise.resolve({ data: null, error: null }) : client.rpc("current_borrower_id"),
      scopedReservationQuery,
      client.from("feedback_threads").select("*").order("updated_at", { ascending: false }),
      client.from("feedback_replies").select("*").order("created_at"),
      isEquipmentManager
        ? client.rpc("list_equipment_tracking_records")
        : Promise.resolve({ data: [], error: null }),
    ]);

    const errors = [];
    if (currentlyBorrowedResult.error) {
      errors.push(`Equipment tracking records could not be loaded: ${currentlyBorrowedResult.error.message}`);
      setCurrentlyBorrowed([]);
    }
    const trackingRows = isEquipmentManager && !currentlyBorrowedResult.error
      ? currentlyBorrowedResult.data || []
      : [];
    const photoPaths = [...new Set([
      currentProfile.profile_photo_path,
      ...trackingRows.map((item) => item.profile_photo_path),
    ].filter(Boolean))];
    let signedPhotosByPath = new Map();
    if (photoPaths.length) {
      const signedPhotosResult = await client.storage.from("profile-photos").createSignedUrls(photoPaths, 3600);
      if (signedPhotosResult.error) {
        errors.push(`Profile photos could not be loaded: ${signedPhotosResult.error.message}`);
      } else {
        signedPhotosByPath = new Map((signedPhotosResult.data || [])
          .filter((item) => item.signedUrl)
          .map((item) => [item.path, item.signedUrl]));
      }
    }
    setProfile({
      ...currentProfile,
      profile_photo_url: signedPhotosByPath.get(currentProfile.profile_photo_path) || null,
    });
    setCurrentlyBorrowed(trackingRows.map((item) => ({
      ...item,
      profile_photo_url: signedPhotosByPath.get(item.profile_photo_path) || null,
    })));
    if (equipmentResult.error) {
      errors.push(`Equipment could not be loaded: ${equipmentResult.error.message}`);
    } else {
      if (availableQuantitiesResult.error) {
        errors.push(`Available equipment amounts could not be loaded: ${availableQuantitiesResult.error.message}`);
      }
      const availableQuantities = new Map(
        (availableQuantitiesResult.data || []).map((item) => [item.equipment_id, item.available_quantity]),
      );
      setEquipment((equipmentResult.data || []).map((item) => ({
        ...item,
        id: item.equipment_id,
        name: item.equipment_name,
        asset_tag: item.asset_code,
        category: item.categories?.category_name || "General",
        location: item.storage_location || "",
        status: item.availability_status === "borrowed" ? "checked_out" : item.availability_status,
        image_url: item.image_url || null,
        quantity: item.quantity ?? 1,
        available_quantity: availableQuantitiesResult.error
          ? null
          : availableQuantities.get(item.equipment_id) ?? null,
      })));
    }
    if (categoryResult.error) errors.push(`Equipment categories could not be loaded: ${categoryResult.error.message}`);
    else setCategoryOptions(categoryResult.data || []);
    if (!isCustodianUser && borrowerResult.error) {
      setBorrowerId(null);
      errors.push(`Your borrower record could not be found: ${borrowerResult.error.message}`);
    } else if (!isCustodianUser) {
      setBorrowerId(borrowerResult.data || null);
      if (!borrowerResult.data) errors.push(`No active borrower record matches ${currentUser.email || "your signed-in email"}. An administrator must add your account to the borrowers table before you can submit or view borrowing requests.`);
    } else {
      setBorrowerId(null);
    }
    if (borrowingResult.error) {
      errors.push(`Borrowing records could not be loaded: ${borrowingResult.error.message}`);
    } else {
      const returnRequestsResult = await client.from("return_requests").select("borrowing_id, status");
      if (returnRequestsResult.error) errors.push(`Return requests could not be loaded: ${returnRequestsResult.error.message}`);
      const openReturnIds = new Set((returnRequestsResult.data || []).filter((item) => item.status === "pending").map((item) => item.borrowing_id));
      setBorrowings((borrowingResult.data || []).map((item) => {
        const borrower = item.borrowers;
        const firstItem = item.borrowing_items?.[0];
        const equipmentItem = firstItem?.equipment;
        const equipmentNames = (item.borrowing_items || []).map((borrowingItem) => borrowingItem.equipment?.equipment_name).filter(Boolean);
        const assetCodes = (item.borrowing_items || []).map((borrowingItem) => borrowingItem.equipment?.asset_code).filter(Boolean);
        const status = openReturnIds.has(item.borrowing_id)
          ? "return_requested"
          : item.transaction_status === "borrowed"
            ? "checked_out"
            : item.transaction_status;
        return {
          ...item,
          id: item.borrowing_id,
          borrower_name: [borrower?.first_name, borrower?.middle_name, borrower?.last_name].filter(Boolean).join(" ") || "Borrower",
          borrower_email: borrower?.email || "",
          purpose: item.purpose,
          location_of_use: item.destination,
          start_date: item.request_date,
          expected_return: item.expected_return_date,
          status,
          equipment_id: equipmentItem?.equipment_id,
          equipment: equipmentItem ? {
            id: equipmentItem.equipment_id,
            name: equipmentNames.join(", "),
            asset_tag: assetCodes.join(", "),
            category: equipmentItem.categories?.category_name || "General",
          } : null,
          equipment_items: (item.borrowing_items || []).map((borrowingItem) => borrowingItem.equipment?.equipment_name).filter(Boolean),
          quantity: (item.borrowing_items || []).reduce((total, borrowingItem) => total + Number(borrowingItem.quantity || 1), 0),
        };
      }));
    }
    if (reservationResult.error) errors.push(`Reservations could not be loaded: ${reservationResult.error.message}`);
    else setReservations((reservationResult.data || []).map((item) => ({
      ...item,
      id: item.reservation_id,
      requester_id: item.requested_by,
      requester_name: [item.borrowers?.first_name, item.borrowers?.middle_name, item.borrowers?.last_name].filter(Boolean).join(" "),
      requester_email: item.borrowers?.email || "",
      start_date: item.start_date,
      end_date: item.end_date,
      location_of_use: item.destination,
      equipment: item.equipment ? {
        id: item.equipment.equipment_id,
        asset_tag: item.equipment.asset_code,
        name: item.equipment.equipment_name,
        category: item.equipment.categories?.category_name || "General",
      } : null,
      quantity: item.quantity || 1,
    })));
    if (feedbackResult.error) {
      errors.push(`Feedback discussions could not be loaded: ${feedbackResult.error.message}`);
    } else if (repliesResult.error) {
      errors.push(`Feedback replies could not be loaded: ${repliesResult.error.message}`);
    } else {
      const repliesByThread = (repliesResult.data || []).reduce((all, reply) => {
        all[reply.thread_id] = [...(all[reply.thread_id] || []), reply];
        return all;
      }, {});
      setFeedbackThreads((feedbackResult.data || []).map((thread) => ({
        ...thread,
        replies: repliesByThread[thread.id] || [],
      })));
    }
    if (isAdminUser) {
      const memberResult = await client.from("profiles").select("*").order("full_name");
      if (memberResult.error) errors.push(`Member management could not be loaded: ${memberResult.error.message}`);
      else setMembers((memberResult.data || []).map((member) => ({
        ...member,
        display_name: member.display_name || member.full_name || "",
        department: member.department || "",
      })));
    } else {
      setMembers([]);
    }
    if (isEquipmentManager) {
      const auditResult = await client.from("equipment_audit_log").select("*").order("changed_at", { ascending: false }).limit(30);
      if (auditResult.error) errors.push(`Equipment change history could not be loaded: ${auditResult.error.message}`);
      else setEquipmentAudit((auditResult.data || []).map((entry) => ({
        ...entry,
        id: entry.id,
        equipment_id: entry.equipment_id,
        asset_tag: entry.asset_code || `Equipment #${entry.equipment_id}`,
      })));
    } else {
      setEquipmentAudit([]);
    }
    if (errors.length) setError(`${errors.join(" ")} Check that the Supabase schema migrations in supabase/migrations have been applied in order.`);
    setLoading(false);
  }, []);

  useEffect(() => {
    if (!supabase) return undefined;
    let alive = true;
    supabase.auth.getSession().then(({ data, error: sessionError }) => {
      if (!alive) return;
      if (sessionError) setError(getErrorMessage(sessionError));
      setUser(data.session?.user || null);
      if (data.session?.user) loadData(supabase, data.session.user);
      else setLoading(false);
    });
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === "PASSWORD_RECOVERY") setRecoveryMode(true);
      setUser(session?.user || null);
      if (session?.user) loadData(supabase, session.user);
      else {
        setProfile(null);
        setEquipment([]);
        setBorrowings([]);
        setCurrentlyBorrowed([]);
        setReservations([]);
        setMembers([]);
        setEquipmentAudit([]);
        setFeedbackThreads([]);
        setLoading(false);
      }
    });
    return () => {
      alive = false;
      subscription.unsubscribe();
    };
  }, [supabase, loadData]);

  const isAdmin = profile?.role === "admin";
  const isPropertyCustodian = profile?.role === "property_custodian";
  const isEquipmentManager = isAdmin || isPropertyCustodian;
  const isEquipmentStaff = isAdmin;

  useEffect(() => {
    if (!profile) return;
    const allowedViews = isAdmin
      ? ["overview", "equipment", "currently-borrowed", "reports", "feedback", "requests", "members", "account"]
      : isPropertyCustodian
        ? ["overview", "equipment", "currently-borrowed", "requests", "feedback", "account"]
        : ["equipment", "loans", "feedback", "account"];
    if (!allowedViews.includes(view)) setView(isAdmin || isPropertyCustodian ? "overview" : "equipment");
  }, [profile, isAdmin, isPropertyCustodian, view]);

  useEffect(() => {
    setSearchShortcut(/Mac|iPhone|iPad/i.test(navigator.platform) ? "⌘ K" : "Ctrl K");
    function focusSearch(event) {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        searchInputRef.current?.focus();
      }
    }
    window.addEventListener("keydown", focusSearch);
    return () => window.removeEventListener("keydown", focusSearch);
  }, []);

  const categories = useMemo(
    () => ["All equipment", ...new Set(equipment.map((item) => item.category).filter(Boolean))],
    [equipment],
  );
  const filteredEquipment = useMemo(() => {
    const query = search.trim().toLowerCase();
    return equipment.filter((item) => {
      const matchesCategory = category === "All equipment" || item.category === category;
      const matchesQuery = !query || [item.name, item.asset_tag, item.category, item.location, item.brand, item.model].some((field) => field?.toLowerCase().includes(query));
      return matchesCategory && matchesQuery;
    });
  }, [equipment, category, search]);

  const counts = useMemo(() => {
    const today = new Date().toISOString().slice(0, 10);
    const currentLoans = borrowings.filter((item) => ["approved", "checked_out", "return_requested"].includes(item.status));
    return {
      available: equipment.filter((item) => item.status === "available").length,
      borrowed: currentLoans.length,
      dueSoon: currentLoans.filter((item) => item.expected_return && String(item.expected_return).slice(0, 10) <= today).length,
      pending: borrowings.filter((item) => item.status === "pending").length + reservations.filter((item) => item.status === "pending").length,
    };
  }, [equipment, borrowings, reservations]);

  async function refresh() {
    if (supabase && user) await loadData(supabase, user);
  }

  async function runAction(action, successMessage) {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const result = await action();
      if (result?.error) throw result.error;
      setNotice(successMessage);
      setModal(null);
      await refresh();
      return true;
    } catch (actionError) {
      setError(getErrorMessage(actionError));
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function submitRequest(event) {
    event.preventDefault();
    if (!modal || !supabase || !user) return;
    const form = new FormData(event.currentTarget);
    const common = {
      p_equipment_id: modal.item.id,
      p_purpose: String(form.get("purpose") || "").trim(),
      p_destination: String(form.get("use_location") || "").trim(),
      p_quantity: Number(form.get("amount")),
    };
    if (modal.kind === "reservation") {
      await runAction(() => supabase.rpc("request_equipment_reservation", {
        ...common,
        p_start_date: form.get("start_date"),
        p_end_date: form.get("end_date"),
        p_start_time: form.get("start_time"),
        p_end_time: form.get("end_time"),
      }), "Reservation request submitted.");
    } else {
      const returnAt = new Date(`${form.get("end_date")}T${form.get("end_time")}`);
      if (Number.isNaN(returnAt.getTime())) {
        setError("Choose a valid expected return date and time.");
        return;
      }
      await runAction(() => supabase.rpc("request_equipment_borrowing", {
        ...common,
        p_expected_return_date: returnAt.toISOString(),
      }), "Borrowing request submitted.");
    }
  }

  async function uploadEquipmentImage(form) {
    const file = form.get("image");
    const encodedImage = await encodeImageToWebp(file, "equipment", 4096);
    if (!encodedImage) return null;

    const path = `${user.id}/${crypto.randomUUID()}.webp`;
    const { error: uploadError } = await supabase.storage
      .from("equipment-images")
      .upload(path, new File([encodedImage], "equipment.webp", { type: "image/webp" }), {
        contentType: "image/webp",
        cacheControl: "3600",
      });
    if (uploadError) throw uploadError;
    return supabase.storage.from("equipment-images").getPublicUrl(path).data.publicUrl;
  }

  async function uploadProfilePhoto(file) {
    const encodedImage = await encodeImageToWebp(file, "profile photo", 1024);
    if (!encodedImage) return null;
    const path = `${user.id}/${crypto.randomUUID()}.webp`;
    const { error: uploadError } = await supabase.storage
      .from("profile-photos")
      .upload(path, new File([encodedImage], "profile.webp", { type: "image/webp" }), {
        contentType: "image/webp",
        cacheControl: "3600",
      });
    if (uploadError) throw uploadError;
    return path;
  }

  async function addEquipment(event) {
    event.preventDefault();
    if (!isEquipmentManager || !supabase || !user) return;
    const form = new FormData(event.currentTarget);
    const item = {
      asset_code: String(form.get("asset_tag") || "").trim(),
      equipment_name: String(form.get("name") || "").trim(),
      category_id: Number(form.get("category_id")),
      quantity: Number(form.get("quantity")),
      brand: String(form.get("brand") || "").trim() || null,
      model: String(form.get("model") || "").trim() || null,
      serial_number: String(form.get("serial_number") || "").trim() || null,
      storage_location: String(form.get("location") || "").trim(),
      description: String(form.get("description") || "").trim(),
      availability_status: "available",
      condition_status: "good",
    };
    await runAction(async () => {
      const imageUrl = await uploadEquipmentImage(form);
      const { error: insertError } = await supabase.from("equipment").insert({ ...item, image_url: imageUrl });
      if (insertError) throw insertError;
    }, "Equipment added to inventory.");
  }

  async function updateEquipment(event) {
    event.preventDefault();
    if (!isEquipmentManager || !modal?.item || !supabase || !user) return;
    const form = new FormData(event.currentTarget);
    const item = {
      asset_code: String(form.get("asset_tag") || "").trim(),
      equipment_name: String(form.get("name") || "").trim(),
      category_id: Number(form.get("category_id")),
      quantity: Number(form.get("quantity")),
      brand: String(form.get("brand") || "").trim() || null,
      model: String(form.get("model") || "").trim() || null,
      serial_number: String(form.get("serial_number") || "").trim() || null,
      storage_location: String(form.get("location") || "").trim(),
      description: String(form.get("description") || "").trim(),
      availability_status: String(form.get("status") || "available"),
      condition_status: String(form.get("condition_status") || "good"),
      updated_at: new Date().toISOString(),
    };
    await runAction(async () => {
      const imageUrl = await uploadEquipmentImage(form);
      if (imageUrl) item.image_url = imageUrl;
      else if (form.get("remove_image") === "on") item.image_url = null;
      const { error: updateError } = await supabase.from("equipment").update(item).eq("equipment_id", modal.item.id);
      if (updateError) throw updateError;
    }, "Equipment record updated.");
  }

  async function saveAccount(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const firstName = String(form.get("first_name") || "").trim();
    const lastName = String(form.get("last_name") || "").trim();
    const selectedPhoto = form.get("profile_photo");
    const removePhoto = form.get("remove_profile_photo") === "on";
    await runAction(async () => {
      const { error: profileError } = await supabase.rpc("update_my_account_profile", {
        p_first_name: firstName,
        p_last_name: lastName,
        p_department: String(form.get("department") || "").trim(),
        p_course: String(form.get("course") || "").trim(),
        p_gender: String(form.get("gender") || "").trim(),
      });
      if (profileError) throw profileError;

      const uploadedPath = selectedPhoto instanceof File && selectedPhoto.size
        ? await uploadProfilePhoto(selectedPhoto)
        : null;
      if (uploadedPath || (removePhoto && profile.profile_photo_path)) {
        const newPhotoPath = uploadedPath || null;
        const { error: photoError } = await supabase.rpc("update_my_profile_photo", {
          p_profile_photo_path: newPhotoPath,
        });
        if (photoError) {
          if (uploadedPath) {
            const { error: cleanupError } = await supabase.storage.from("profile-photos").remove([uploadedPath]);
            if (cleanupError) throw new Error(`Profile photo update failed and the uploaded image could not be cleaned up: ${cleanupError.message}`);
          }
          throw photoError;
        }
        if (profile.profile_photo_path && profile.profile_photo_path !== newPhotoPath) {
          const { error: cleanupError } = await supabase.storage.from("profile-photos").remove([profile.profile_photo_path]);
          if (cleanupError) throw new Error(`Profile updated, but the previous photo could not be removed: ${cleanupError.message}`);
        }
      }
    }, "Account settings saved.");
  }

  async function submitFeedback(event) {
    event.preventDefault();
    const feedbackForm = event.currentTarget;
    const form = new FormData(feedbackForm);
    const thread = {
      author_id: user.id,
      author_name: displayName,
      title: String(form.get("title") || "").trim(),
      category: String(form.get("category") || "suggestion"),
      message: String(form.get("message") || "").trim(),
    };
    const posted = await runAction(
      () => supabase.from("feedback_threads").insert(thread),
      "Feedback posted to the discussion board.",
    );
    if (posted) feedbackForm.reset();
  }

  async function replyToFeedback(event, threadId) {
    event.preventDefault();
    const replyForm = event.currentTarget;
    const form = new FormData(replyForm);
    const message = String(form.get("reply") || "").trim();
    if (!message) return;
    const posted = await runAction(
      () => supabase.from("feedback_replies").insert({
        thread_id: threadId,
        author_id: user.id,
        author_name: displayName,
        message,
      }),
      "Reply posted.",
    );
    if (posted) replyForm.reset();
  }

  function downloadReport(reportType) {
    const today = new Date().toISOString().slice(0, 10);
    let rows;
    let suffix;
    if (reportType === "equipment") {
      suffix = "equipment-status";
      rows = [
        ["Equipment", "Asset tag", "Category", "Status", "Storage location", "Current borrower", "Current location of use", "Expected return"],
        ...equipment.map((item) => {
          const activeLoan = borrowings.find((loan) => loan.equipment_id === item.id && ["approved", "checked_out", "return_requested"].includes(loan.status));
          return [item.name, item.asset_tag, item.category, item.status, item.location, activeLoan?.borrower_email || "", activeLoan?.location_of_use || "", activeLoan?.expected_return || ""];
        }),
      ];
    } else {
      const reportRows = reportType === "overdue"
        ? borrowings.filter((item) => ACTIVE_BORROWING.includes(item.status) && String(item.expected_return || "").slice(0, 10) < today)
        : reportType === "returns"
          ? borrowings.filter((item) => item.status === "returned")
          : borrowings;
      suffix = reportType === "overdue" ? "overdue-items" : reportType === "returns" ? "returns" : "borrowing";
      rows = [
        ["Equipment", "Asset tag", "Borrower email", "Purpose", "Location of use", "Start date", "Expected return", "Status"],
        ...reportRows.map((item) => [
          item.equipment?.name || "",
          item.equipment?.asset_tag || "",
          item.borrower_email || item.borrower_id,
          item.purpose || "",
          item.location_of_use || "",
          item.start_date || "",
          item.expected_return || "",
          item.status || "",
        ]),
      ];
    }
    const csv = rows.map((row) => row.map((value) => {
      const text = String(value ?? "");
      let firstVisibleCharacter = 0;
      while (firstVisibleCharacter < text.length) {
        const characterCode = text.charCodeAt(firstVisibleCharacter);
        if (/\s/.test(text[firstVisibleCharacter])
          || characterCode <= 0x1f
          || (characterCode >= 0x7f && characterCode <= 0x9f)
          || characterCode === 0xfeff) {
          firstVisibleCharacter += 1;
        } else {
          break;
        }
      }
      const safeText = /^[=+\-@]/.test(text.slice(firstVisibleCharacter)) ? `'${text}` : text;
      return `"${safeText.replaceAll('"', '""')}"`;
    }).join(",")).join("\r\n");
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    link.download = `rmmc-${suffix}-report-${today}.csv`;
    link.click();
    URL.revokeObjectURL(link.href);
  }

  async function signOut() {
    const { error: signOutError } = await supabase.auth.signOut();
    if (signOutError) setError(getErrorMessage(signOutError));
    else setProfileMenuOpen(false);
  }

  if (!user) return <SignIn supabase={supabase} configError={configError} />;
  if (!user.email_confirmed_at) {
    return (
      <main className="profile-guard" role="alert">
        <div><span className="brand-mark"><ShieldCheck size={21} /></span><h1>Email verification required</h1>
          <p>Confirm your email address before accessing this workspace. Check the Supabase Auth email-confirmation settings.</p>
          <button className="button-secondary" type="button" onClick={signOut}>Sign out</button>
        </div>
      </main>
    );
  }
  if (!profile) {
    return (
      <main className="profile-guard" role={error ? "alert" : "status"}>
        <div><span className="brand-mark"><ShieldCheck size={21} /></span><h1>{error ? "Workspace access unavailable" : "Verifying your access…"}</h1>
          <p>{error || "Your account permissions are being checked securely."}</p>
          {error ? <button className="button-secondary" type="button" onClick={signOut}>Sign out</button> : <LoadingPanel />}
        </div>
      </main>
    );
  }

  const displayName = profile?.display_name || user.user_metadata?.display_name || user.email?.split("@")[0] || "Member";
  const userRole = profile?.role || "unavailable";

  const sectionHeader = {
    overview: ["Good day", displayName, "Here’s what’s happening with your team’s equipment."],
    equipment: ["Equipment library", "Find the right gear", "Browse available equipment or check when an item is due back."],
    loans: ["Your activity", "My equipment", "Track borrowing requests, reservations, due dates, and returns."],
    reports: ["At a glance", "Reports", "Recent database-recorded equipment changes."],
    "currently-borrowed": ["Equipment use", "Equipment tracking", "Current borrowed and reserved equipment, including overdue loans."],
    requests: ["Operations", isPropertyCustodian ? "Borrower requests" : "Manage requests", "Find requests by the borrower's first or last name."],
    members: ["Operations", "Members & roles", "Review account access and keep member permissions up to date."],
    feedback: ["Have a say", "Feedback & ideas", "Share improvements and discuss how the system should grow."],
    account: ["Your profile", "Account settings", "Keep your name and department information up to date."],
  }[view] || ["Workspace", "Equipment", "Manage equipment and requests."];

  const myBorrowings = borrowings.filter((item) => Number(item.borrower_id) === Number(borrowerId));
  const myReservations = reservations.filter((item) => item.requester_id === user.id);
  const visibleNavItems = isAdmin
    ? ADMIN_NAV_ITEMS
    : isPropertyCustodian
      ? CUSTODIAN_NAV_ITEMS
      : MEMBER_NAV_ITEMS;

  return (
    <div className="app-shell">
      {mobileNav && <button className="backdrop" aria-label="Close navigation" onClick={() => setMobileNav(false)} />}
      <aside className={`sidebar ${mobileNav ? "sidebar-open" : ""}`}>
        <a className="brand" href="/" aria-label="RMMC-MI home">
          <span className="brand-mark"><HardDrive size={21} /></span>
          <span>RMMC <i>·</i> MI</span>
        </a>
        <div className="workspace-label">EQUIPMENT SERVICES</div>
        <nav className="main-nav" aria-label="Main navigation">
          <p className="nav-label">Workspace</p>
          {visibleNavItems.map(({ id, label, icon: Icon }) => (
            <button key={id} className={`nav-item ${view === id ? "active" : ""}`} onClick={() => { setView(id); setMobileNav(false); }}>
              <Icon size={18} /><span>{label}</span>
              {id === "loans" && myBorrowings.some((item) => item.status === "pending") && <i className="nav-badge">!</i>}
            </button>
          ))}
          {isAdmin && (
            <>
              <p className="nav-label nav-section">Administration</p>
              {ADMIN_ITEMS.map(({ id, label, icon: Icon }) => (
                <button key={id} className={`nav-item ${view === id ? "active" : ""}`} onClick={() => { setView(id); setMobileNav(false); }}>
                  <Icon size={18} /><span>{label}</span>
                  {id === "requests" && counts.pending > 0 && <i className="nav-badge">{counts.pending}</i>}
                </button>
              ))}
            </>
          )}
        </nav>
        <div className="sidebar-spacer" />
        <div className="help-card">
          <span className="help-icon"><MessageSquare size={15} /></span>
          <strong>Help shape the system</strong>
          <p>Share ideas, report an issue, or discuss what should come next.</p>
          <button type="button" onClick={() => setView("feedback")}>Open feedback <ArrowUpRight size={14} /></button>
        </div>
        <div className="sidebar-user">
          <ProfileAvatar name={displayName} photoUrl={profile.profile_photo_url} />
          <div><strong>{displayName}</strong><span>          {userRole === "admin" ? "Administrator" : userRole === "property_custodian" ? "Property custodian" : userRole === "staff" ? "Staff member" : "Role unavailable"}</span></div>
        </div>
      </aside>

      <main className="content">
        <header className="topbar">
          <button className="menu-button" aria-label="Open navigation" onClick={() => setMobileNav(true)}><Menu size={20} /></button>
          <span className="topbar-context">RMMC-MI <i>/</i> Equipment services</span>
          <div className="top-actions">
            <InstallAppButton />
            <div className="profile-menu-wrap">
              <button className="user-chip profile-menu-trigger" type="button" title={`${displayName} · ${userRole}`} aria-label="Open user account menu" aria-expanded={profileMenuOpen} onClick={() => setProfileMenuOpen((open) => !open)}>
                <ProfileAvatar name={displayName} photoUrl={profile.profile_photo_url} />
                <div><strong>{displayName}</strong><span>{userRole === "admin" ? "Administrator" : userRole === "property_custodian" ? "Property custodian" : "Borrower account"}</span></div>
                <Settings size={15} aria-hidden="true" />
              </button>
              {profileMenuOpen && <div className="profile-menu" role="menu">
                <button type="button" role="menuitem" onClick={() => { setView("account"); setProfileMenuOpen(false); }}><Settings size={15} /> Account settings</button>
                <button type="button" role="menuitem" onClick={signOut}><LogOut size={15} /> Log out</button>
              </div>}
            </div>
          </div>
        </header>

        <div className="page">
          <section className="page-heading">
            <div>
              <p className="eyebrow">{sectionHeader[0]}</p>
              <h1>{sectionHeader[1]}{view === "overview" && <span className="heading-period">.</span>}</h1>
              <p>{sectionHeader[2]}</p>
            </div>
            {view === "equipment" && <div className="availability-note"><span /> <strong>{counts.available}</strong> items available</div>}
            {view === "equipment" && isEquipmentManager && <button className="button-primary" onClick={() => setModal({ kind: "add-equipment" })}><Plus size={17} /> Add equipment</button>}
          </section>

          {(error || notice) && (
            <div className={`banner ${error ? "banner-error" : "banner-success"}`} role={error ? "alert" : "status"}>
              <span>{error ? error : notice}</span>
              {error && <button onClick={() => setError("")} aria-label="Dismiss error"><X size={16} /></button>}
            </div>
          )}

          {view === "overview" && (
            <>
              <section className="welcome-strip">
                <div className="welcome-icon"><ShieldCheck size={21} /></div>
                <div><strong>{isEquipmentManager ? "Your equipment operations workspace" : "Your equipment workspace"}</strong><p>{isEquipmentManager ? "Keep the equipment library accurate and coordinate borrower requests." : "Browse gear, check your requests, and keep every return on schedule."}</p></div>
                <button onClick={() => setView(isEquipmentManager ? "requests" : "equipment")}>{isEquipmentManager ? "Review requests" : "Browse equipment"} <ArrowUpRight size={15} /></button>
                <div className="welcome-decoration" />
              </section>
              {isEquipmentManager ? (
                <>
                  <section className="metric-grid" aria-label="Equipment operations summary">
                    <article className="metric-card"><div className="metric-top"><span>Available now</span><span className="metric-icon metric-green"><Package size={18} /></span></div><strong>{loading ? "—" : counts.available}</strong><small>Equipment ready to request</small></article>
                    <article className="metric-card"><div className="metric-top"><span>Inventory records</span><span className="metric-icon metric-amber"><HardDrive size={18} /></span></div><strong>{loading ? "—" : equipment.length}</strong><small>Active equipment items</small></article>
                    <article className="metric-card"><div className="metric-top"><span>Feedback topics</span><span className="metric-icon metric-blue"><MessageSquare size={18} /></span></div><strong>{loading ? "—" : feedbackThreads.length}</strong><small>Community discussions</small></article>
                    <article className="metric-card"><div className="metric-top"><span>Inventory updates</span><span className="metric-icon metric-rose"><Activity size={18} /></span></div><strong>{loading ? "—" : equipmentAudit.length}</strong><small>Recent recorded changes</small></article>
                  </section>
                  <div className="section-title"><div><h2>Equipment management</h2><p>Review stock and keep the active inventory current.</p></div><button className="text-action" onClick={() => setView("equipment")}>Manage equipment <ArrowUpRight size={15} /></button></div>
                  <div className="section-title"><div><h2>Borrower requests</h2><p>Search borrowing and reservation requests by borrower name.</p></div><button className="text-action" onClick={() => setView("requests")}>Find a borrower <ArrowUpRight size={15} /></button></div>
                  <div className="section-title"><div><h2>Feedback and improvements</h2><p>Discuss issues and track ideas from the equipment community.</p></div><button className="text-action" onClick={() => setView("feedback")}>Open feedback <ArrowUpRight size={15} /></button></div>
                </>
              ) : (
                <>
                  <section className="metric-grid" aria-label="Equipment summary">
                    <article className="metric-card"><div className="metric-top"><span>Available now</span><span className="metric-icon metric-green"><Package size={18} /></span></div><strong>{loading ? "—" : counts.available}</strong><small>Ready to request</small></article>
                    <article className="metric-card"><div className="metric-top"><span>Currently borrowed</span><span className="metric-icon metric-amber"><ArrowLeftRight size={18} /></span></div><strong>{loading ? "—" : counts.borrowed}</strong><small>Approved or checked out</small></article>
                    <article className="metric-card"><div className="metric-top"><span>Due today / overdue</span><span className="metric-icon metric-rose"><Clock3 size={18} /></span></div><strong>{loading ? "—" : counts.dueSoon}</strong><small>Items needing attention</small></article>
                    <article className="metric-card"><div className="metric-top"><span>Requests to review</span><span className="metric-icon metric-blue"><Bell size={18} /></span></div><strong>{loading ? "—" : counts.pending}</strong><small>{isEquipmentStaff ? "Awaiting your review" : "Across your requests"}</small></article>
                  </section>
                  <div className="section-title"><div><h2>Find equipment</h2><p>Browse what’s available for your next project</p></div><button className="text-action" onClick={() => setView("equipment")}>Explore library <ArrowUpRight size={15} /></button></div>
                  <div className="equipment-grid compact-grid">
                    {(equipment.filter((item) => item.status === "available").slice(0, 3)).map((item) => <EquipmentCard key={item.id} item={item} canRequest={false} onBorrow={(selected) => setModal({ kind: "borrow", item: selected })} onReserve={(selected) => setModal({ kind: "reservation", item: selected })} />)}
                    {!loading && equipment.length === 0 && <EmptyState title="Your equipment library is ready" copy="Once equipment is added to the inventory, it will appear here." action={isAdmin ? "Add equipment" : null} onAction={() => setModal({ kind: "add-equipment" })} />}
                  </div>
                </>
              )}
            </>
          )}

          {view === "equipment" && (
            <>
              <div className="toolbar">
                <label className="search-box"><Search size={18} /><input ref={searchInputRef} value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search equipment, tag or location" aria-label="Search equipment" /><kbd>{searchShortcut}</kbd></label>
                <div className="category-tabs" role="group" aria-label="Filter by category">
                  {categories.map((item) => <button key={item} className={category === item ? "selected" : ""} onClick={() => setCategory(item)}>{item}</button>)}
                </div>
                <span className="filter-caption"><Filter size={15} /> {filteredEquipment.length} results</span>
              </div>
              {loading ? <LoadingPanel /> : filteredEquipment.length ? (
                <div className="equipment-grid">
                  {filteredEquipment.map((item) => <EquipmentCard key={item.id} item={item} canRequest={!isEquipmentManager} onBorrow={(selected) => setModal({ kind: "borrow", item: selected })} onReserve={(selected) => setModal({ kind: "reservation", item: selected })} />)}
                </div>
              ) : <EmptyState title={equipment.length ? "No matching equipment" : "No equipment has been added yet"} copy={equipment.length ? "Try another search or category." : "The inventory team can add equipment to make it available here."} action={isEquipmentManager && !equipment.length ? "Add equipment" : null} onAction={() => setModal({ kind: "add-equipment" })} />}
              {isEquipmentManager && (
                <>
                  <div className="section-title"><div><h2>Manage equipment</h2><p>Edit item details or remove retired equipment from the active library.</p></div><span className="record-count">{equipment.length} active items</span></div>
                  <EquipmentTable
                    equipment={equipment}
                    onEdit={(item) => setModal({ kind: "edit-equipment", item })}
                    onDelete={(item) => {
                      if (window.confirm(`Remove ${item.name} (${item.asset_tag}) from the active equipment library? Existing borrowing history will be preserved.`)) {
                        runAction(() => supabase.rpc("delete_equipment", { p_equipment_id: item.id }), "Equipment removed from the active library.");
                      }
                    }}
                  />
                </>
              )}
            </>
          )}

          {view === "currently-borrowed" && isEquipmentManager && (
            <CurrentlyBorrowedWorkspace rows={currentlyBorrowed} categories={categoryOptions} loading={loading} />
          )}

          {view === "loans" && !isEquipmentManager && (
            <>
              <div className="toolbar list-toolbar">
                <div className="list-toolbar-copy"><span className="toolbar-icon"><ClipboardList size={17} /></span><div><strong>My equipment</strong><small>Borrowing requests and reservations tied to your account</small></div></div>
                <span className="record-count">{myBorrowings.length + myReservations.length} records</span>
              </div>
              <BorrowingList rows={myBorrowings} onRequestReturn={(row) => runAction(() => supabase.rpc("request_equipment_return", { p_borrowing_id: row.id }), "Return request submitted.")} loading={loading} />
              <div className="section-title"><div><h2>My reservations</h2><p>Upcoming and past reservation requests</p></div><span className="record-count">{myReservations.length} records</span></div>
              <ReservationList rows={myReservations} loading={loading} />
            </>
          )}

          {view === "requests" && (isEquipmentStaff || isPropertyCustodian) && (
            <AdminRequests
              borrowings={borrowings}
              reservations={reservations}
              busy={busy}
              runAction={runAction}
              supabase={supabase}
              canReview={isAdmin || isPropertyCustodian}
            />
          )}

          {view === "members" && isEquipmentStaff && (
            <>
              <div className="toolbar list-toolbar">
                <div className="list-toolbar-copy"><span className="toolbar-icon"><UsersRound size={17} /></span><div><strong>Workspace members</strong><small>Manage access to equipment operations</small></div></div>
                <span className="record-count">{members.length} accounts</span>
              </div>
              <MemberTable members={members} currentUserId={user.id} runAction={runAction} supabase={supabase} />
            </>
          )}

          {view === "reports" && (
            <>
              {isAdmin && <div className="report-callout">
                <div className="report-icon"><FileBarChart size={21} /></div>
                <div><strong>Download reports</strong><p>Export borrowing, returns, equipment status, or overdue equipment as CSV.</p></div>
                <div className="report-actions">
                  <button className="button-secondary" onClick={() => downloadReport("borrowing")}><Download size={14} /> Borrowing</button>
                  <button className="button-secondary" onClick={() => downloadReport("returns")}><Download size={14} /> Returns</button>
                  <button className="button-secondary" onClick={() => downloadReport("equipment")}><Download size={14} /> Equipment</button>
                  <button className="button-secondary" onClick={() => downloadReport("overdue")}><Download size={14} /> Overdue</button>
                </div>
              </div>}
              <div className="section-title"><div><h2>Equipment change history</h2><p>Database-recorded additions, edits, and removals.</p></div><span className="record-count">{equipmentAudit.length} recent changes</span></div>
              <EquipmentAuditLog entries={equipmentAudit} />
            </>
          )}

          {view === "feedback" && (
            <FeedbackBoard
              threads={feedbackThreads}
              currentUserId={user.id}
              isAdmin={isAdmin}
              canManageFeedback={isEquipmentManager}
              busy={busy}
              onCreate={submitFeedback}
              onReply={replyToFeedback}
              onDeleteReply={(reply) => {
                if (window.confirm(`Permanently delete the comment from ${reply.author_name}?`)) {
                  runAction(
                    () => supabase.from("feedback_replies").delete().eq("id", reply.id),
                    "Comment deleted.",
                  );
                }
              }}
              onStatusChange={(threadId, status) => runAction(
                () => supabase.from("feedback_threads").update({ status }).eq("id", threadId),
                "Feedback status updated.",
              )}
            />
          )}

          {view === "account" && (
            <AccountSettings profile={profile} user={user} busy={busy} onSave={saveAccount} />
          )}

          <footer className="page-footer"><span>RMMC-MI Equipment Services</span><span>Keep equipment safe. Keep projects moving.</span></footer>
        </div>
      </main>

      {modal && (
        <div className="modal-wrap" role="presentation">
          <button className="modal-backdrop" onClick={() => !busy && setModal(null)} aria-label="Close dialog" />
          <section className="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title">
            <button className="modal-close" onClick={() => setModal(null)} aria-label="Close" disabled={busy}><X size={18} /></button>
            {modal.kind === "add-equipment" || modal.kind === "edit-equipment" ? (
              <>
                <div className="modal-kicker">INVENTORY</div>
                <h2 id="modal-title">{modal.kind === "edit-equipment" ? "Edit equipment" : "Add equipment"}</h2>
                <p className="modal-copy">{modal.kind === "edit-equipment" ? "Update this record. Changes are saved to the database audit history." : "Create an equipment record for your team to discover and request."}</p>
                <form className="modal-form" onSubmit={modal.kind === "edit-equipment" ? updateEquipment : addEquipment}>
                  <label><span>Equipment name</span><input name="name" placeholder="e.g. Canon EOS R6" defaultValue={modal.item?.name || ""} required maxLength={160} /></label>
                  <div className="form-row"><label><span>Asset code</span><input name="asset_tag" placeholder="CAM-001" defaultValue={modal.item?.asset_tag || ""} required maxLength={80} /></label><label><span>Category</span><select name="category_id" defaultValue={modal.item?.category_id || ""} required><option value="" disabled>Select a category</option>{categoryOptions.map((option) => <option key={option.category_id} value={option.category_id}>{option.category_name}</option>)}</select></label></div>
                  <label><span>Amount</span><input name="quantity" type="number" min="0" max="10000" step="1" defaultValue={modal.item?.quantity ?? 1} required /></label>
                  <div className="form-row"><label><span>Brand (optional)</span><input name="brand" defaultValue={modal.item?.brand || ""} maxLength={120} /></label><label><span>Model (optional)</span><input name="model" defaultValue={modal.item?.model || ""} maxLength={120} /></label></div>
                  <label><span>Serial number (optional)</span><input name="serial_number" defaultValue={modal.item?.serial_number || ""} maxLength={160} /></label>
                  <label><span>Storage location</span><input name="location" placeholder="Media office · Cabinet 2" defaultValue={modal.item?.location || ""} maxLength={200} /></label>
                  <label><span>Description (optional)</span><textarea name="description" rows="3" placeholder="Condition, accessories, or notes" defaultValue={modal.item?.description || ""} maxLength={1000} /></label>
                  <label><span>Equipment picture</span><input name="image" type="file" accept="image/jpeg,image/png,image/webp" /><small className="field-hint">JPEG, PNG, or WebP; 5 MB maximum, re-encoded before upload.</small></label>
                  {modal.kind === "edit-equipment" && modal.item.image_url && (
                    <div className="equipment-image-preview"><img src={modal.item.image_url} alt={`Current picture of ${modal.item.name}`} /><span>Current picture</span></div>
                  )}
                  {modal.kind === "edit-equipment" && modal.item.image_url && <label className="checkbox-label"><input name="remove_image" type="checkbox" /><span>Remove current picture</span></label>}
                  {modal.kind === "edit-equipment" && <label><span>Condition</span><select name="condition_status" defaultValue={modal.item.condition_status}><option value="good">Good</option><option value="fair">Fair</option><option value="damaged">Damaged</option></select></label>}
                  {modal.kind === "edit-equipment" && <label><span>Availability</span><select name="status" defaultValue={modal.item.availability_status}><option value="available">Available</option><option value="maintenance">Maintenance</option><option value="retired">Retired</option>{["borrowed", "reserved"].includes(modal.item.availability_status) && <option value={modal.item.availability_status}>{modal.item.availability_status === "borrowed" ? "Borrowed" : "Reserved"} (manage through requests)</option>}</select></label>}
                  <div className="modal-actions"><button type="button" className="button-secondary" onClick={() => setModal(null)}>Cancel</button><button className="button-primary" disabled={busy || (!categoryOptions.length && modal.kind === "add-equipment")} type="submit">{busy ? "Saving…" : modal.kind === "edit-equipment" ? "Save changes" : "Add to inventory"} {modal.kind === "edit-equipment" ? <Check size={15} /> : <Plus size={15} />}</button></div>
                </form>
              </>
            ) : (
              <>
                <div className="modal-kicker">{modal.kind === "reservation" ? "RESERVE EQUIPMENT" : "BORROW EQUIPMENT"}</div>
                <h2 id="modal-title">{modal.kind === "reservation" ? "Plan ahead" : "Request this equipment"}</h2>
                <p className="modal-copy"><strong>{modal.item.name}</strong> · {modal.item.asset_tag} — {modal.kind === "reservation" ? "choose the dates you need it reserved." : "tell us when and where you’ll use it."}</p>
                <form className="modal-form" onSubmit={submitRequest}>
                  <label><span>Purpose</span><input name="purpose" placeholder="What will you use it for?" required maxLength={300} /></label>
                  <label><span>Location of use</span><input name="use_location" placeholder="Room, building, or event venue" required maxLength={200} /></label>
                  <label><span>Amount</span><input name="amount" type="number" min="1" max={modal.kind === "reservation" ? modal.item.quantity : Math.max(1, modal.item.available_quantity || 1)} defaultValue="1" required /><small className="field-hint">{modal.kind === "reservation" ? `${modal.item.quantity} total units in inventory; availability is checked for your selected dates.` : `${modal.item.available_quantity ?? 0} units currently available.`}</small></label>
                  {modal.kind === "reservation" ? <div className="form-row">
                    <label><span>Reservation starts</span><input type="date" name="start_date" min={new Date().toISOString().slice(0, 10)} defaultValue={new Date().toISOString().slice(0, 10)} required /></label>
                    <label><span>Pickup time</span><input type="time" name="start_time" defaultValue="09:00" required /></label>
                    <label><span>Reservation ends</span><input type="date" name="end_date" min={new Date().toISOString().slice(0, 10)} defaultValue={new Date(Date.now() + 86400000).toISOString().slice(0, 10)} required /></label>
                    <label><span>Return time</span><input type="time" name="end_time" defaultValue="17:00" required /></label>
                  </div> : <div className="form-row">
                    <label><span>Expected return date</span><input type="date" name="end_date" min={new Date().toISOString().slice(0, 10)} defaultValue={new Date(Date.now() + 86400000).toISOString().slice(0, 10)} required /></label>
                    <label><span>Expected return time</span><input type="time" name="end_time" defaultValue="17:00" required /></label>
                  </div>}
                  <div className="modal-info"><ShieldCheck size={19} /><div><strong>Requests are reviewed by the equipment team</strong><span>You’ll see status updates in My equipment.</span></div></div>
                  <div className="modal-actions"><button type="button" className="button-secondary" onClick={() => setModal(null)} disabled={busy}>Cancel</button><button className="button-primary" disabled={busy} type="submit">{busy ? "Submitting…" : "Submit request"} <ArrowUpRight size={15} /></button></div>
                </form>
              </>
            )}
          </section>
        </div>
      )}
      {recoveryMode && <PasswordRecoveryDialog supabase={supabase} onComplete={() => { setRecoveryMode(false); setNotice("Your password has been updated."); }} />}
    </div>
  );
}

function LoadingPanel() {
  return <div className="loading-panel"><span className="spinner" /> Loading workspace data…</div>;
}

function PasswordRecoveryDialog({ supabase, onComplete }) {
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    if (password !== confirmation) {
      setError("The passwords do not match.");
      return;
    }
    setBusy(true);
    setError("");
    try {
      const { error: updateError } = await supabase.auth.updateUser({ password });
      if (updateError) setError(getErrorMessage(updateError));
      else onComplete();
    } catch (updateError) {
      setError(getErrorMessage(updateError));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="modal-wrap">
      <section className="modal" role="dialog" aria-modal="true" aria-labelledby="recovery-title">
        <div className="modal-kicker">ACCOUNT RECOVERY</div>
        <h2 id="recovery-title">Choose a new password</h2>
        <p className="modal-copy">Use at least 8 characters, then confirm your new password.</p>
        <form className="modal-form" onSubmit={submit}>
          <label><span>New password</span><input type="password" autoComplete="new-password" minLength={8} maxLength={128} value={password} onChange={(event) => setPassword(event.target.value)} required /></label>
          <label><span>Confirm new password</span><input type="password" autoComplete="new-password" minLength={8} maxLength={128} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} required /></label>
          {error && <p className="feedback feedback-error" role="alert">{error}</p>}
          <div className="modal-actions"><button className="button-primary" type="submit" disabled={busy}>{busy ? "Updating…" : "Update password"} <Check size={15} /></button></div>
        </form>
      </section>
    </div>
  );
}

function BorrowingList({ rows, onRequestReturn, loading }) {
  if (loading) return <LoadingPanel />;
  if (!rows.length) return <EmptyState title="No borrowing activity yet" copy="When you request equipment, updates will appear here." />;
  return (
    <div className="loan-list">
      {rows.map((item) => (
        <article className="loan-card" key={item.id}>
          <div className="loan-art"><Laptop size={25} /></div>
          <div className="loan-main">
            <div className="loan-card-heading"><span className="card-category">{item.equipment?.category || "Equipment"}</span><StatusPill value={item.status} /></div>
            <h2>{item.equipment?.name || "Equipment"}</h2>
            <p>{item.equipment?.asset_tag || "—"} <i /> {item.quantity || 1} {Number(item.quantity || 1) === 1 ? "item" : "items"} <i /> {item.purpose || "No purpose specified"}</p>
          </div>
          <div className="loan-date"><span>Expected return</span><strong>{dateTimeLabel(item.expected_return)}</strong><small className={item.expected_return && String(item.expected_return).slice(0, 10) < new Date().toISOString().slice(0, 10) && ACTIVE_BORROWING.includes(item.status) ? "due-soon" : ""}>{item.location_of_use || "Location not set"}</small></div>
          <div className="loan-actions">
            {["approved", "checked_out"].includes(item.status) && <button className="button-secondary" onClick={() => onRequestReturn(item)}>Request return</button>}
            {item.status === "return_requested" && <span className="return-note"><Clock3 size={14} /> Return requested</span>}
          </div>
        </article>
      ))}
    </div>
  );
}

function ReservationList({ rows, loading, admin = false }) {
  if (loading) return <LoadingPanel />;
  if (!rows.length) return <EmptyState title="No reservations yet" copy="Reserve equipment for an upcoming project from the equipment library." />;
  return (
    <div className="reservation-list">
      {rows.map((item) => (
        <article className="reservation-row" key={item.id}>
          <span className="reservation-icon"><CalendarDays size={18} /></span>
          <div className="reservation-main"><strong>{item.equipment?.name || "Equipment"}</strong><span>{item.equipment?.asset_tag} · {item.quantity || 1} {Number(item.quantity || 1) === 1 ? "item" : "items"} · {item.purpose || "No purpose specified"}{admin && item.requester_email ? ` · ${item.requester_email}` : ""}</span></div>
          <div className="reservation-dates"><strong>{dateLabel(item.start_date)} — {dateLabel(item.end_date)}</strong><span>{item.location_of_use || "Location not set"}</span></div>
          <StatusPill value={item.status} />
        </article>
      ))}
    </div>
  );
}

function BorrowingTable({ rows, loading }) {
  if (loading) return <LoadingPanel />;
  if (!rows.length) return <EmptyState title="No history yet" copy="Completed and active borrowing requests will be listed here." />;
  return (
    <div className="table-wrap">
      <table>
        <thead><tr><th>Equipment</th><th>Borrower</th><th>Dates</th><th>Status</th></tr></thead>
        <tbody>{rows.map((item) => <tr key={item.id}>
          <td><strong>{item.equipment?.name || "Equipment"}</strong><small>{item.equipment?.asset_tag}</small></td>
          <td>{item.borrower_email || "Member"}</td>
          <td><strong>{dateLabel(item.start_date)} – {dateLabel(item.expected_return)}</strong><small>{item.location_of_use || item.purpose}</small></td>
          <td><StatusPill value={item.status} /></td>
        </tr>)}</tbody>
      </table>
    </div>
  );
}

function AdminRequests({ borrowings, reservations, busy, runAction, supabase, canReview }) {
  const [borrowerSearch, setBorrowerSearch] = useState("");
  const query = borrowerSearch.trim().toLocaleLowerCase();
  const matchesBorrower = (name, email) => !query
    || `${name || ""} ${email || ""}`.toLocaleLowerCase().includes(query)
    || String(name || "").toLocaleLowerCase().split(/\s+/).some((part) => part.startsWith(query));
  const pendingBorrowings = borrowings.filter((item) =>
    ["pending", "return_requested"].includes(item.status)
      && matchesBorrower(item.borrower_name, item.borrower_email));
  const pendingReservations = reservations.filter((item) =>
    item.status === "pending"
      && matchesBorrower(item.requester_name, item.requester_email));
  return (
    <>
      <div className="toolbar request-search-toolbar">
        <label className="search-box"><Search size={18} /><input value={borrowerSearch} onChange={(event) => setBorrowerSearch(event.target.value)} placeholder="Search borrower first or last name" aria-label="Search borrower requests by first or last name" /><kbd>⌕</kbd></label>
        <span className="filter-caption">{pendingBorrowings.length + pendingReservations.length} matching requests</span>
      </div>
      <div className="section-title"><div><h2>Borrowing & return requests</h2><p>{canReview ? "Review each member request before updating inventory status." : "Search requests using a borrower's first or last name."}</p></div><span className="record-count">{pendingBorrowings.length} to review</span></div>
      {!pendingBorrowings.length ? <EmptyState title={query ? "No matching borrowing requests" : "All caught up"} copy={query ? "Try another first or last name." : "There are no borrowing or return requests waiting for review."} /> : (
        <div className="admin-request-list">
          {pendingBorrowings.map((item) => (
            <article className="admin-request" key={item.id}>
              <div className="loan-art"><Laptop size={23} /></div>
              <div className="admin-request-main"><div className="loan-card-heading"><span className="card-category">{item.equipment?.asset_tag}</span><StatusPill value={item.status} /></div><h2>{item.equipment?.name || "Equipment"}</h2><p>{item.borrower_name} · {item.borrower_email || item.borrower_id} · {item.quantity || 1} {Number(item.quantity || 1) === 1 ? "item" : "items"} · {item.purpose}</p><small>{dateLabel(item.start_date)} – {dateTimeLabel(item.expected_return)} · {item.location_of_use}</small></div>
              {canReview && <div className="admin-actions">
                {item.status === "pending" ? <>
                  <button className="button-secondary" disabled={busy} onClick={() => runAction(() => supabase.rpc("review_borrowing_request", { p_borrowing_id: item.id, p_action: "reject" }), "Request declined.")}>Decline</button>
                  <button className="button-primary" disabled={busy} onClick={() => runAction(() => supabase.rpc("review_borrowing_request", { p_borrowing_id: item.id, p_action: "approve" }), "Borrowing request approved.")}><Check size={15} /> Approve</button>
                </> : <button className="button-primary" disabled={busy} onClick={() => runAction(() => supabase.rpc("complete_equipment_return", { p_borrowing_id: item.id }), "Equipment marked as returned.")}><CheckCircle2 size={15} /> Confirm return</button>}
              </div>}
            </article>
          ))}
        </div>
      )}
      <div className="section-title"><div><h2>Reservation requests</h2><p>Check availability before confirming upcoming dates.</p></div><span className="record-count">{pendingReservations.length} to review</span></div>
      {!pendingReservations.length ? <EmptyState title={query ? "No matching reservation requests" : "No reservations to review"} copy={query ? "Try another first or last name." : "New reservation requests will appear here."} /> : (
        <div className="admin-request-list">
          {pendingReservations.map((item) => (
            <article className="admin-request" key={item.id}>
              <span className="reservation-icon"><CalendarDays size={19} /></span>
              <div className="admin-request-main"><div className="loan-card-heading"><span className="card-category">{item.equipment?.asset_tag}</span><StatusPill value={item.status} /></div><h2>{item.equipment?.name || "Equipment"}</h2><p>{item.requester_name} · {item.requester_email || item.requester_id} · {item.quantity || 1} {Number(item.quantity || 1) === 1 ? "item" : "items"} · {item.purpose}</p><small>{dateLabel(item.start_date)} – {dateLabel(item.end_date)} · {item.location_of_use}</small></div>
              {canReview && <div className="admin-actions">
                <button className="button-secondary" disabled={busy} onClick={() => runAction(() => supabase.rpc("review_equipment_reservation", { p_reservation_id: item.id, p_action: "reject" }), "Reservation declined.")}>Decline</button>
                <button className="button-primary" disabled={busy} onClick={() => runAction(() => supabase.rpc("review_equipment_reservation", { p_reservation_id: item.id, p_action: "approve" }), "Reservation approved.")}><Check size={15} /> Approve</button>
              </div>}
            </article>
          ))}
        </div>
      )}
    </>
  );
}

function EquipmentTable({ equipment, onEdit, onDelete }) {
  if (!equipment.length) return <EmptyState title="No equipment records" copy="Add the first item to start your inventory." />;
  return (
    <div className="table-wrap inventory-table">
      <table><thead><tr><th>Asset</th><th>Category</th><th>Available / total</th><th>Storage</th><th>Status</th><th>Actions</th></tr></thead>
        <tbody>{equipment.map((item) => <tr key={item.id}>
          <td><div className="inventory-asset">{item.image_url && <img src={item.image_url} alt="" />}<div><strong>{item.name}</strong><small>{item.asset_tag}</small></div></div></td><td>{item.category || "—"}</td><td>{item.available_quantity ?? "—"} / {item.quantity}</td><td>{item.location || "—"}</td><td><StatusPill value={item.quantity === 0 || item.available_quantity === 0 ? "out_of_stock" : item.status} /></td>
          <td><div className="table-actions">
            <button type="button" className="button-secondary" onClick={() => onEdit(item)} aria-label={`Edit ${item.name}`}><Pencil size={14} /> Edit</button>
            <button type="button" className="button-danger" onClick={() => onDelete(item)} aria-label={`Remove ${item.name}`}><Trash2 size={14} /> Delete</button>
          </div></td>
        </tr>)}</tbody>
      </table>
    </div>
  );
}

function EquipmentAuditLog({ entries }) {
  if (!entries.length) return <EmptyState title="No equipment changes recorded" copy="Equipment additions, edits, and removals will be captured here automatically." />;
  return (
    <div className="audit-list">
      {entries.map((entry) => (
        <article className="audit-entry" key={entry.id}>
          <span className={`audit-mark audit-${entry.action}`}><Activity size={16} /></span>
          <div className="audit-entry-main">
            <strong>{entry.action === "insert" ? "Equipment added" : entry.action === "delete" ? "Equipment removed" : "Equipment updated"}</strong>
            <p>{entry.asset_tag} · {entry.changed_fields.join(", ")}</p>
            <small>{new Date(entry.changed_at).toLocaleString()} · User {entry.actor_id || "unknown"}</small>
            <details>
              <summary>Show recorded values</summary>
              <div className="audit-values">
                {entry.old_values && <div><b>Before</b><pre>{JSON.stringify(entry.old_values, null, 2)}</pre></div>}
                {entry.new_values && <div><b>After</b><pre>{JSON.stringify(entry.new_values, null, 2)}</pre></div>}
              </div>
            </details>
          </div>
        </article>
      ))}
    </div>
  );
}

function AccountSettings({ profile, user, busy, onSave }) {
  return (
    <section className="account-panel">
      <div className="account-panel-heading">
        <span className="toolbar-icon"><Settings size={18} /></span>
        <div><h2>Profile information</h2><p>Update the information shown to other workspace members.</p></div>
      </div>
      <form className="modal-form account-form" onSubmit={onSave}>
        <div className="profile-photo-setting">
          <ProfileAvatar name={profile?.display_name || user.email || "Member"} photoUrl={profile?.profile_photo_url} className="profile-photo-preview" />
          <div>
            <label><span>Profile photo</span><input name="profile_photo" type="file" accept="image/jpeg,image/png,image/webp" /><small className="field-hint">JPEG, PNG, or WebP; up to 5 MB. Borrower photos are visible in the admin and custodian equipment workspace.</small></label>
            {profile?.profile_photo_path && <label className="checkbox-label"><input name="remove_profile_photo" type="checkbox" /><span>Remove current photo when saving</span></label>}
          </div>
        </div>
        <div className="form-row">
          <label><span>First name</span><input name="first_name" defaultValue={profile?.first_name?.trim() || profile?.display_name?.trim().split(/\s+/)[0] || ""} autoComplete="given-name" required maxLength={60} /></label>
          <label><span>Last name</span><input name="last_name" defaultValue={profile?.last_name?.trim() || profile?.display_name?.trim().split(/\s+/).slice(1).join(" ") || ""} autoComplete="family-name" required maxLength={60} /></label>
        </div>
        <label><span>Email address</span><input value={user.email || ""} readOnly /></label>
        <div className="form-row">
          <label><span>Department</span><input name="department" defaultValue={profile?.department || ""} maxLength={120} placeholder="Your department" required /></label>
          <label><span>Course</span><input name="course" defaultValue={profile?.course || ""} maxLength={120} placeholder="Your course" required /></label>
        </div>
        <label><span>Gender</span><select name="gender" defaultValue={profile?.gender || ""} required><option value="">Select gender</option><option value="Female">Female</option><option value="Male">Male</option><option value="Non-binary">Non-binary</option><option value="Prefer not to say">Prefer not to say</option><option value="Other">Other</option></select></label>
        <div className="account-form-actions"><span>Your role: <strong>{profile?.role || "member"}</strong></span><button className="button-primary" type="submit" disabled={busy}>{busy ? "Saving…" : "Save account settings"} <Check size={15} /></button></div>
      </form>
    </section>
  );
}

function CurrentlyBorrowedWorkspace({ rows, categories, loading }) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("all");
  const [selectedCategory, setSelectedCategory] = useState("All equipment");
  const [activeTable, setActiveTable] = useState("borrowed");
  if (loading) return <LoadingPanel />;
  const normalizedQuery = query.trim().toLowerCase();
  const matchesFilters = (item) => {
    const matchesStatus = status === "all" || item.record_status === status;
    const matchesCategory = selectedCategory === "All equipment" || item.category_name === selectedCategory;
    const matchesSearch = !normalizedQuery || [
      item.equipment_name,
      item.asset_code,
      item.borrower_name,
      item.department,
      item.destination,
      item.storage_location,
    ].some((value) => value?.toLowerCase().includes(normalizedQuery));
    return matchesStatus && matchesCategory && matchesSearch;
  };
  const borrowedRows = rows.filter((item) => item.record_type === "borrow" && matchesFilters(item));
  const reservedRows = rows.filter((item) => item.record_type === "reservation" && matchesFilters(item));
  const summary = [
    ["borrowed", "Borrowed"],
    ["overdue", "Overdue"],
    ["reserved", "Reserved"],
  ];
  const visibleRows = activeTable === "borrowed" ? borrowedRows : reservedRows;
  const statusCount = (value) => rows.filter((item) => item.record_status === value).length;
  return (
    <>
      <section className="tracking-summary" aria-label="Equipment status summary">
        {summary.map(([value, label]) => <article key={value} className={`tracking-summary-card tracking-${value}`}><span>{label}</span><strong>{statusCount(value)}</strong></article>)}
      </section>
      <div className="toolbar currently-borrowed-toolbar">
        <label className="search-box"><Search size={17} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search equipment, tag, borrower or location" aria-label="Search equipment tracking" /></label>
        <label className="tracking-filter"><span className="sr-only">Filter by category</span><select value={selectedCategory} onChange={(event) => setSelectedCategory(event.target.value)}><option>All equipment</option>{categories.map((item) => <option key={item.category_id} value={item.category_name}>{item.category_name}</option>)}</select></label>
        <label className="tracking-filter"><span className="sr-only">Filter by equipment status</span><select value={status} onChange={(event) => setStatus(event.target.value)}><option value="all">All statuses</option>{summary.map(([value, label]) => <option key={value} value={value}>{label} ({statusCount(value)})</option>)}</select></label>
        <span className="filter-caption">{visibleRows.length} records</span>
      </div>
      <div className="tracking-table-tabs" role="tablist" aria-label="Equipment tracking tables">
        <button type="button" role="tab" aria-selected={activeTable === "borrowed"} className={activeTable === "borrowed" ? "active" : ""} onClick={() => setActiveTable("borrowed")}>Borrowed equipments <span>{borrowedRows.length}</span></button>
        <button type="button" role="tab" aria-selected={activeTable === "reserved"} className={activeTable === "reserved" ? "active" : ""} onClick={() => setActiveTable("reserved")}>Reserved equipment <span>{reservedRows.length}</span></button>
      </div>
      {!visibleRows.length ? <EmptyState title={rows.length ? "No matching equipment" : "No tracking records available"} copy={rows.length ? "Try a different search, category, or status filter." : "Equipment inventory, reservations, checkouts, and returns will appear here."} /> : <div className="table-wrap tracking-table-wrap">
        <table className="tracking-table">
          <thead><tr><th>Equipment</th><th>Borrower</th><th>Status</th><th>Location of use</th><th>Pickup time</th><th>Return time</th><th>Amount</th></tr></thead>
          <tbody>{visibleRows.map((item) => (
            <tr key={item.record_id}>
              <td><div className="tracking-item"><span className="tracking-item-image">{item.equipment_image_url ? <img src={item.equipment_image_url} alt="" /> : <Package size={18} />}</span><span><strong>{item.equipment_name}</strong><small>{item.asset_code} · {item.category_name}</small></span></div></td>
              <td>{item.borrower_name ? <div className="tracking-borrower"><ProfileAvatar name={item.borrower_name} photoUrl={item.profile_photo_url} className="borrower-photo" /><span><strong>{item.borrower_name}</strong><small>{item.department || "Department not provided"}</small></span></div> : "—"}</td>
              <td><StatusPill value={item.record_status} /></td>
              <td>{item.destination || item.storage_location || "—"}</td>
              <td>{item.pickup_at ? dateTimeLabel(item.pickup_at) : item.record_type === "reservation" ? dateLabel(item.start_date) : "—"}</td>
              <td>{item.return_at ? dateTimeLabel(item.return_at) : item.record_type === "reservation" ? dateLabel(item.end_date) : "—"}</td>
              <td>{item.amount} {item.amount === 1 ? "item" : "items"}</td>
            </tr>
          ))}</tbody>
        </table>
      </div>}
    </>
  );
}

function FeedbackBoard({ threads, currentUserId, isAdmin, canManageFeedback, busy, onCreate, onReply, onDeleteReply, onStatusChange }) {
  const statusLabels = {
    open: "Open",
    under_review: "Under review",
    planned: "Planned",
    implemented: "Implemented",
  };
  return (
    <div className="feedback-board">
      <section className="feedback-compose">
        <div className="feedback-compose-heading"><span className="toolbar-icon"><MessageSquare size={18} /></span><div><h2>Start a conversation</h2><p>Suggest a feature, report an issue, or ask how the system should work in the future.</p></div></div>
        <form className="feedback-form" onSubmit={onCreate}>
          <label><span>Topic</span><input name="title" placeholder="A short title for your feedback" maxLength={140} required /></label>
          <div className="form-row">
            <label><span>Type</span><select name="category" defaultValue="suggestion"><option value="suggestion">Suggestion</option><option value="issue">Issue</option><option value="question">Question</option><option value="other">Other</option></select></label>
            <label className="feedback-message-label"><span>Your message</span><textarea name="message" placeholder="Share details so members and admins can discuss it…" rows="3" maxLength={4000} required /></label>
          </div>
          <div className="feedback-submit-row"><small>Visible to signed-in members and admins.</small><button className="button-primary" type="submit" disabled={busy}>{busy ? "Posting…" : "Post feedback"} <Send size={14} /></button></div>
        </form>
      </section>

      <div className="section-title"><div><h2>Community feedback</h2><p>Ideas and updates shared across the equipment community</p></div><span className="record-count">{threads.length} topics</span></div>
      {!threads.length ? <EmptyState title="Start the first conversation" copy="Your feedback will help members and admins decide what to improve next." /> : (
        <div className="feedback-thread-list">
          {threads.map((thread) => (
            <article className="feedback-thread" key={thread.id}>
              <header className="feedback-thread-header">
                <div><span className={`feedback-category category-${thread.category}`}>{thread.category.replaceAll("_", " ")}</span><span className={`feedback-status status-${thread.status}`}>{statusLabels[thread.status]}</span></div>
                {canManageFeedback && <label className="feedback-status-control"><span className="sr-only">Update discussion status</span><select value={thread.status} disabled={busy} onChange={(event) => onStatusChange(thread.id, event.target.value)}>{Object.entries(statusLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>}
              </header>
              <h3>{thread.title}</h3>
              <p className="feedback-thread-message">{thread.message}</p>
              <div className="feedback-byline">Started by {thread.author_name} · {new Date(thread.created_at).toLocaleString()}</div>
              {!!thread.replies.length && <div className="feedback-replies">{thread.replies.map((reply) => (
                <div className="feedback-reply" key={reply.id}>
                  <div><strong>{reply.author_name}{reply.author_id === currentUserId ? " (you)" : ""}</strong><time>{new Date(reply.created_at).toLocaleString()}</time>{isAdmin && <button className="feedback-delete-button" type="button" aria-label={`Delete comment by ${reply.author_name}`} title="Delete comment" disabled={busy} onClick={() => onDeleteReply(reply)}><Trash2 size={14} /></button>}</div>
                  <p>{reply.message}</p>
                </div>
              ))}</div>}
              <form className="feedback-reply-form" onSubmit={(event) => onReply(event, thread.id)}>
                <label><span className="sr-only">Reply to {thread.title}</span><textarea name="reply" placeholder="Add a reply to this discussion…" rows="2" maxLength={2000} required /></label>
                <button className="button-secondary" type="submit" disabled={busy}><Send size={14} /> Reply</button>
              </form>
            </article>
          ))}
        </div>
      )}
    </div>
  );
}

function MemberTable({ members, currentUserId, runAction, supabase }) {
  if (!members.length) return <EmptyState title="No member accounts yet" copy="Accounts will appear here after users sign up and confirm their email." />;
  return (
    <div className="table-wrap inventory-table">
      <table><thead><tr><th>Member</th><th>Account status</th><th>Role</th><th>Account created</th></tr></thead>
        <tbody>{members.map((member) => (
          <tr key={member.id}>
            <td><strong>{member.display_name || "Unnamed member"}</strong><small>{member.email || "Email not available"}</small></td>
            <td>{member.account_status || "—"}</td>
            <td>
              <select
                aria-label={`Change role for ${member.display_name || member.email}`}
                value={member.role}
                disabled={member.id === currentUserId}
                onChange={(event) => runAction(
                  () => supabase.rpc("set_profile_role", { p_user_id: member.id, p_role: event.target.value }),
                  "Member role updated.",
                )}
              >
                <option value="staff">Staff member</option>
                <option value="property_custodian">Property custodian</option>
                <option value="admin">Administrator</option>
              </select>
            </td>
            <td>{dateLabel(member.created_at?.slice(0, 10))}</td>
          </tr>
        ))}</tbody>
      </table>
      <p className="table-note">Your own role cannot be changed here. Ask another administrator if you need to change your access.</p>
    </div>
  );
}
