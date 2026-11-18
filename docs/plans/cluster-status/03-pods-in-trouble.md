# 3. Pods in trouble

Blocked by slice 1.

## Done means

Under the nodes, only the pods in trouble, with namespace, name, phase, reason and detail. Pods come paged and capped
with the field selector, Namespaces to ignore is honoured, and a refusal on pods leaves the nodes showing.

## The restart rule

Plan's call: a container is restarting when `restartCount` is at least Restart threshold **and**
`lastState.terminated.finishedAt` is under an hour old. Kubernetes keeps the total and the last termination, not a
history, so this is the rule a fixed clock can test. README: "listed as restarting when it has restarted at least 5
times in all and the last restart was within the hour". Detail: "12 restarts, the last 8 min ago" (not the design's
"in the last hour"). "OOMKilled recently" uses the same hour.

## Steps

1. `trouble_rule.rb`, `TroubleRule.trouble_for(pod, now:, pending_grace_minutes:, restart_threshold:)`, returning `nil`
   or a hash of `reason`, `message`, `restart_count`, `last_restart_at`, `pending_since`. First match wins:

   ```ruby
   WAITING_REASONS = %w[CrashLoopBackOff ImagePullBackOff ErrImagePull CreateContainerConfigError
                        CreateContainerError InvalidImageName RunContainerError].freeze
   RECENT_SECONDS = 3600
   statuses = hashes(pod, "initContainerStatuses") + hashes(pod, "containerStatuses")
   # 1. a status waiting in WAITING_REASONS      -> that reason, its restartCount, lastState finishedAt
   # 2. phase "Failed"                           -> status.reason || "Failed", status.message
   # 3. phase "Pending", creationTimestamp at least
   #    pending_grace_minutes * 60 before now    -> "Pending", pending_since, PodScheduled "False" message
   # 4. state or lastState terminated "OOMKilled",
   #    finishedAt within RECENT_SECONDS         -> "OOMKilled", restartCount
   # 5. restartCount >= restart_threshold, lastState
   #    finishedAt within RECENT_SECONDS         -> "Restarting", restartCount, last_restart_at
   ```
   Plan's call: four waiting reasons beyond the design's three, and init containers count.
2. `KubernetesClient#pods` returns `PodList = Struct.new(:items, :truncated)`: `?fieldSelector=status.phase!=Succeeded
   &limit=500`, following `continue`. Plan's call: `POD_PAGE_SIZE = 500`, `POD_PAGE_LIMIT = 10`, and Argo CD's
   `DEADLINE_TIMEOUT_MULTIPLE = 2` (no new page past twice Timeout seconds); either sets `truncated`, carried to
   `Report#pods_truncated`.
3. `ClusterStatus.trouble_pods_from(pods, now:, settings:)` gives `TroublePod = Struct.new(:namespace, :name, :phase,
   :reason, :message, :restart_count, :last_restart_at, :pending_since, keyword_init: true)`, ignored namespaces
   skipped, by namespace then name. Plan's call: at most `TROUBLE_LIST_LIMIT = 20` kept, the rest counted in
   `Report#more_trouble_count` ("and 14 more"); the summary counts them all.
4. A failed pods call sets `Report#pods_failure_reason`; the cluster stays available.

## Tests, in order

1. `test/unit/trouble_rule_test.rb`, `now = FakeKubernetesApi::CAPTURED_AT`: billing-api `CrashLoopBackOff`, 12
   restarts; import `Pending` with "0/3 nodes are available: insufficient memory"; cache-0 `OOMKilled`; nightly-check
   `Error`; web (7 restarts, 3 hours ago) and report (Pending 2 minutes) `nil`.
2. Unit: an inline Running pod with 7 restarts, the last 10 minutes ago, is `Restarting` at threshold 7 and `nil` at 8;
   grace 15 makes import `nil`.
3. Unit: "an ignored namespace is never listed": `batch-test` ignored leaves three pods.
4. Integration `pods_in_trouble_test.rb` (`travel_to CAPTURED_AT`): "only the pods in trouble are listed", with
   "Pending 14 min" and "12 restarts, the last 8 min ago"; the recorded `fieldSelector` is `status.phase!=Succeeded`.
5. "pods refused with 403 leave the nodes showing and say the pods were not checked" (Review Focus):
   `forbidden_paths = ["/api/v1/pods"]`; four node rows, "Pods could not be checked", the reason for administrators only.
6. "a cluster with more pods than the page cap is asked for 10 pages and says so" (Review Focus): 5,001 synthetic Running
   pods; exactly 10 pod requests, each `limit=500`; "Only the first 5000 pods were checked".
7. "more than 20 pods in trouble show 20 and a count of the rest".

## Not in this slice

Events, logs, pod metrics. The summary wording (5).
