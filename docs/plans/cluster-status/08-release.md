# 8. Demo, screenshots, README, CHANGELOG and release

Roadmap item 4. Blocked by slices 6 and 7.

## Done means

`bin/demo up` shows the plugin against the fake API, the README screenshots are taken from it, the README and CHANGELOG
describe 1.0.0, and tag `v1.0.0` exists locally on a green suite. Nothing is pushed: the repository has no remote yet.

## Steps

1. `docker-compose.yml` from Beszel's (Redmine on `127.0.0.1:3014`, Plan's call: the next free port after Beszel's 3013),
   with a `fake_kubernetes` service running `ruby /plugin/test/support/fake_kubernetes_api.rb` over https with host name
   `fake_kubernetes`, and Argo CD's `test` service.
2. `bin/demo` from Beszel's: `up`, `restart`, `scenario NAME`, `down`, `reset`. Plan's call: `up` starts the fake first,
   waits for its CA in `tmp/demo/certificate_authority.txt` (git-ignored `tmp/`), then starts Redmine with that text in
   `K8S_DEMO_CA` and the fake's token in `K8S_DEMO_TOKEN`. Scenarios: `all_ready`, `one_not_ready`, `no_metrics`,
   `unavailable`, switched over the fake's `POST /__...` controls.
3. `script/seed_demo.rb` from Beszel's: settings with two clusters ("Production" on the fake, "Staging" pointing
   at a closed port), a demo person, a wiki page with `{{k8s_status}}`, the My page block.
4. `package.json`, `script/browser.mjs` and `script/demo_screenshots.mjs` from Beszel's: `status-all-ready.png`,
   `status-trouble.png`, `status-no-metrics.png`, `status-unavailable.png`, `wiki-macro.png`, `settings.png` in
   `docs/screenshots/`. Check each image for a real name before committing.
5. `README.md` laid out like Argo CD's: What it does, Install, **A read-only Kubernetes account** (the ClusterRole with
   get/list on `nodes` and `pods` and on `metrics.k8s.io` `nodes`, nothing more; never Secrets, ConfigMaps or logs; a ServiceAccount; a `kubernetes.io/service-account-token` Secret; how to
   read the token and CA into `K8S_...` variables), Settings, Redmine in the same cluster (`in-cluster`), Where it
   shows, Security, Troubleshooting, Development, Releasing, License. State the restart rule in the words of slice 3.
6. Check that the development cluster's read-only account covers every rule in the README's role by reading it
   (`kubectl get clusterrole <name> -o yaml`, read only); the account is broader than the README's role, which is fine.
   `--as` is not honoured there, so no `auth can-i --as`.
7. `CHANGELOG.md` in Keep a Changelog form, `## [1.0.0] - <date>`, Added items mirroring Argo CD's 1.0.0 entry.
8. `.github/workflows/{tests,release,security}.yml` and `dependabot.yml` already came in slice 1; copy
   `.gitea/publish.rb` and `.gitea/workflows/publish.yml` with `PUBLISH_GITHUB_REPOSITORY: rubylode/redmine-rubylode-k8s`.
   `docs/redmine-org-listing.md` from Beszel's.
9. Set `version "1.0.0"` in `init.rb`, run `bin/test` once, commit, `git tag v1.0.0`. Stop there.

## Not in this slice

Creating a remote. A Gitea repository (as `origin`) and the public `rubylode/redmine-rubylode-k8s` on GitHub are needed
before the tag can be pushed and the release workflow can run; that is a separate step on explicit request.
Installing on a production Redmine.
