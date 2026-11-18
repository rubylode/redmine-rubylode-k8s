# Cluster status: implementation plan

Spec: `docs/specs/2026-11-16-cluster-status-design.md`. Date: 2026-11-18. Model: Rubylode Argo CD 1.1.0
(`~/Code/ruby/redmine-rubylode-argocd`); its plan is the format.

## Goal

Per Kubernetes cluster, one row per node (Ready or not, the failing condition, CPU and memory bars) and the pods in
trouble with their reason, in every place Rubylode Argo CD shows its block. Read only; no token reaches another host.

## Architecture

A client of our own makes three GETs per cluster (nodes, pods paged with a field selector, node metrics) over https
only, trusting each cluster's own CA. `ClusterStatus` turns the answers into node rows, pods in trouble and a summary,
and caches the extracted rows per cluster. Everything around it is Argo CD's, renamed.

Seams, as in Argo CD: (1) Redmine requests against `test/support/fake_kubernetes_api.rb`, which serves the fixtures over
real https, a second fake playing the wrong host; (2) the status model (`ClusterStatus`, `TroubleRule`, `Quantity`),
JSON in and rows out. No test reaches into a private method.

## Order

| # | File | What becomes true | Blocked by |
|---|---|---|---|
| 0 | `00-fixtures.md` | Scrubbed fixtures and an https fake API | nothing |
| 1 | `01-tracer.md` | One cluster's nodes on `/status/k8s` | 0 |
| 2 | `02-node-usage.md` | CPU and memory bars, "no metrics", failing conditions | 1 |
| 3 | `03-pods-in-trouble.md` | Pods in trouble, paged and capped | 1 |
| 4 | `04-several-clusters.md` | Clusters fail alone; transport rules; in-cluster | 1 |
| 5 | `05-summary-and-visibility.md` | Summary line, ordering, Block title, who may see it | 2, 3, 4 |
| 6 | `06-placements.md` | Macro, My page block, hooks, top menu, Status widget | 5 |
| 7 | `07-settings-page.md` | Settings validate; variables and files reported | 4 |
| 8 | `08-release.md` | Demo, screenshots, README, CHANGELOG, local tag v1.0.0 | 6, 7 |

Slices 2, 3 and 4 go in any order; 7 can run beside 5 and 6. Each slice starts in a fresh session from its file, works
test first, runs single files while working and `bin/test` once at the end, and ends with conventional commits.

## Global Constraints

- Redmine 5.1, 6.0, 6.1 and 7.0; Ruby 3.2 to 4.0; Kubernetes 1.28 and newer. Tests are Minitest.
- Plugin id `redmine_rubylode_k8s`, settings `plugin_redmine_rubylode_k8s`, namespace `RubylodeK8s`.
- Page `/status/k8s`, macro `{{k8s_status}}`, My page block "Kubernetes", default Block title "Kubernetes".
- Locale prefix `rubylode_k8s`, CSS prefix `rubylode-k8s-`, stylesheet `rubylode_k8s.css`.
- Token and CA variables match `/\AK8S_[A-Z0-9_]+\z/`; no other variable is ever read.
- https only: plain http is refused everywhere, loopback included (Argo CD allows loopback; this plugin does not).
- Read only: `GET /api/v1/nodes`, `GET /api/v1/pods`, `GET /apis/metrics.k8s.io/v1beta1/nodes`, nothing else.
- GPL v2 header on every Ruby file, first line `# Rubylode Kubernetes: cluster status from the Kubernetes API for Redmine`.
- Descriptive names without abbreviations (`certificate_authority_pem`, not `ca_pem`).
- No real names from the development cluster in the repository, the fixtures or the screenshots.

## Review Focus

Five ways this can hurt a user that the obvious tests would miss. Each owning slice carries the named test.

1. A token sent on a redirect to another host: slice 4, "a redirect to another host is not followed with the token".
2. An in-cluster token rotated between refreshes: slice 4, "a rotated in-cluster token is read again on the next
   refresh".
3. A 403 on pods while nodes succeed: slice 3, "pods refused with 403 leave the nodes showing and say the pods were not
   checked".
4. Metrics for only some nodes: slice 2, "a node missing from the metrics answer shows no metrics while the others show
   bars".
5. A huge pod list: slice 3, "a cluster with more pods than the page cap is asked for 10 pages and says so".

Quantity parsing and a node without a Ready condition are covered by slice 2's own tests.

## Sources to copy from

Argo CD, renaming `argocd` to `k8s` and `RubylodeArgocd` to `RubylodeK8s`: `init.rb`, routes, controller, `lib/*`,
`path_matcher`, `settings`, `settings_validator`, `secure_transport`, `status_widget`, `argocd_client` (to
`kubernetes_client`), `application_status` (to `cluster_status`), views, stylesheet, `bin/test`, Docker files,
`.github/`, `.gitea/`, `test/test_helper.rb`, `script/scrub_fixtures.rb`. Beszel: `usage_level.rb`, the bar markup and
CSS, `bin/demo`, `script/{seed_demo.rb,browser.mjs,demo_screenshots.mjs}`, `package.json`. Leave out Argo CD's
`attention_rule.rb` (replaced by `TroubleRule`), the link address and Allow plain http.
