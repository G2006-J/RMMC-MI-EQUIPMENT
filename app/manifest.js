export default function manifest() {
  return {
    name: "RMMC-MI Equipment Borrowing",
    short_name: "RMMC Equipment",
    description: "Equipment borrowing and inventory for RMMC-MI.",
    start_url: "/",
    display: "standalone",
    background_color: "#f6f7f4",
    theme_color: "#132b20",
    icons: [
      {
        src: "/icon.svg",
        sizes: "any",
        type: "image/svg+xml",
        purpose: "any maskable",
      },
    ],
  };
}
