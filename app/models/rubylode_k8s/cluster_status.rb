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

require "digest"

module RubylodeK8s
  # A cluster's node list in, one row per node out.
  class ClusterStatus
    NodeRow = Struct.new(:name, :status, :failing_conditions, :cpu_percent, :memory_percent, keyword_init: true)

    # One pod in trouble, with what the rule found. The times are Time or nil.
    TroublePod = Struct.new(:namespace, :name, :phase, :reason, :message, :restart_count, :last_restart_at, :pending_since, keyword_init: true) do
      # The detail column: "12 restarts, the last 8 min ago", "Pending 14 min" (hours and days past an hour and a day), then the message Kubernetes gave.
      def detail(now)
        parts = []
        parts << restart_detail(now) if restart_count.to_i.positive?
        parts << I18n.t("rubylode_k8s.detail.pending", duration: elapsed(pending_since, now)) if pending_since
        parts << message.to_s unless message.to_s.empty?
        parts.join("; ")
      end

      private

      def restart_detail(now)
        text = I18n.t("rubylode_k8s.detail.restarts", count: restart_count)
        return text unless last_restart_at

        "#{text}, #{I18n.t('rubylode_k8s.detail.last_restart', duration: elapsed(last_restart_at, now))}"
      end

      def elapsed(time, now)
        ElapsedTime.short(now - time)
      end
    end
    # Most pods in trouble that are listed; the rest are counted ("and 14 more").
    TROUBLE_LIST_LIMIT = 20

    # What one cluster's section shows: its node rows, or the reason it could not be asked. The pod and metrics fields
    # are filled by later slices. Cached as a plain hash, never as the raw answers.
    Report = Struct.new(:node_rows, :trouble_pods, :more_trouble_count, :pods_truncated, :pods_checked_count, :pods_failure_reason,
                        :metrics_available, :metrics_failure_reason, :unavailable, :failure_reason, keyword_init: true) do
      alias_method :unavailable?, :unavailable

      def self.unavailable_because(reason)
        new(node_rows: [], trouble_pods: [], unavailable: true, failure_reason: reason)
      end

      def to_cache
        to_h.transform_keys(&:to_s).merge("node_rows" => node_rows.map { |row| row.to_h.transform_keys(&:to_s) },
                                          "trouble_pods" => Array(trouble_pods).map { |pod| pod.to_h.transform_keys(&:to_s) })
      end

      def self.from_cache(hash)
        values = hash.transform_keys(&:to_sym)
        values[:node_rows] = values.fetch(:node_rows, []).map { |row| NodeRow.new(**row.transform_keys(&:to_sym)) }
        values[:trouble_pods] = values.fetch(:trouble_pods, nil).to_a.map { |pod| TroublePod.new(**pod.transform_keys(&:to_sym)) }
        new(**values)
      end
    end

    # What the block says in one line, over every cluster that answered.
    Summary = Struct.new(:node_count, :not_ready_count, :trouble_count, :pods_unchecked_cluster_count, :unavailable_cluster_count, keyword_init: true) do
      def state
        if not_ready_count.to_i.positive? || trouble_count.to_i.positive? then :trouble
        elsif unavailable_cluster_count.to_i.positive? || pods_unchecked_cluster_count.to_i.positive? then :unavailable
        elsif node_count.to_i.zero? then :no_nodes
        else :all_fine
        end
      end

      # Node part, then pod part, joined by a comma; unavailable clusters after a full stop. Pods that could not be
      # checked (or only in part) are said, and never counted as none in trouble.
      def text
        parts = [node_part, pod_part].compact
        sentence = parts.join(", ")
        return unavailable_part if sentence.empty?

        unavailable_cluster_count.to_i.positive? ? "#{sentence}. #{unavailable_part}" : sentence
      end

      private

      def node_part
        return I18n.t("rubylode_k8s.summary.no_nodes") if node_count.to_i.zero? && unavailable_cluster_count.to_i.zero?
        return nil if node_count.to_i.zero?

        if not_ready_count.to_i.positive?
          I18n.t("rubylode_k8s.summary.nodes_not_ready", count: node_count, not_ready: not_ready_count)
        else
          I18n.t("rubylode_k8s.summary.nodes_ready", count: node_count)
        end
      end

      def pod_part
        return nil if node_count.to_i.zero?

        unchecked = I18n.t("rubylode_k8s.summary.pods_not_checked", count: pods_unchecked_cluster_count) if pods_unchecked_cluster_count.to_i.positive?
        if trouble_count.to_i.positive?
          [I18n.t("rubylode_k8s.summary.pods_in_trouble", count: trouble_count), unchecked].compact.join(", ")
        else
          unchecked || I18n.t("rubylode_k8s.summary.no_pods_in_trouble")
        end
      end

      def unavailable_part
        I18n.t("rubylode_k8s.summary.clusters_unavailable", count: unavailable_cluster_count)
      end
    end

    READY_STATUSES = { "True" => "Ready", "False" => "NotReady" }.freeze
    UNKNOWN_STATUS = "Unknown".freeze

    class << self
      attr_writer :cache

      def cache
        @cache ||= Rails.cache
      end
    end

    # Every error is the plugin's own failure (an unavailable cluster, metrics or pods), except the time limit of
    # whoever asked for the block (see CallerDeadline): that one goes on to the caller and nothing is cached for it.
    # Only Unavailable carries a message, already scrubbed of the token; anything else is named by its class alone.

    # The report of one cluster. Its API is asked at most once per Cache seconds, and after a failure not again for
    # Failure cache seconds. When anything fails, the answer is an unavailable report and never an error; only a
    # caller's time limit is raised.
    def self.report_for(cluster, settings = Settings.current)
      cached = read_cache(cluster)
      return Report.from_cache(cached) if cached

      fetch_and_cache(cluster, settings)
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      Rails.logger.warn("Rubylode Kubernetes: could not build the section for #{cluster.name}: #{error.class}")
      Report.unavailable_because(failure_reason_for(error))
    end

    # Any failure is cached as one, for Failure cache seconds. A caller's time limit is not a failure and caches nothing.
    def self.fetch_and_cache(cluster, settings)
      client = KubernetesClient.new(cluster: cluster, timeout_seconds: settings.timeout_seconds)
      nodes_answer = client.nodes
      metrics_answer, metrics_failure_reason = metrics_from(client)
      pod_list, pods_failure_reason = pods_from(client)
      report = Report.new(node_rows: sorted_node_rows(nodes_answer, metrics_answer), unavailable: false,
                          metrics_available: !metrics_answer.nil?, metrics_failure_reason: metrics_failure_reason,
                          **pod_fields_from(pod_list, pods_failure_reason, settings))
      write_cache(cluster, report, settings.cache_seconds)
      report
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      Rails.logger.warn("Rubylode Kubernetes: could not fetch #{cluster.name}: #{error.class}")
      report = Report.unavailable_because(failure_reason_for(error))
      write_cache(cluster, report, settings.failure_cache_seconds)
      report
    end
    private_class_method :fetch_and_cache

    # The message of Unavailable (already scrubbed of the token), or the class name of anything else, whose message
    # could carry the token.
    def self.failure_reason_for(error)
      error.is_a?(KubernetesClient::Unavailable) ? error.message : error.class.name
    end
    private_class_method :failure_reason_for

    # The node rows, not ready first. Nodes that cannot be read make the answer unreadable, named by the error's class.
    def self.sorted_node_rows(nodes_answer, metrics_answer)
      node_rows_from(nodes_answer, metrics_answer).sort_by { |row| node_order_key(row) }
    rescue KubernetesClient::Unavailable
      raise
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      raise KubernetesClient::Unavailable, I18n.t("rubylode_k8s.errors.answer_unreadable_because", error_class: error.class)
    end
    private_class_method :sorted_node_rows

    # The node metrics answer and nil, or nil and why there is none. Missing metrics never make the cluster unavailable:
    # the nodes still show, with "no metrics" in place of the bars.
    def self.metrics_from(client)
      [client.node_metrics, nil]
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      reason = failure_reason_for(error)
      Rails.logger.warn("Rubylode Kubernetes: no node metrics: #{reason}")
      [nil, reason]
    end
    private_class_method :metrics_from

    # The pod list and nil, or nil and why there is none. Missing pods never make the cluster unavailable: the nodes
    # still show, and the page says the pods were not checked.
    def self.pods_from(client)
      [client.pods, nil]
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      reason = failure_reason_for(error)
      Rails.logger.warn("Rubylode Kubernetes: no pods: #{reason}")
      [nil, reason]
    end
    private_class_method :pods_from

    # The pod fields of a report: the first TROUBLE_LIST_LIMIT pods in trouble, how many more there are, and whether the
    # list was cut short.
    def self.pod_fields_from(pod_list, failure_reason, settings)
      return { trouble_pods: [], more_trouble_count: 0, pods_truncated: false, pods_failure_reason: failure_reason } if pod_list.nil?

      trouble = trouble_pods_from(pod_list.items, now: Time.current, settings: settings)
      { trouble_pods: trouble.first(TROUBLE_LIST_LIMIT), more_trouble_count: [trouble.size - TROUBLE_LIST_LIMIT, 0].max,
        pods_truncated: pod_list.truncated, pods_checked_count: pod_list.items.size }
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      Rails.logger.warn("Rubylode Kubernetes: pods could not be read: #{error.class}")
      { trouble_pods: [], more_trouble_count: 0, pods_truncated: false, pods_failure_reason: error.class.name }
    end
    private_class_method :pod_fields_from

    def self.phase_of(pod)
      status = pod["status"]
      status.is_a?(Hash) ? status["phase"].to_s : ""
    end
    private_class_method :phase_of

    # Every pod in trouble, by namespace then name, leaving out the namespaces the settings ignore.
    def self.trouble_pods_from(pods, now:, settings:)
      ignored = settings.namespaces_to_ignore
      pods.filter_map do |pod|
        next unless pod.is_a?(Hash)

        metadata = pod["metadata"].is_a?(Hash) ? pod["metadata"] : {}
        namespace = metadata["namespace"].to_s
        next if ignored.include?(namespace)

        trouble = TroubleRule.trouble_for(pod, now: now, pending_grace_minutes: settings.pending_grace_minutes,
                                               restart_threshold: settings.restart_threshold)
        next unless trouble

        TroublePod.new(namespace: namespace, name: metadata["name"].to_s, phase: phase_of(pod), **trouble)
      end.sort_by { |trouble_pod| [trouble_pod.namespace, trouble_pod.name] }
    end

    # The summary of the reports of all clusters. An unavailable cluster is counted only as unavailable. Pods in trouble
    # include those beyond the listed ones; a cluster whose pods could not be read, or only in part, is unchecked.
    def self.summary_for(reports)
      answered, unavailable = reports.partition { |report| !report.unavailable? }
      rows = answered.flat_map(&:node_rows)
      Summary.new(node_count: rows.size, not_ready_count: rows.count { |row| row.status != "Ready" },
                  trouble_count: answered.sum { |report| Array(report.trouble_pods).size + report.more_trouble_count.to_i },
                  pods_unchecked_cluster_count: answered.count { |report| report.pods_failure_reason.present? || report.pods_truncated },
                  unavailable_cluster_count: unavailable.size)
    end

    # Sorts nodes that are not ready (NotReady and Unknown) first, then by name.
    def self.node_order_key(row)
      [row.status == "Ready" ? 1 : 0, row.name]
    end

    # Drops what is cached for these clusters, so the next load asks Kubernetes again.
    def self.forget(clusters)
      clusters.each { |cluster| cache.delete(cache_key_for(cluster)) }
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      Rails.logger.warn("Rubylode Kubernetes: cache clear failed: #{error.class}")
    end

    # A cache that cannot be read or written is a miss, not an error, unless the caller's time limit struck meanwhile.
    # A time of 0 means no caching at all.
    def self.read_cache(cluster)
      cache.read(cache_key_for(cluster))
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      Rails.logger.warn("Rubylode Kubernetes: cache read failed, carrying on without it: #{error.class}")
      nil
    end
    private_class_method :read_cache

    def self.write_cache(cluster, report, seconds)
      return unless seconds.positive?

      cache.write(cache_key_for(cluster), report.to_cache, expires_in: seconds)
    rescue StandardError => error
      raise if CallerDeadline.raised?(error)

      Rails.logger.warn("Rubylode Kubernetes: cache write failed, carrying on without it: #{error.class}")
    end
    private_class_method :write_cache

    # Two tokens on one address may see different things, so both are part of the key.
    def self.cache_key_for(cluster)
      identity = [cluster.address, cluster.token_variable, cluster.certificate_authority_variable, cluster.in_cluster].join("|")
      "rubylode_k8s/nodes/#{Digest::SHA256.hexdigest(identity)[0, 16]}"
    end

    PRESSURE_CONDITIONS = %w[MemoryPressure DiskPressure PIDPressure NetworkUnavailable].freeze

    # One row per node of the node list. The metrics answer (nil when there is none) gives each node its percents; a
    # node missing from it has none.
    def self.node_rows_from(nodes_answer, metrics_answer = nil)
      usage_by_name = usage_by_name_from(metrics_answer)
      Array(nodes_answer["items"]).map do |node|
        name = node.dig("metadata", "name").to_s
        allocatable = node.dig("status", "allocatable")
        usage = usage_by_name[name]
        usage = nil unless usage.is_a?(Hash)
        NodeRow.new(name: name, status: status_of(node), failing_conditions: failing_conditions_of(node),
                    cpu_percent: percent_of(usage && usage["cpu"], allocatable && allocatable["cpu"]),
                    memory_percent: percent_of(usage && usage["memory"], allocatable && allocatable["memory"]))
      end
    end

    def self.usage_by_name_from(metrics_answer)
      items = metrics_answer.is_a?(Hash) && metrics_answer["items"].is_a?(Array) ? metrics_answer["items"] : []
      items.grep(Hash).to_h { |item| [(item["metadata"].is_a?(Hash) ? item["metadata"]["name"] : nil).to_s, item["usage"]] }
    end
    private_class_method :usage_by_name_from

    # Usage over allocatable, as kubectl top node does, as a Float; nil when either side is missing, the total is zero or
    # the result is not finite.
    def self.percent_of(usage_text, allocatable_text)
      usage = Quantity.parse(usage_text)
      allocatable = Quantity.parse(allocatable_text)
      return nil if usage.nil? || allocatable.nil? || allocatable.zero?

      percent = (usage / allocatable * 100).to_f
      percent.finite? ? percent : nil
    end
    private_class_method :percent_of

    def self.failing_conditions_of(node)
      active = Array(node.dig("status", "conditions")).select { |condition| condition["status"] == "True" }.map { |condition| condition["type"] }
      PRESSURE_CONDITIONS & active
    end
    private_class_method :failing_conditions_of

    # The Ready condition: "True" is Ready, "False" is NotReady, "Unknown" or no condition is Unknown.
    def self.status_of(node)
      ready = Array(node.dig("status", "conditions")).find { |condition| condition["type"] == "Ready" }
      READY_STATUSES.fetch(ready && ready["status"], UNKNOWN_STATUS)
    end
    private_class_method :status_of
  end
end
