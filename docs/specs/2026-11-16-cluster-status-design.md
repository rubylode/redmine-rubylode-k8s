# Rubylode Kubernetes: design

Date: 2026-11-16. Status: approved for planning.

## Intent

Show the state of one or more Kubernetes clusters inside Redmine: whether every node is ready, how much CPU and memory
each node uses, and which pods are in trouble and why. Two audiences: a team that wants a glance in Redmine without
`kubectl`, and anyone who installs it as a public Rubylode plugin next to Rubylode Beszel and Rubylode Argo CD.

Rubylode Argo CD (a sibling built first, `~/code/ruby/redmine-rubylode-argocd`) answers "are my deploys healthy and in
sync with git". This plugin answers "is the cluster under them healthy and does it have room".

## Goals

- Per cluster, one row per node: name, Ready or not (with the failing condition, for example `MemoryPressure`), and
  CPU and memory bars from the Metrics API, coloured like Beszel's (amber from 80 percent, red from 90).
- Under the nodes, only the pods that are in trouble, each with namespace, name, phase and reason: waiting reasons such
  as `CrashLoopBackOff`, `ImagePullBackOff`, `CreateContainerConfigError`; `Pending` longer than a grace period (with the
  scheduler's message when there is one); `Failed`; a container restarted at least 5 times in the last hour, or
  terminated with `OOMKilled` recently. Healthy pods are not listed.
- A summary line: "All 3 nodes ready, no pods in trouble", "1 of 3 nodes not ready, 2 pods in trouble".
- Several clusters, each with its own address, token and failure state. One cluster being down shows "unavailable" for
  that cluster only.
- Without the Metrics API (no metrics-server) the bars are replaced by "no metrics" and everything else still works.
- The same places to show it as Rubylode Beszel: the wiki macro, a page, a My page block, a partial, the placements and
  a widget on the Rubylode Status page when that plugin is installed.
- Read only. Tokens stay in environment variables and are sent only to the cluster they belong to.

## Non-goals

- Any action: restart, scale, delete, exec, logs.
- Per-namespace usage against requests and limits, history or charts.
- Application health and sync (Rubylode Argo CD covers that).
- Events beyond the message on the pod or node itself.

## Anti-goals (a failure even if it works)

- A token reaching another host, or appearing in a page, a log line or an error message.
- Asking for more rights than reading: the README's role must stay get/list on the resources listed below, never
  Secrets, ConfigMaps or logs.
- Listing every pod in a big cluster on each page view. Pods are fetched with a field selector excluding
  `status.phase=Succeeded`, and the answer is cached like Beszel's.
- Real names from the development cluster in the repository, the fixtures or the screenshots.

## Constraints

- Redmine 5.1, 6.0, 6.1 and 7.0; Ruby 3.2 to 4.0. Tests are Minitest.
- Plugin id `redmine_rubylode_k8s`, namespace `RubylodeK8s`, page `/status/k8s`, macro `{{k8s_status}}`, My page block
  "Kubernetes", settings stored as `plugin_redmine_rubylode_k8s`.
- Kubernetes 1.28 and newer. API calls: `GET /api/v1/nodes`, `GET /api/v1/pods` (field selector as above),
  `GET /apis/metrics.k8s.io/v1beta1/nodes`. Pod metrics are not needed for the first version.
- The role the README asks for is a ClusterRole with get/list on `nodes` and `pods`, and get/list on `metrics.k8s.io`
  `nodes`, and nothing else, bound to a ServiceAccount with a long-lived token Secret
  (`kubernetes.io/service-account-token`). Trimmed on 2026-11-18 to exactly what the plugin reads; the development
  cluster's read-only account is broader (it adds namespaces, workloads, jobs and pod metrics), which is fine for testing.

## Approaches considered

1. **Copy the house pattern (chosen).** As Rubylode Argo CD does: Beszel's layout, Windmill's client and
   attention-rule pieces, shared helpers copied and renamed. If Rubylode Argo CD is done by then, reuse its versions
   of the per-instance settings, cache and failure handling rather than reworking Beszel's.
2. **A Kubernetes client gem (`kubeclient`, `k8s-ruby`).** Rejected: three GET calls do not justify a dependency tree
   in every Redmine that installs the plugin, and the transport rules (host binding, https, timeouts) are easier to keep
   in one small client of our own.
3. **Shell out to `kubectl`.** Rejected: a public plugin cannot require a binary and a kubeconfig on the Redmine host.

## What was decided

### Reaching the API

Settings take clusters one per line:

    Name | address | token variable | CA variable
    Production | https://k8s.example.com:6443 | K8S_PRODUCTION_TOKEN | K8S_PRODUCTION_CA
    Here | in-cluster

- Variables must start with `K8S_`. The CA variable holds the PEM text of the cluster's CA; empty means the system
  trust store.
- `in-cluster` (only the name and that word) uses the pod's mounted service account: address
  `https://kubernetes.default.svc`, token `/var/run/secrets/kubernetes.io/serviceaccount/token` (read on each refresh,
  because Kubernetes rotates it), CA `.../ca.crt`. The settings page says whether those files exist.
- A token is sent only to its own cluster's address; redirects to another host are not followed with it. Plain http
  is refused (the Kubernetes API always speaks TLS).

### Settings

| Setting | Default | Meaning |
|---|---|---|
| Clusters | empty | As above. |
| Links | empty | One line per cluster, `Name | cluster link | node link | pod link`, each optional, with `{node}`, `{namespace}` and `{pod}` filled in. The cluster heading, node names and trouble pod names link to the owner's own tool (Argo CD, Headlamp, a dashboard); without a pattern they stay plain text. Added 2026-11-18. |
| Pending grace minutes, Restart threshold | 5, 5 | When a Pending pod or a restarting container counts as trouble. |
| Namespaces to ignore | empty | One per line; their pods are never listed (for example a namespace of batch jobs that fail on purpose). |
| Cache seconds, Failure cache seconds, Timeout seconds | 60, 30, 3 | Per cluster, as in Beszel. |
| Block title | Kubernetes | Heading of the block and the top menu link. |
| Who may see the block | Everyone signed in | Or administrators only. Anonymous never. |
| Show the block on | all off | The placements, as in Beszel. |

### Display

```
Kubernetes                         All 3 nodes ready, 2 pods in trouble
Production
Node            Status   CPU               Memory
node-a          Ready    ████░░░░  24%     ████░░░░  44%
node-b          Ready    █░░░░░░░  10%     ██░░░░░░  24%
node-c          Ready    ██░░░░░░  20%     ██░░░░░░  27%
Pods in trouble
shop/billing-api-7d9f6c-x2k4p   CrashLoopBackOff   12 restarts in the last hour
jobs/import-28311-abcde        Pending 14 min     0/3 nodes are available: insufficient memory
```

### Development data

The development cluster's API is reachable from the developer's Mac only through a tailnet proxy that signs requests
in as the developer's own login (an administrator), so a ServiceAccount token cannot be used from there and `--as`
impersonation is not honoured. Capture sample answers with `kubectl get --raw` and use read commands only
(`get --raw`, `get`, `top`); never apply, edit, delete, exec or read Secrets. The paths to capture are
`/api/v1/nodes`, `/api/v1/pods?fieldSelector=status.phase!=Succeeded` and `/apis/metrics.k8s.io/v1beta1/nodes`.
Raw answers go to a scratch folder outside the repository. Fixtures for the fake API server
(`test/support/fake_kubernetes_api.rb`) are built from them with every node, namespace, pod, image, host and label
replaced by made-up values. Include a not-ready node, a CrashLoopBackOff pod, a long Pending pod with a scheduler
message, an OOMKilled container, and a cluster answer without the Metrics API (404 on the metrics path).

The development cluster runs metrics-server and has a read-only account that covers the role above (and more), so the
plugin's calls can be checked against it.

## Left to the builder

- Exact class layout inside `app/models/rubylode_k8s/`, and how much to share in shape with Rubylode Argo CD.
- Wording of messages and settings help, in the voice of the existing plugins.
- Whether "restarted at least N times in the last hour" uses `lastState.terminated.finishedAt` or a simpler
  restart-count rule; pick the one the fixtures can test honestly and say which in the README.
- The demo (`bin/demo`), screenshot script and release mechanics, following Beszel. The repository and its remote do
  not exist yet beyond this folder.
