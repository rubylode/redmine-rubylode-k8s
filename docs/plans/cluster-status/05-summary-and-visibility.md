# 5. Summary, ordering, Block title and visibility

Blocked by slices 2, 3 and 4 (the summary counts nodes, pods and unavailable clusters).

## Done means

The block opens with the design's summary line, nodes that are not ready come first, Block title heads the block, and
only the people the setting allows see it.

## Steps

1. `ClusterStatus::Summary = Struct.new(:node_count, :not_ready_count, :trouble_count, :pods_unchecked_cluster_count,
   :unavailable_cluster_count, keyword_init: true)` with `#state` (`:trouble`, `:unavailable`, `:no_nodes`,
   `:all_fine`) and `#text`; `ClusterStatus.summary_for(reports)` from Argo CD's. Unavailable clusters are not
   counted; `trouble_count` adds `more_trouble_count`; a cluster with `pods_failure_reason` counts as unchecked.
   Node part then pod part, joined by a comma:
   - nodes: "All 3 nodes ready" or "1 of 3 nodes not ready"; pods: "no pods in trouble" or "2 pods in trouble"
     (pluralised in the locale).
   - Plan's call: pods not checked on some cluster replace the pod part with "pods not checked on 1 cluster" when no
     trouble was found, and append it after the count otherwise.
   - Unavailable clusters append ". 1 cluster unavailable", as Argo CD does.
2. Node rows: `NotReady` and `Unknown` first, then by name (Plan's call, as Argo CD puts attention first).
3. The controller's `require_permission_to_see_status` and `Settings#visible_to?` as Argo CD's.

## Tests, in order

1. Unit `cluster_status_test.rb`, "the summary says": `node_count: 3, not_ready_count: 0, trouble_count: 0` gives
   "All 3 nodes ready, no pods in trouble"; `3, 1, 2` gives "1 of 3 nodes not ready, 2 pods in trouble"; `3, 0, 2` gives
   "All 3 nodes ready, 2 pods in trouble".
2. Unit: "an unavailable cluster is not counted, and the summary says so".
3. Unit: "pods not checked are said, never counted as none in trouble".
4. Unit: "nodes that are not ready come first, then by name": `node-d` before `node-a`.
5. Integration `test/integration/summary_and_visibility_test.rb`: "the page opens with the summary" (fixture: "1 of 4
   nodes not ready, 4 pods in trouble").
6. Integration: "by default any signed in person sees the page; the reason a cluster failed is for administrators alone".
7. Integration: "Administrators only turns a signed in person away, and still shows the page to an administrator".
8. Integration: "an anonymous visitor is sent to sign in, whoever the setting allows".
9. Integration: "Block title is the heading, Kubernetes when none is set".

## Not in this slice

The placements (6) and the settings form (7).
