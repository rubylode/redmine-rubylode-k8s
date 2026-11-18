# 4. Several clusters, transport rules and in-cluster

Blocked by slice 1. Touches credentials: a fresh read-only reviewer at the end (the diff plus this file).

## Done means

Every cluster line has its own section; one cluster down, slow or refusing the token says "Status unavailable" there
only (administrators see why, never the token); each token reaches only its own address; an `in-cluster` line uses the
pod's service account and reads its token on each refresh.

## Steps

1. `Settings#clusters` reads many lines and `Name | in-cluster`. Plan's call: `in_cluster_account.rb`, module
   `InClusterAccount`, `ADDRESS = "https://kubernetes.default.svc"`, `DIRECTORY = "/var/run/secrets/kubernetes.io/
   serviceaccount"`, `.token`, `.certificate_authority_pem`, `.token_file_present?`,
   `.certificate_authority_file_present?`, and `address=`/`directory=` for tests (as `ClusterStatus.cache=`). An
   in-cluster `Cluster` has `in_cluster: true`, the account's address, and a `#token` that reads the file each call.
2. The client reads the token once per refresh (slice 1): a rotation is picked up next refresh, never mid-refresh.
3. Nodes failing makes the cluster unavailable; pods or metrics failing does not (slices 2, 3).
4. Plan's call: any 3xx is refused, as Argo CD does, rather than followed even to the same host.
5. Port Argo CD's `several_instances_test.rb`; drop its plain-http, link-address and IPv6 cases.

## Tests, in order (`test/integration/several_clusters_test.rb`)

1. "two clusters give two sections in the order of the settings".
2. "a cluster that answers 500, or is slower than the timeout, is unavailable alone; only an administrator sees why".
3. "after a failure the cluster is not asked again within the failure cache time".
4. "each token is sent only to its own cluster": each fake's `seen_requests` holds only its own `Bearer`.
5. "a redirect to another host is not followed with the token" (Review Focus): first fake `redirect_to = second.url`;
   the second records no request with the first token; the first section says "redirected".
6. "a plain http address is refused, loopback included": `http://127.0.0.1:<port>` is unavailable, the fake sees nothing.
7. "neither token is in the page, the log or the reason, even when a cluster fails" (`captured_log`).
8. "a variable that is unset, or does not start with K8S_, makes that cluster unavailable and is never read or sent".
9. "an answer bigger than 10 MB is refused, and an administrator is told why" (`pod_body_bytes`).
10. "an in-cluster line uses the mounted token and CA": `InClusterAccount.directory` at a temporary folder with `token`
    and `ca.crt` (the fake's CA), `.address` at the fake; the fake sees the file's `Bearer`.
11. "a rotated in-cluster token is read again on the next refresh" (Review Focus): cache seconds 0, `accepted_tokens =
    ["first", "second"]`; write "first", load, write "second", load; the last two headers are `Bearer first`, `Bearer
    second`.
12. "an in-cluster line without the token file is unavailable with a clear reason".

## Not in this slice

The settings page check of the files (7). Pinning a token to a host from the environment (an Argo CD after-1.0 idea).
