// Capture cockpit QA evidence: board + open ticket detail.
// Usage: node scripts/shot.mjs   (dev server must be running on URL)
import { chromium } from "playwright";

const url = process.env.URL ?? "http://localhost:3100";
const out = "../qa-evidence";

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1366, height: 800 } });

await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("text=SODEV-956");
await page.waitForTimeout(700);
await page.screenshot({ path: `${out}/cockpit-board.png` });

const noHScroll = await page.evaluate(
  () => document.documentElement.scrollWidth <= window.innerWidth
);
console.log(`no horizontal page scroll @1366: ${noHScroll}`);

await page.getByText("Fix collection search debounce").click();
await page.waitForSelector("text=Timeline");
await page.waitForTimeout(600);
await page.screenshot({ path: `${out}/cockpit-detail.png` });

const links = await page.$$eval('a[target="_blank"][rel*="noopener"]', (els) =>
  els.map((e) => e.getAttribute("href"))
);
console.log("clickable external links in detail:", JSON.stringify(links));

await page.getByText("before.png").click();
await page.waitForTimeout(500);
await page.screenshot({ path: `${out}/cockpit-lightbox.png` });

await browser.close();
console.log("captured board + detail + lightbox");
