import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Self-contained server output so the cockpit can run on the VPS with just
  // `node server.js` (no install/build on the agent box).
  output: "standalone",
};

export default nextConfig;
