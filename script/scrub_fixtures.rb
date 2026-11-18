#!/usr/bin/env ruby
# frozen_string_literal: true

# Rubylode Kubernetes: cluster status from the Kubernetes API for Redmine
# Copyright (C) 2026  Nick Gorbikoff
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require "json"
require "fileutils"
require "time"

# Builds the fake Kubernetes API's fixtures from answers captured from a real cluster.
#
#   ruby script/scrub_fixtures.rb RAW_FOLDER [OUTPUT_FOLDER]
#
# RAW_FOLDER is outside the repository and holds the raw answers, one body per file, captured with read commands only:
#
#   nodes.body           GET /api/v1/nodes
#   pods.body            GET /api/v1/pods?fieldSelector=status.phase!=Succeeded
#   node_metrics.body    GET /apis/metrics.k8s.io/v1beta1/nodes
#
# Every object is rebuilt from a list of keys the plugin reads, so whatever the script does not know about (labels,
# hosts, addresses, uids, volumes, images' digests) is left out rather than copied. Every node, namespace, pod, container
# and image name is replaced by a made-up value, and every timestamp is shifted so the capture moment is CAPTURED_AT.
#
# The output has exactly four nodes (the first three real ones, plus a synthetic one that is not ready) and every real
# pod is made healthy: Running, Ready, a few restarts, nothing recent. The cases the plugin has to show are then added
# as synthetic pods, so later tests can assert exact counts: one node of four not ready, four pods in trouble.
#
# Last, every string in the raw answers is looked for in the output. The real values replaced and any that survive are
# written to RAW_FOLDER (never printed), and the script fails if a real value survives that is not ordinary Kubernetes
# vocabulary.
class FixtureScrubber
  CAPTURED_AT = Time.utc(2026, 11, 16, 12)
  NODE_NAMES = %w[node-a node-b node-c].freeze
  NOT_READY_NODE_NAME = "node-d"

  # Real namespaces become these; kube-system names nothing of the cluster's and stays.
  NAMESPACES = %w[payments storefront telemetry data queue mail search tools platform support].freeze
  KEPT_NAMESPACES = %w[kube-system].freeze
  WORKLOAD_NAMES = %w[
    ledger notifications gateway inventory checkout mailer scheduler auth-service images analytics exporter search-index
    job-runner catalog ingest sessions uploader metrics-relay audit-log reconciler dispatcher
  ].freeze
  CONTAINER_NAMES = %w[app sidecar proxy agent exporter helper].freeze

  NODE_CONDITION_TYPES = %w[NetworkUnavailable MemoryPressure DiskPressure PIDPressure Ready].freeze
  ALLOCATABLE_KEYS = %w[cpu memory pods].freeze
  HEALTHY_RESTART_LIMIT = 2
  POD_NAMES_TAKEN_BY_CASES = %w[billing-api web cache report import nightly-check].freeze

  # Strings in the raw answers that may appear in the fixtures because they name nothing of the cluster's.
  VOCABULARY = %w[
    Running Pending Failed Succeeded Completed Error True False Ready Initialized ContainersReady PodScheduled
    NetworkUnavailable MemoryPressure DiskPressure PIDPressure kube-system v1 default NodeList PodList NodeMetricsList
    metrics.k8s.io/v1beta1 NodeMetrics KubeletReady KubeletNotReady KubeletHasSufficientMemory KubeletHasNoDiskPressure
    KubeletHasSufficientPID status namespace true false kubelet metrics server CrashLoopBackOff OOMKilled ContainerCreating Unschedulable ContainersNotReady
  ].freeze

  def initialize(raw_folder, output_folder)
    @raw_folder = raw_folder
    @output_folder = output_folder
    @random = Random.new(20_261_116)
    @replacements = Hash.new { |hash, category| hash[category] = {} }
    @taken_names = []
  end

  def run
    raw_nodes = read_json("nodes.body").fetch("items").sort_by { |node| node.dig("metadata", "name") }
    raw_pods = read_json("pods.body").fetch("items")
    raw_metrics = read_json("node_metrics.body").fetch("items")
    @offset = CAPTURED_AT - capture_moment(raw_metrics)

    # The fixtures are rebuilt whole, so a renamed object leaves no stale file behind.
    Dir[File.join(@output_folder, "**", "*.json")].each { |path| File.delete(path) }

    nodes = scrub_nodes(raw_nodes)
    pods = raw_pods.map { |pod| scrub_pod(pod) } + synthetic_pods
    metrics = scrub_metrics(raw_metrics, raw_nodes, nodes)

    write("nodes.json", list("NodeList", nodes))
    write("pods.json", list("PodList", pods))
    write("node_metrics.json", "kind" => "NodeMetricsList", "apiVersion" => "metrics.k8s.io/v1beta1", "metadata" => {}, "items" => metrics)
    write_errors

    check_for_survivors
  end

  private

  def read_json(name)
    JSON.parse(File.read(File.join(@raw_folder, name)))
  end

  def write(relative_path, data)
    path = File.join(@output_folder, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(data)}\n")
  end

  def list(kind, items)
    { "kind" => kind, "apiVersion" => "v1", "metadata" => { "resourceVersion" => "1000" }, "items" => items }
  end

  # The same real value always gets the same made-up one.
  def fake(category, real)
    return real if real.nil? || real == ""

    @replacements[category][real] ||= yield
  end

  def hex(length)
    Array.new(length) { "0123456789abcdef"[@random.rand(16)] }.join
  end

  def alphanumeric(length)
    Array.new(length) { "bcdfghjklmnpqrstvwxz2456789"[@random.rand(27)] }.join
  end

  # --- time ------------------------------------------------------------------------------------------------------

  def capture_moment(raw_metrics)
    raw_metrics.map { |item| Time.parse(item.fetch("timestamp")) }.max
  end

  def shift(timestamp)
    return nil if timestamp.nil?

    [Time.parse(timestamp) + @offset, CAPTURED_AT].min.utc.iso8601
  end

  def minutes_before_capture(minutes)
    (CAPTURED_AT - (minutes * 60)).utc.iso8601
  end

  # --- nodes -----------------------------------------------------------------------------------------------------

  def scrub_nodes(raw_nodes)
    real = raw_nodes.first(NODE_NAMES.size)
    real += [real.last] * (NODE_NAMES.size - real.size)
    scrubbed = real.each_with_index.map do |node, index|
      name = NODE_NAMES.fetch(index)
      fake("node", node.dig("metadata", "name")) { name } if index < raw_nodes.size
      {
        "metadata" => { "name" => name },
        "status" => {
          "conditions" => node.dig("status", "conditions").select { |condition| NODE_CONDITION_TYPES.include?(condition["type"]) }
                              .map { |condition| scrub_node_condition(condition) },
          "allocatable" => node.dig("status", "allocatable").slice(*ALLOCATABLE_KEYS)
        }
      }
    end
    scrubbed << not_ready_node(scrubbed.last)
  end

  # The network condition's reason and message name the cluster's network software, so they are the standard ones.
  def scrub_node_condition(condition)
    reason, message = condition["type"] == "NetworkUnavailable" ? ["RouteCreated", "RouteController created a route"] : condition.values_at("reason", "message")
    { "type" => condition["type"], "status" => condition["status"], "reason" => reason,
      "message" => message, "lastTransitionTime" => shift(condition["lastTransitionTime"]) }.compact
  end

  def not_ready_node(template)
    since = minutes_before_capture(30)
    conditions = [
      { "type" => "NetworkUnavailable", "status" => "False", "reason" => "KubeletReady", "message" => "network is available" },
      { "type" => "MemoryPressure", "status" => "True", "reason" => "KubeletHasInsufficientMemory", "message" => "kubelet has insufficient memory available" },
      { "type" => "DiskPressure", "status" => "False", "reason" => "KubeletHasNoDiskPressure", "message" => "kubelet has no disk pressure" },
      { "type" => "PIDPressure", "status" => "False", "reason" => "KubeletHasSufficientPID", "message" => "kubelet has sufficient PID available" },
      { "type" => "Ready", "status" => "False", "reason" => "KubeletNotReady", "message" => "container runtime is not responding" }
    ].map { |condition| condition.merge("lastTransitionTime" => since) }
    {
      "metadata" => { "name" => NOT_READY_NODE_NAME },
      "status" => { "conditions" => conditions, "allocatable" => template.dig("status", "allocatable").dup }
    }
  end

  # node-a is shown at 24 percent CPU and 44 percent memory; the other real nodes keep what the cluster reported.
  # The not ready node has no metrics entry at all.
  def scrub_metrics(raw_metrics, raw_nodes, nodes)
    by_real_name = raw_metrics.to_h { |item| [item.dig("metadata", "name"), item] }
    raw_nodes.first(NODE_NAMES.size).each_with_index.filter_map do |raw_node, index|
      item = by_real_name[raw_node.dig("metadata", "name")]
      next unless item

      name = NODE_NAMES.fetch(index)
      usage = item.fetch("usage").slice("cpu", "memory")
      usage = usage_at(nodes.first.dig("status", "allocatable"), cpu_percent: 24, memory_percent: 44) if index.zero?
      { "metadata" => { "name" => name }, "usage" => usage }
    end
  end

  def usage_at(allocatable, cpu_percent:, memory_percent:)
    cpu_millicores = allocatable.fetch("cpu").delete_suffix("m").to_i
    memory_kibibytes = allocatable.fetch("memory").delete_suffix("Ki").to_i
    { "cpu" => "#{(cpu_millicores * cpu_percent * 10_000)}n", "memory" => "#{memory_kibibytes * memory_percent / 100}Ki" }
  end

  # --- pods ------------------------------------------------------------------------------------------------------

  def namespace(real)
    return real if KEPT_NAMESPACES.include?(real)

    fake("namespace", real) do
      index = @replacements["namespace"].size
      NAMESPACES[index] || "namespace-#{index + 1}"
    end
  end

  def workload_name(real)
    fake("workload", real) do
      index = @replacements["workload"].size
      WORKLOAD_NAMES[index] || "workload-#{index + 1}"
    end
  end

  # Pod names are a workload's name plus what the controller adds: a hash and a suffix for a Deployment, an ordinal for
  # a StatefulSet, a suffix for a DaemonSet or Job.
  def pod_name(real)
    fake("pod", real) do
      candidate =
        case real
        when /\A(.+)-[a-f0-9]{6,10}-[a-z0-9]{5}\z/ then "#{workload_name(Regexp.last_match(1))}-#{hex(10)}-#{alphanumeric(5)}"
        when /\A(.+)-(\d+)\z/ then "#{workload_name(Regexp.last_match(1))}-#{Regexp.last_match(2)}"
        when /\A(.+)-[a-z0-9]{5}\z/ then "#{workload_name(Regexp.last_match(1))}-#{alphanumeric(5)}"
        else workload_name(real)
        end
      candidate = "#{candidate}-#{alphanumeric(3)}" while @taken_names.include?(candidate) || POD_NAMES_TAKEN_BY_CASES.include?(candidate)
      @taken_names << candidate
      candidate
    end
  end

  def container_name(real)
    fake("container", real) do
      index = @replacements["container"].size
      CONTAINER_NAMES[index] || "container-#{index + 1}"
    end
  end

  def image(real)
    fake("image", real) { "registry.example.com/acme/image-#{@replacements["image"].size + 1}:1.4.2" }
  end

  # Every real pod becomes a healthy one, whatever state it was in when captured.
  def scrub_pod(pod)
    status = pod.fetch("status")
    created = shift(pod.dig("metadata", "creationTimestamp"))
    conditions = status.fetch("conditions", []).to_h { |condition| [condition["type"], shift(condition["lastTransitionTime"])] }
    scrubbed = {
      "metadata" => { "namespace" => namespace(pod.dig("metadata", "namespace")), "name" => pod_name(pod.dig("metadata", "name")), "creationTimestamp" => created },
      "status" => {
        "phase" => "Running",
        "conditions" => %w[Initialized Ready ContainersReady PodScheduled].map do |type|
          { "type" => type, "status" => "True", "lastTransitionTime" => conditions[type] || created }
        end,
        "containerStatuses" => status.fetch("containerStatuses", []).map { |container| healthy_container(container, created) }
      }
    }
    init_containers = status["initContainerStatuses"]
    scrubbed["status"]["initContainerStatuses"] = init_containers.map { |container| completed_init_container(container, created) } if init_containers
    scrubbed
  end

  def healthy_container(container, created)
    {
      "name" => container_name(container["name"]),
      "ready" => true,
      "restartCount" => [container["restartCount"].to_i, HEALTHY_RESTART_LIMIT].min,
      "state" => { "running" => { "startedAt" => shift(container.dig("state", "running", "startedAt")) || created } },
      "lastState" => {},
      "image" => image(container["image"])
    }
  end

  def completed_init_container(container, created)
    finished = shift(container.dig("state", "terminated", "finishedAt")) || created
    {
      "name" => container_name(container["name"]),
      "ready" => true,
      "restartCount" => 0,
      "state" => { "terminated" => { "exitCode" => 0, "reason" => "Completed", "startedAt" => shift(container.dig("state", "terminated", "startedAt")) || created, "finishedAt" => finished } },
      "lastState" => {},
      "image" => image(container["image"])
    }
  end

  # --- synthetic cases ---------------------------------------------------------------------------------------------

  def synthetic_pods
    [
      crash_looping_pod, unschedulable_pod, out_of_memory_pod, restarted_long_ago_pod, starting_pod, failed_job_pod
    ]
  end

  def condition(type, status, time, reason: nil, message: nil)
    { "type" => type, "status" => status, "reason" => reason, "message" => message, "lastTransitionTime" => time }.compact
  end

  def ready_conditions(time)
    %w[Initialized Ready ContainersReady PodScheduled].map { |type| condition(type, "True", time) }
  end

  def synthetic_pod(namespace, name, created, status)
    { "metadata" => { "namespace" => namespace, "name" => name, "creationTimestamp" => created }, "status" => status }
  end

  def running_container(restart_count:, last_state: {}, image: "registry.example.com/acme/app:1.4.2")
    { "name" => "app", "ready" => true, "restartCount" => restart_count, "state" => { "running" => { "startedAt" => minutes_before_capture(180) } },
      "lastState" => last_state, "image" => image }
  end

  def crash_looping_pod
    name = "billing-api-7d9f6c-x2k4p"
    created = minutes_before_capture(168)
    not_ready = { "reason" => "ContainersNotReady", "message" => "containers with unready status: [app]" }
    synthetic_pod("shop", name, created, {
      "phase" => "Running",
      "conditions" => [
        condition("Initialized", "True", created), condition("PodScheduled", "True", created),
        condition("Ready", "False", minutes_before_capture(8), **not_ready.transform_keys(&:to_sym)),
        condition("ContainersReady", "False", minutes_before_capture(8), **not_ready.transform_keys(&:to_sym))
      ],
      "containerStatuses" => [{
        "name" => "app", "ready" => false, "restartCount" => 12,
        "state" => { "waiting" => { "reason" => "CrashLoopBackOff", "message" => "back-off 5m0s restarting failed container=app pod=#{name}" } },
        "lastState" => { "terminated" => { "exitCode" => 1, "reason" => "Error", "startedAt" => minutes_before_capture(9), "finishedAt" => minutes_before_capture(8) } },
        "image" => "registry.example.com/acme/billing-api:1.4.3"
      }]
    })
  end

  def unschedulable_pod
    created = minutes_before_capture(14)
    synthetic_pod("jobs", "import-28311-abcde", created, {
      "phase" => "Pending",
      "conditions" => [condition("PodScheduled", "False", created, reason: "Unschedulable", message: "0/3 nodes are available: insufficient memory")]
    })
  end

  def out_of_memory_pod
    created = minutes_before_capture(2880)
    killed = { "terminated" => { "exitCode" => 137, "reason" => "OOMKilled", "startedAt" => minutes_before_capture(180), "finishedAt" => minutes_before_capture(20) } }
    synthetic_pod("shop", "cache-0", created, {
      "phase" => "Running", "conditions" => ready_conditions(created),
      "containerStatuses" => [running_container(restart_count: 1, last_state: killed, image: "registry.example.com/acme/cache:7.2.0")]
    })
  end

  def restarted_long_ago_pod
    created = minutes_before_capture(4320)
    restarted = { "terminated" => { "exitCode" => 1, "reason" => "Error", "startedAt" => minutes_before_capture(400), "finishedAt" => minutes_before_capture(180) } }
    synthetic_pod("shop", "web-5c8d7-q9wzt", created, {
      "phase" => "Running", "conditions" => ready_conditions(created),
      "containerStatuses" => [running_container(restart_count: 7, last_state: restarted, image: "registry.example.com/acme/web:2.9.1")]
    })
  end

  def starting_pod
    created = minutes_before_capture(2)
    synthetic_pod("shop", "report-6f2b1-m3kd8", created, {
      "phase" => "Pending",
      "conditions" => [condition("Initialized", "True", created), condition("PodScheduled", "True", created),
                       condition("Ready", "False", created, reason: "ContainersNotReady", message: "containers with unready status: [app]")],
      "containerStatuses" => [{ "name" => "app", "ready" => false, "restartCount" => 0, "state" => { "waiting" => { "reason" => "ContainerCreating" } },
                                "lastState" => {}, "image" => "registry.example.com/acme/report:3.0.4" }]
    })
  end

  def failed_job_pod
    created = minutes_before_capture(540)
    synthetic_pod("batch-test", "nightly-check-29110-zz9kq", created, {
      "phase" => "Failed", "reason" => "Error",
      "conditions" => [condition("Initialized", "True", created), condition("PodScheduled", "True", created)],
      "containerStatuses" => [{
        "name" => "app", "ready" => false, "restartCount" => 0,
        "state" => { "terminated" => { "exitCode" => 1, "reason" => "Error", "startedAt" => minutes_before_capture(539), "finishedAt" => minutes_before_capture(538) } },
        "lastState" => {}, "image" => "registry.example.com/acme/nightly-check:1.0.0"
      }]
    })
  end

  # --- errors, as Kubernetes answers them (the proxy signs in as an administrator, so none can be captured) --------

  def write_errors
    write("errors/unauthorized.json", status_object(401, "Unauthorized", "Unauthorized"))
    write("errors/forbidden.json", status_object(403, "Forbidden", "nodes is forbidden: User \"system:serviceaccount:monitoring:status-reader\" cannot list resource \"nodes\" in API group \"\" at the cluster scope"))
    write("errors/not_found.json", status_object(404, "NotFound", "the server could not find the requested resource"))
    write("errors/method_not_allowed.json", status_object(405, "MethodNotAllowed", "the server does not allow this method on the requested resource"))
    write("errors/server_error.json", status_object(500, "InternalError", "Internal error occurred: an unexpected error"))
  end

  def status_object(code, reason, message)
    { "kind" => "Status", "apiVersion" => "v1", "metadata" => {}, "status" => "Failure", "message" => message, "reason" => reason, "code" => code }
  end

  # --- the check that nothing real is left ---------------------------------------------------------------------

  def check_for_survivors
    raw_strings = Dir[File.join(@raw_folder, "*.body")].flat_map { |path| strings_in(JSON.parse(File.read(path))) }
    raw_strings += @replacements.values.flat_map(&:keys)
    raw_strings = raw_strings.uniq.select { |value| value.length >= 4 } - VOCABULARY
    output = Dir[File.join(@output_folder, "**", "*.json")].map { |path| File.read(path) }.join("\n")
    survivors = raw_strings.select { |value| output.match?(whole_token(value)) }
    ignorable = survivors.select { |value| ignorable?(value) }
    real = survivors - ignorable

    replaced = @replacements.flat_map { |category, pairs| pairs.keys.map { |value| "#{category}\t#{value}" } }
    File.write(File.join(@raw_folder, "replaced.txt"), replaced.join("\n"))
    File.write(File.join(@raw_folder, "survivors.txt"), survivors.map { |value| "#{real.include?(value) ? "REAL" : "ok"}\t#{value}" }.join("\n"))
    puts "#{replaced.size} real values replaced (#{@replacements.map { |category, pairs| "#{pairs.size} #{category}" }.join(", ")})"
    puts "#{survivors.size} raw strings appear in the fixtures: #{ignorable.size} ordinary, #{real.size} not (both listed in survivors.txt in the raw folder)"
    exit(real.empty? ? 0 : 1)
  end

  # A real name only counts as surviving when it stands alone, not as a piece of a longer made-up word.
  def whole_token(value)
    /(?<![[:alnum:]_-])#{Regexp.escape(value)}(?![[:alnum:]_-])/
  end

  def strings_in(value)
    case value
    when Hash then value.values.flat_map { |nested| strings_in(nested) }
    when Array then value.flat_map { |nested| strings_in(nested) }
    when String then [value]
    else []
    end
  end

  # Timestamps, Kubernetes' own condition text and quantities name nothing of the cluster's.
  def ignorable?(value)
    value.match?(/\A\d{4}-\d{2}-\d{2}T[\d:.]+Z\z/) ||
      value.match?(/\A\d+(Ki|m|n)?\z/) ||
      value.match?(/\A(kubelet|container runtime|network) /)
  end
end

if $PROGRAM_NAME == __FILE__
  raw_folder = ARGV.fetch(0) { abort "usage: ruby script/scrub_fixtures.rb RAW_FOLDER [OUTPUT_FOLDER]" }
  output_folder = ARGV.fetch(1, File.expand_path("../test/support/fixtures/kubernetes", __dir__))
  FixtureScrubber.new(raw_folder, output_folder).run
end
