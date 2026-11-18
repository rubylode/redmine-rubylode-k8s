# 0. Fixtures and the fake API

Roadmap item 2. Blocked by nothing. Read commands only against the development cluster (`get --raw`, `get`, `top`);
never apply, edit, delete, exec or read Secrets.

## Done means

`test/support/fixtures/kubernetes/` holds scrubbed answers, `test/support/fake_kubernetes_api.rb` serves them over https,
and not one real name from the development cluster is in the repository.

## Steps

1. Capture with `kubectl get --raw` into a scratch folder outside the repository, one body per file: `nodes.body`
   (`/api/v1/nodes`), `pods.body` (`/api/v1/pods?fieldSelector=status.phase!=Succeeded`), `node_metrics.body`
   (`/apis/metrics.k8s.io/v1beta1/nodes`). The proxy signs in as an administrator, so synthesise the 401, 403 and 404
   bodies as Kubernetes `Status` objects (`"kind":"Status","reason":"Forbidden","code":403`).
2. `script/scrub_fixtures.rb RAW_FOLDER [OUTPUT_FOLDER]`, from Argo CD's: rebuild every object from an allowlist of the
   keys the plugin reads (node name, conditions, allocatable; pod namespace, name, creationTimestamp, phase, reason,
   message, conditions, container and init container statuses; metrics name and usage). Map every node, namespace, pod,
   container and image name to a made-up one; drop labels, hosts, IPs and uids. Shift every timestamp so the capture
   moment is `2026-11-16T12:00:00Z`. Print the real names it replaced.
3. Plan's call: the script adds these exact cases, which later slices assert on:
   - `node-d`: Ready `False`, MemoryPressure `True`, no metrics entry; `node-a` at 24 percent CPU and 44 memory.
   - `shop/billing-api-7d9f6c-x2k4p`: waiting `CrashLoopBackOff`, restartCount 12, last terminated 8 minutes before.
   - `jobs/import-28311-abcde`: Pending 14 minutes, PodScheduled `False`, "0/3 nodes are available: insufficient memory".
   - `shop/cache-0`: lastState terminated `OOMKilled` 20 minutes before.
   - `shop/web-5c8d7-q9wzt`: restartCount 7, the last 3 hours before (not trouble).
   - `shop/report-6f2b1-m3kd8`: Pending 2 minutes (inside the grace).
   - `batch-test/nightly-check-29110-zz9kq`: Failed, reason `Error`. The rest stay healthy.
4. Grep the output for every name the script printed; none may survive. Keep the scratch folder until this passes.
5. `FakeKubernetesApi`, from `fake_argocd_server.rb`:
   - `CAPTURED_AT = Time.utc(2026, 11, 16, 12)`, `TOKEN = "fake.kubernetes.token-not-a-secret"`.
   - Plan's call: https, since this plugin refuses plain http even on loopback. `.certificate_authority_pem` makes one
     CA per process with OpenSSL; each server gets a leaf for `127.0.0.1`, `localhost` and any `host_names:`. No `.pem`
     file in the repository (`.gitea/publish.rb` refuses them).
   - `GET /api/v1/nodes`, `GET /api/v1/pods` (honours `limit` and `continue`), `GET /apis/metrics.k8s.io/v1beta1/nodes`;
     401 unless `Bearer` one of `accepted_tokens`.
   - Controls: `failure` (`server_error`, `timeout`, `unauthorized`), `redirect_to`, `forbidden_paths` (403),
     `metrics_missing` (404), `nodes_answer=`, `pods_answer=`, `metrics_answer=`, `pod_body_bytes=`, `reset!`, and the
     same over `POST /__fail/...`, `/__redirect_to`, `/__reset`, `GET /__requests`.
   - `seen_requests` records method, path, query, `Host` and `Authorization`.
   - Run alone, it writes its CA to `FAKE_KUBERNETES_CA_PATH` for `bin/demo`.

## Not in this slice

The plugin. The fake is first exercised by slice 1.
