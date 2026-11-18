# 7. Settings page

Blocked by slice 4.

## Done means

The settings page takes every setting in the design's table, refuses bad lines with a message naming the line, says
next to each cluster whether its token and CA variables are set (never their values), and for an `in-cluster` line
whether the token and CA files exist.

## Steps

1. `settings_validator.rb` from Argo CD's: drop Allow plain http and Apps to show. A cluster line has 2 fields
   (`Name | in-cluster`) or 3 to 4 (`Name | address | token variable | CA variable`). `NUMBER_FIELDS` gains
   `"pending_grace_minutes" => 0` and `"restart_threshold" => 1`. Namespaces to ignore: one per line, each matching
   `/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/`, refused with its line number.
2. `settings_controller_patch.rb` as Argo CD's, calling `ClusterStatus.forget`.
3. `app/views/settings/_rubylode_k8s.html.erb` from Argo CD's: the clusters box with the line format and an example of
   each kind, the two trouble numbers, Namespaces to ignore, the cache and timeout numbers, Block title, who may see it,
   the placements. Next to each line: "token variable set / not set", "CA variable set / not set / system trust store",
   or for in-cluster "token file found / not found", "CA file found / not found".

4. Links out (owner's decision, 2026-11-18): a "Links" setting, default empty, one line per cluster,
   `Name | cluster link | node link | pod link`, every link optional (an empty field means no link). The name must match a
   cluster line. Placeholders: `{node}` in the node link, `{namespace}` and `{pod}` in the pod link; each value is
   percent-encoded before it goes in. Only `https://` or `http://` links with a host are accepted (no `javascript:`,
   no relative links); a bad line is refused with its line number. On the status page the cluster heading, each node name
   and each trouble pod name become links when their pattern is set, and stay plain text otherwise. The links never carry
   a token. Example in the settings help: `Production | https://argocd.example.com/applications | | https://argocd.example.com/applications?search={pod}`.
   `Settings#links_for(cluster_name)` returns the three patterns; `LinkTemplate.expand(pattern, values)` does the
   substitution.

## Tests, in order (`test/integration/settings_page_test.rb`)

1. "saving valid cluster lines stores them as plugin settings" (`plugin_redmine_rubylode_k8s`).
2. "each bad cluster line is refused with its line number": one field; five fields; an address that is not a URL;
   `http://` (always, no checkbox); a token variable not starting with `K8S_`; a CA variable not starting with `K8S_`;
   `Here | in-cluster | K8S_X` (in-cluster takes no more fields); a duplicate name. `#` lines are ignored.
3. "an address with credentials, a query or a fragment is refused with its line number".
4. "a namespace that is not a valid name is refused with its line number".
5. "pending grace, restart threshold, cache, failure cache and timeout outside their bounds are refused".
6. "the page says whether each variable is set and never shows a value".
7. "for an in-cluster line the page says whether the token and CA files exist" (`InClusterAccount.directory` pointed at
   a temporary folder with only `token`).
8. "saving clears the cache, so the next page load asks Kubernetes again".
9. "someone who is not an administrator cannot open or save the settings", and "the validation patch is applied".
10. "each bad links line is refused with its line number": an unknown cluster name; more than four fields; a
    `javascript:` link; a relative link.
11. `test/unit/link_template_test.rb`, "placeholders are replaced with percent-encoded values": a pod named `a b/c`
    gives `a%20b%2Fc`; an unknown placeholder is left as written.
12. `test/integration/status_links_test.rb`, "names link out when a pattern is set and stay text when not": with a node
    link and a pod link set for the fake cluster, `node-a` and `billing-api-…` are links to the expanded addresses and
    the cluster heading is plain text; with no links line nothing on the page is a link to outside Redmine.

## Not in this slice

Live checking of the address or the token from the settings page (no network call on save).
