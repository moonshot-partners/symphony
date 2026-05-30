// Manual WCAG checks axe can't do: keyboard operability + visible focus + Esc.
import { chromium } from "playwright";

const url = process.env.URL ?? "http://localhost:3200";
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("text=SODEV-964");

let ok = true;

await page.keyboard.press("Tab");
const role = await page.evaluate(() => document.activeElement?.getAttribute("role"));
const text = await page.evaluate(() => document.activeElement?.textContent?.slice(0, 30));
console.log(`Tab -> focused role=${role} text="${text}"`);
if (role !== "button") ok = false;

await page.screenshot({ path: "../qa-evidence/cockpit-focus.png" });

await page.keyboard.press("Enter");
try {
  await page.waitForSelector("text=Evidence", { timeout: 3000 });
  console.log("Enter -> detail opened: OK");
} catch {
  console.log("Enter -> detail did NOT open: FAIL");
  ok = false;
}

await page.keyboard.press("Escape");
try {
  await page.waitForSelector("text=Evidence", { state: "detached", timeout: 3000 });
  console.log("Escape -> detail closed: OK");
} catch {
  console.log("Escape -> detail did NOT close: FAIL");
  ok = false;
}

await browser.close();
console.log(ok ? "\nKEYBOARD CHECKS: PASS" : "\nKEYBOARD CHECKS: FAIL");
process.exit(ok ? 0 : 1);
