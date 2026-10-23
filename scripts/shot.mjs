// Usage: node scripts/shot.mjs <absolute path to html file> <out prefix> [width]
// Saves a full-page PNG plus one PNG per 1000px band, and logs page errors.
// Playwright comes from this repo's devDependencies (npm install, then npx playwright install chromium).
import { chromium } from "@playwright/test";
const [file, out, width = "1440"] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: Number(width), height: 1000 }, deviceScaleFactor: 1 });
page.on("pageerror", (e) => console.log("PAGEERROR", e.message));
page.on("console", (m) => m.type() === "error" && console.log("CONSOLE", m.text()));
await page.goto("file://" + file);
await page.waitForTimeout(500);
const h = await page.evaluate(() => document.documentElement.scrollHeight);
console.log("height", h);
await page.screenshot({ path: `${out}-full.png`, fullPage: true });
for (let y = 0, i = 0; y < h; y += 1000, i++) {
  await page.screenshot({ path: `${out}-${i}.png`, fullPage: true, clip: { x: 0, y, width: Number(width), height: Math.min(1000, h - y) } });
}
await browser.close();
