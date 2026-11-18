# 1. Tracer: one cluster's nodes on the status page

Blocked by slice 0.

## Done means

With one cluster line, an administrator opening `/status/k8s` sees one row per node with its name and status (`Ready`,
`NotReady`, `Unknown`), served by the fake over https with its CA, and CI runs the 5.1 to 7.0 matrix.

## Steps

1. Prefactoring commit, no behaviour: Argo CD's skeleton renamed. `init.rb` registers `redmine_rubylode_k8s`, "Rubylode
   Kubernetes", `0.1.0`, defaults `clusters ""`, `pending_grace_minutes "5"`, `restart_threshold "5"`,
   `namespaces_to_ignore ""`, cache `"60"`, failure cache `"30"`, timeout `"3"`, `block_title "Kubernetes"`,
   `visibility "logged_in"`, placements `"0"`. Route `status/k8s` to `RubylodeK8sStatusController#show`.
   `plugin_registered_test.rb` passes.
2. `settings.rb`: `TOKEN_VARIABLE_PATTERN = /\AK8S_[A-Z0-9_]+\z/`; `Cluster = Struct.new(:name, :address,
   :token_variable, :certificate_authority_variable, :in_cluster, keyword_init: true)` with `#token` and
   `#certificate_authority_pem` (empty unless the variable matches); `#clusters` parses
   `Name | address | token variable | CA variable`, CA optional.
3. `secure_transport.rb`: `SecureTransport.allowed?(uri)` (https and a host); `.certificate_store_for(pem)`, an
   `OpenSSL::X509::Store` with every certificate in the text, or the default paths when it is empty.
4. `kubernetes_client.rb` from `argocd_client.rb`: `KubernetesClient.new(cluster:, timeout_seconds:)`, `#nodes`,
   `Unavailable < StandardError` with `attr_reader :status`. Keep the 10 MB body cap, `max_retries = 0`, no proxy, any
   3xx refused, the token scrubbed from messages; add `VERIFY_PEER` and `cert_store`. The token is read once in
   `initialize`, so one refresh uses one token.
5. `cluster_status.rb` from `application_status.rb`: `ClusterStatus.report_for(cluster, settings = Settings.current)`,
   `.node_rows_from(nodes_answer, metrics_answer = nil)`, `NodeRow = Struct.new(:name, :status, :failing_conditions,
   :cpu_percent, :memory_percent, keyword_init: true)`, `cache=`, `forget`, `cache_key_for`, and `Report = Struct.new(
   :node_rows, :trouble_pods, :more_trouble_count, :pods_truncated, :pods_failure_reason, :metrics_available,
   :metrics_failure_reason, :unavailable, :failure_reason, keyword_init: true)`, later fields filled by slices 2
   and 3. Plan's call: cache
   the extracted report as a plain hash (`Report#to_cache`, `Report.from_cache`), not the raw answers, which Argo CD's
   roadmap lists as an after-1.0 fix for Memcached's 1 MB limit.
6. Status from the `Ready` condition: `"True"` is `Ready`, `"False"` is `NotReady`, `"Unknown"` or none is `Unknown`.
7. Views `rubylode_k8s/_status.html.erb` (nodes only), `rubylode_k8s_status/show.html.erb`, the stylesheet.

## Tests, in order

1. `test/unit/cluster_status_test.rb`, "each node becomes a row with its name and status": `node-a`, `node-b`,
   `node-c` `Ready`, `node-d` `NotReady`.
2. `test/integration/status_page_test.rb`, "an administrator sees one row per node": four `.rubylode-k8s-node` rows.
3. "the call carries the token from the named variable over https": `Bearer fake.kubernetes.token-not-a-secret` on
   `/api/v1/nodes`.
4. "the cluster's CA variable is trusted, and without it the fake's certificate is refused" ("Status unavailable").
5. "a second look within the cache time does not ask Kubernetes again".

## Not in this slice

Metrics (2), pods (3), several clusters and in-cluster (4), the summary (5).
