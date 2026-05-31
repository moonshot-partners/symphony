import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Self-contained server output so the cockpit runs on the VPS with just
  // `node server.js` (no build on the box at runtime).
  output: "standalone",
  // The only image is the small Moonshot logo; skip optimization so the server
  // needs no native sharp binary (not installed on the VPS).
  images: { unoptimized: true },
};

export default nextConfig;
