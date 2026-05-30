// Record a short clip of the board so the motion (progress sheen, ping dot,
// spinner, animated "Checking…") is visible as evidence.
import { chromium } from "playwright";

const url = process.env.URL ?? "http://localhost:3200";
const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width: 1366, height: 800 },
  recordVideo: { dir: "../qa-evidence/video", size: { width: 1366, height: 800 } },
});
const page = await context.newPage();
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("text=SODEV-956");
await page.waitForTimeout(5000); // let the loops run

const video = page.video();
await context.close();
console.log("video at:", await video.path());
await browser.close();
