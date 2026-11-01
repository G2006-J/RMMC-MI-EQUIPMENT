"use client";

import { Download, Share } from "lucide-react";
import { useEffect, useState } from "react";

let pendingInstallPrompt = null;

const isIosDevice = () => {
  const platform = navigator.userAgentData?.platform || navigator.platform;
  return /iPhone|iPad|iPod/i.test(navigator.userAgent)
    || (platform === "MacIntel" && navigator.maxTouchPoints > 1);
};

export default function InstallAppButton() {
  const [installPrompt, setInstallPrompt] = useState(null);
  const [isIos, setIsIos] = useState(false);
  const [isInstalled, setIsInstalled] = useState(false);
  const [showIosHelp, setShowIosHelp] = useState(false);
  const [installError, setInstallError] = useState("");

  useEffect(() => {
    const standalone = window.matchMedia("(display-mode: standalone)").matches
      || navigator.standalone === true;
    setInstallPrompt(pendingInstallPrompt);
    setIsInstalled(standalone);
    setIsIos(isIosDevice() && !standalone);

    function captureInstallPrompt(event) {
      event.preventDefault();
      pendingInstallPrompt = event;
      setInstallPrompt(event);
    }

    function markInstalled() {
      setIsInstalled(true);
      pendingInstallPrompt = null;
      setInstallPrompt(null);
    }

    window.addEventListener("beforeinstallprompt", captureInstallPrompt);
    window.addEventListener("appinstalled", markInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", captureInstallPrompt);
      window.removeEventListener("appinstalled", markInstalled);
    };
  }, []);

  async function installApp() {
    if (isIos) {
      setShowIosHelp(true);
      return;
    }
    if (!installPrompt) return;

    setInstallError("");
    try {
      await installPrompt.prompt();
      const choice = await installPrompt.userChoice;
      if (choice.outcome === "accepted") setIsInstalled(true);
    } catch (error) {
      setInstallError(error instanceof Error ? error.message : "The app could not be installed. Please try again.");
    } finally {
      pendingInstallPrompt = null;
      setInstallPrompt(null);
    }
  }

  if (isInstalled || (!isIos && !installPrompt && !installError)) return null;

  return (
    <>
      {(isIos || installPrompt) && (
        <button className="install-app-button" type="button" onClick={installApp}>
          <Download size={15} />
          <span>Install app</span>
        </button>
      )}
      {installError && <p className="install-error" role="alert">{installError}</p>}
      {showIosHelp && (
        <div className="install-help-wrap" role="presentation" onClick={() => setShowIosHelp(false)}>
          <section
            className="install-help"
            role="dialog"
            aria-modal="true"
            aria-labelledby="install-help-title"
            onClick={(event) => event.stopPropagation()}
          >
            <button className="install-help-close" type="button" onClick={() => setShowIosHelp(false)} aria-label="Close">
              ×
            </button>
            <span className="install-help-icon"><Share size={18} /></span>
            <h2 id="install-help-title">Add to your Home Screen</h2>
            <p>In Safari, tap <Share size={14} /> <strong>Share</strong>, then choose <strong>Add to Home Screen</strong>.</p>
            <button className="button-primary" type="button" onClick={() => setShowIosHelp(false)}>Got it</button>
          </section>
        </div>
      )}
    </>
  );
}
