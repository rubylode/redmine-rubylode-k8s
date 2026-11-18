// README screenshots from the demo Redmine (bin/demo up), in its default theme, with the fake cluster's made-up data.
//   npm install && npm run screenshots
import { execFileSync } from "node:child_process"
import { mkdirSync } from "node:fs"
import { baseUrl, launch, signedInPage } from "./browser.mjs"

const out = new URL("../docs/screenshots/", import.meta.url).pathname
const root = new URL("../", import.meta.url).pathname
mkdirSync(out, { recursive: true })

async function scenario(name) {
  execFileSync("ruby", ["bin/demo", "scenario", name], { cwd: root, stdio: "inherit" })
  await new Promise((resolve) => setTimeout(resolve, 6000)) // the demo caches each cluster's answer for 5 seconds
}

async function shoot(page, name, path, selector, extra = {}) {
  await page.goto(`${baseUrl}${path}`, { waitUntil: "load" })
  await page.waitForSelector(selector)
  await page.screenshot({ path: `${out}${name}.png`, ...extra })
  console.log("saved", `${name}.png`)
}

const browser = await launch()
const page = await signedInPage(browser, "sam.rivera", "demo-password-1", { width: 1280, height: 700 })

await scenario("all_ready")
await shoot(page, "status-all-ready", "/status/k8s", ".rubylode-k8s-table")

await scenario("one_not_ready")
await shoot(page, "status-trouble", "/status/k8s", ".rubylode-k8s-pods-table")
await shoot(page, "wiki-macro", "/projects/operations/wiki/Clusters", ".wiki .rubylode-k8s-table")

await scenario("no_metrics")
await shoot(page, "status-no-metrics", "/status/k8s", ".rubylode-k8s-no-metrics")

await scenario("unavailable")
await shoot(page, "status-unavailable", "/status/k8s", ".rubylode-k8s-unavailable")

await scenario("one_not_ready")
const administrator = await signedInPage(browser, "admin", "admin", { width: 1280, height: 1500 })
await shoot(administrator, "settings", "/settings/plugin/redmine_rubylode_k8s", ".rubylode-k8s-variable-state")
await browser.close()
