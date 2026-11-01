import "./globals.css";
import PwaRegister from "./pwa-register";

export const dynamic = "force-dynamic";

export const metadata = {
  title: "RMMC-MI Equipment Borrowing",
  description: "Equipment inventory, borrowing, reservations, and returns for RMMC-MI.",
  applicationName: "RMMC-MI Equipment",
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "RMMC Equipment",
  },
};

export const viewport = {
  themeColor: "#132b20",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <PwaRegister />
        {children}
      </body>
    </html>
  );
}
