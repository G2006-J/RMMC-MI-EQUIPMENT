"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { ArrowUpRight, Check, HardDrive } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

export default function ResetPasswordPage() {
  const [supabase, setSupabase] = useState(null);
  const [status, setStatus] = useState("loading");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let active = true;
    let client;

    try {
      client = createClient();
      setSupabase(client);
    } catch (clientError) {
      setError(clientError.message);
      setStatus("invalid");
      return () => { active = false; };
    }

    const { data: { subscription } } = client.auth.onAuthStateChange((event) => {
      if (active && event === "PASSWORD_RECOVERY") setStatus("ready");
    });

    client.auth.getSession().then(({ data, error: sessionError }) => {
      if (!active) return;
      if (sessionError) {
        setError(sessionError.message);
        setStatus("invalid");
      } else {
        setStatus(data.session ? "ready" : "invalid");
      }
    }).catch((sessionError) => {
      if (!active) return;
      setError(sessionError.message || "The password reset link could not be verified.");
      setStatus("invalid");
    });

    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, []);

  async function submit(event) {
    event.preventDefault();
    setError("");
    if (password !== confirmation) {
      setError("The passwords do not match.");
      return;
    }

    setBusy(true);
    try {
      const { error: updateError } = await supabase.auth.updateUser({ password });
      if (updateError) throw updateError;
      await supabase.auth.signOut({ scope: "local" });
      setStatus("success");
    } catch (updateError) {
      setError(updateError.message || "Your password could not be updated. Request a new reset link and try again.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-showcase">
        <Link className="auth-brand" href="/" aria-label="RMMC-MI equipment home">
          <span className="brand-mark"><HardDrive size={21} /></span>
          <span>RMMC <b>·</b> MI</span>
        </Link>
        <div className="showcase-copy">
          <p className="eyebrow">Account recovery</p>
          <h1>Get back to the work that matters.</h1>
          <p>Choose a new password for your RMMC-MI equipment account.</p>
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
            <p className="eyebrow">Password reset</p>
            <h2>{status === "success" ? "Password updated" : status === "invalid" ? "Reset link unavailable" : status === "ready" ? "Choose a new password" : "Verifying your link"}</h2>
            <p>{status === "success" ? "Your password has been changed. Sign in with your new password to continue." : status === "invalid" ? "This reset link is invalid or has expired. Request a new one from the sign-in page." : status === "ready" ? "Use at least 8 characters, then confirm your new password." : "Please wait while we verify your password reset link."}</p>
          </div>
          {status === "ready" && (
            <form className="auth-form" onSubmit={submit}>
              <label>
                <span>New password</span>
                <input type="password" autoComplete="new-password" minLength={8} maxLength={128} value={password} onChange={(event) => setPassword(event.target.value)} required />
              </label>
              <label>
                <span>Confirm new password</span>
                <input type="password" autoComplete="new-password" minLength={8} maxLength={128} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} required />
              </label>
              {error && <p className="feedback feedback-error" role="alert">{error}</p>}
              <button className="auth-submit" disabled={busy} type="submit">
                {busy ? "Updating…" : "Update password"}
                <Check size={16} />
              </button>
            </form>
          )}
          {status === "invalid" && error && <p className="feedback feedback-error" role="alert">{error}</p>}
          {status === "loading" && <p className="feedback" role="status">Verifying reset link…</p>}
          {(status === "success" || status === "invalid") && (
            <Link className="auth-submit" href="/">
              {status === "success" ? "Return to sign in" : "Back to sign in"}
              <ArrowUpRight size={16} />
            </Link>
          )}
          <p className="auth-terms">Use of this system is subject to your institution’s equipment policies.</p>
        </div>
      </section>
    </main>
  );
}