# 2. Node usage: CPU and memory bars

Blocked by slice 1.

## Done means

Each node row shows CPU and memory bars, usage over allocatable, amber from 80 percent and red from 90; without
metrics-server the bars say "no metrics" and the rest still works; a node under pressure names the condition.

## Steps

1. `quantity.rb`, `Quantity.parse(text)`, a `Rational` or `nil`:

   ```ruby
   BINARY = { "Ki" => 2**10, "Mi" => 2**20, "Gi" => 2**30, "Ti" => 2**40, "Pi" => 2**50, "Ei" => 2**60 }.freeze
   DECIMAL = { "n" => Rational(1, 10**9), "u" => Rational(1, 10**6), "m" => Rational(1, 1000), "" => 1,
               "k" => 10**3, "M" => 10**6, "G" => 10**9, "T" => 10**12, "P" => 10**15, "E" => 10**18 }.freeze
   PATTERN = /\A(\d+(?:\.\d+)?)(?:[eE]([+-]?\d+)|(Ki|Mi|Gi|Ti|Pi|Ei|[numkMGTPE]))?\z/

   def self.parse(text)
     match = PATTERN.match(text.to_s.strip) or return nil
     number = Rational(match[1])
     return number * Rational(10)**match[2].to_i if match[2]
     number * (BINARY[match[3]] || DECIMAL[match[3].to_s])
   end
   ```
2. `usage_level.rb`: Beszel's `UsageLevel` as is (80.0, 90.0, `.for`, `.clamp`).
3. `KubernetesClient#node_metrics`. After nodes succeed, `ClusterStatus` asks for metrics; a 404 or 403 sets
   `Report#metrics_available = false` and `metrics_failure_reason`, never making the cluster unavailable.
4. `node_rows_from`: `cpu_percent = usage.cpu / allocatable.cpu * 100` as a `Float`, likewise memory; `nil` when either
   side is missing or allocatable is zero. Plan's call: allocatable, as `kubectl top node` uses. `failing_conditions`
   lists `MemoryPressure`, `DiskPressure`, `PIDPressure`, `NetworkUnavailable` when `"True"`.
5. View: Beszel's bar markup renamed to `rubylode-k8s-bar is-normal|is-warning|is-critical`; status cell
   "NotReady: MemoryPressure"; "no metrics" in both cells for a node without a reading.

## Tests, in order

1. `test/unit/quantity_test.rb`, table-driven: `"250m"` is `1/4`, `"2"` is `2`, `"1Gi"` is `1073741824`, `"3977412Ki"` is
   `4072869888`, `"1500000n"` is `3/2000`, `"250u"` is `1/4000`, `"1.5k"` is `1500`, `"12e3"` is `12000`, `"1E"` is
   `10**18`; `""`, `"abc"` and `"5Kb"` are `nil`.
2. `test/unit/usage_level_test.rb`: 79.9 normal, 80 warning, 90 critical, `nil` nothing.
3. `cluster_status_test.rb`: "percent is usage over allocatable": `node-a` reads 24 and 44 (the scrub script sets it).
4. "a node missing from the metrics answer shows no metrics while the others show bars" (Review Focus): `node-d` has
   `nil` percents, `node-a` keeps its numbers.
5. "a node without a Ready condition is Unknown"; "a node with MemoryPressure True names it".
6. Integration `node_usage_test.rb`: "without the Metrics API the bars say no metrics and the nodes still show"
   (`metrics_missing = true`); "metrics refused with 403 behave the same, and only an administrator sees why".
7. "bars carry the level class": a node at 91 percent memory has `.rubylode-k8s-bar.is-critical`.

## Not in this slice

Pod metrics (a roadmap idea). Requests and limits.
