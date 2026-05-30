// WCAG + best-practice audit with axe-core across the cockpit's states.
// Usage: URL=http://localhost:3200 node scripts/a11y.mjs
import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";

const url = process.env.URL ?? "http://localhost:3200";
const WCAG = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"];

const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await context.newPage();
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("text=SODEV-956");

async function run(label, tags) {
  const { violations } = await new AxeBuilder({ page }).withTags(tags).analyze();
  console.log(`\n## ${label}: ${violations.length} violation(s)`);
  for (const v of violations) {
    console.log(`- [${v.impact}] ${v.id}: ${v.help} (${v.nodes.length})`);
    for (const n of v.nodes.slice(0, 3)) {
      console.log(`    ${JSON.stringify(n.target)} | ${n.failureSummary?.replace(/\n/g, " ")}`);
    }
  }
  return violations.length;
}

let wcag = 0;
let bp = 0;

async function both(state) {
  wcag += await run(`${state} [WCAG A/AA]`, WCAG);
  bp += await run(`${state} [best-practice]`, ["best-practice"]);
}

await both("board");

await page.getByText("Fix collection search debounce").click();
await page.waitForSelector("text=Timeline");
await page.waitForTimeout(700);
await both("detail sheet");

await page.getByText("before.png").click();
await page.waitForTimeout(700);
await both("lightbox dialog");

console.log(`\nTOTAL WCAG A/AA: ${wcag}`);
console.log(`TOTAL best-practice: ${bp}`);
await browser.close();
process.exit(wcag > 0 ? 1 : 0);
