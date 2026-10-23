// Usage: node scripts/phones.mjs <absolute path to html file> <out prefix>
// Finds each phone frame (outermost ~393x852 element) and saves it as a JPEG.
// Playwright comes from this repo's devDependencies (npm install, then npx playwright install chromium).
import { chromium } from "@playwright/test";
const [file, out] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2 });
await page.goto("file://" + file);
await page.waitForTimeout(500);
const n = await page.evaluate(() => {
  const ok = (el) => { const r = el.getBoundingClientRect(); return r.width >= 380 && r.width <= 460 && r.height >= 820 && r.height <= 940; };
  const all = [...document.querySelectorAll("body *")].filter(ok);
  const outer = all.filter((el) => !all.some((o) => o !== el && o.contains(el)));
  outer.forEach((el, i) => el.setAttribute("data-phone", i));
  return outer.length;
});
console.log(file.split("/").pop(), "phones:", n);
for (let i = 0; i < n; i++) await page.locator(`[data-phone="${i}"]`).screenshot({ path: `${out}-p${i}.jpg`, type: "jpeg", quality: 82 });
await browser.close();
