# Changelog

All notable changes to this plugin. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.1] - 2026-11-19

No change to what the plugin does.

### Changed

- The publishing job stops early, with a clear message, when the GitHub token is empty.

## [1.0.0] - 2026-11-18

First release. It shows the health of the nodes and the pods in trouble of one or more Kubernetes clusters inside Redmine, read only.

### Added

- A table of nodes per cluster: name, Ready or not with the failing condition (for example `NotReady: MemoryPressure`), and CPU and memory bars from the Metrics API, amber from 80 percent and red from 90. Nodes that are not ready come first, and a summary line says "All 3 nodes ready, no pods in trouble" or "1 of 3 nodes not ready, 2 pods in trouble".
- The pods in trouble under the nodes, with namespace, name, phase, reason and detail: a waiting reason such as `CrashLoopBackOff` or `ImagePullBackOff`, a pod `Pending` for the grace period or longer with the scheduler's message, a `Failed` pod, an `OOMKilled` container, and a container that has restarted at least the threshold number of times with the last restart within the hour. Healthy pods are not listed. At most 20 are shown and the rest are counted.
- Several clusters, each with its own address, token variable, certificate authority variable, cache and failure state. One that cannot be reached says "Status unavailable" and the others still show. A cluster without metrics-server shows "no metrics" in place of the bars.
- `Name | in-cluster` for the cluster Redmine itself runs in, using the pod's own service account.
- Links: a `Name | cluster link | node link | pod link` line per cluster turns the cluster heading, node names and pod names into links to your own tool, with `{node}`, `{namespace}` and `{pod}` filled in.
- The block as a wiki macro (`{{k8s_status}}`), a page (`/status/k8s`), a My page block, a partial, placements on the welcome page, the default My page, project Overview pages and pages matching a path list, a top menu link, and a widget on the Rubylode Status page when that plugin is installed.
- A settings page that checks each line and shows whether each token and certificate authority variable is set.
- Tokens and certificate authorities are read from `K8S_...` environment variables only, sent only to their own cluster, over https only (plain http is refused, loopback included), and never followed through a redirect. A certificate authority variable that is named but holds no certificate makes that cluster unavailable and never falls back to the system's trusted authorities.
- Pods are asked for in pages of 500 with the field selector `status.phase!=Succeeded`, up to 10 pages and no longer than twice Timeout seconds, and an answer over 10 MB is refused.
- On the Rubylode Status page a cluster without metrics-server is ok, with "no metrics" in its detail. Pods in trouble or not checked make a warning, and a node that is not ready makes it down.
- A node, metrics or pods answer of the wrong shape makes that part unreadable, never a list of no nodes. A trailing newline on a token is stripped, and a token with a line break inside is refused and never sent.
- An empty number setting means its default (cache 60, failure cache 30, timeout 3, pending grace 5, restart threshold 5); a typed 0 turns a cache off, and the timeout and restart threshold are at least 1.
- An unexpected error of the plugin's own never breaks the page. If the nodes cannot be read, the cluster shows "Status unavailable" and is cached as a failure; if only the metrics or the pods fail, that part is left out ("no metrics", "pods not checked") and the rest still shows. Only the time limit of the page that asked (the Rubylode Status page's) goes on to that page, and nothing is cached for it.
- Durations read in minutes, then hours past an hour and days past a day ("Pending 3 h", "the last 2 d ago").
