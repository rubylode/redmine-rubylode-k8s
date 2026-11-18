# Roadmap

## Goal

Show the state of a Kubernetes cluster inside Redmine: every node ready or not, CPU and memory per node, and the pods
in trouble with the reason, without a second login and without leaking a token.

## Next

1. ~~Write the implementation plan from `docs/specs/2026-11-16-cluster-status-design.md` into `docs/plans/`~~ done
   2026-11-18 (plan written): `docs/plans/cluster-status/`, modelled on Rubylode Argo CD 1.1.0.
2. ~~Capture sample answers from the development cluster with `kubectl get --raw` (read commands only, see the design)
   and build the scrubbed fixtures and the fake API server: `00-fixtures.md`.~~ done 2026-11-18.
3. ~~Build the plugin from the Rubylode Argo CD layout, test first: `01-tracer.md` through `07-settings-page.md`.~~ done
   2026-11-18.
4. ~~Screenshots, README, CHANGELOG, then release 1.0.0 the way Rubylode Beszel does: `08-release.md`.~~ done 2026-11-18:
   the demo, the README and CHANGELOG, and the local tag `v1.0.0`. Left to do: create the Gitea repository and the public
   GitHub one, then push the tag so the release workflow runs.

## After 1.0

- A volume-claims table per cluster (decided 2026-11-18): each claim's size, which app claimed it, and whether it is Bound,
  Pending or Lost, with Pending or Lost counted as trouble. The role gains get and list on `persistentvolumeclaims` and
  nothing else, and never `nodes/proxy`. It shows sizes, not how full a volume is.

## Ideas

- Per-namespace CPU and memory against requests and limits.
- Pod metrics next to the pods in trouble.
- Translations beyond English.
