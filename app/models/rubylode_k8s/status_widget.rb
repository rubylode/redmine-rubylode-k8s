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

module RubylodeK8s
  # What the Kubernetes block hands to Rubylode Status: a state (ok, warning, down or unknown), a one-line summary and one
  # item per cluster. See the Status plugin's docs/widget-contract.md. Works without the Status plugin; then nothing is
  # registered.
  module StatusWidget
    KEY = "k8s".freeze
    PAGE_PATH = "/status/k8s".freeze
    PARTIAL = "rubylode_k8s/status".freeze
    WORSE_FIRST = %w[down warning unknown ok].freeze

    class << self
      def status_plugin_present?
        defined?(RubylodeStatus::Registry) ? true : false
      end

      # Called once every plugin has loaded (see init.rb). Returns whether the widget was registered.
      def register
        return false unless status_plugin_present?

        RubylodeStatus::Registry.register(
          key: KEY,
          title: -> { RubylodeK8s::Settings.current.block_title },
          path: PAGE_PATH,
          data: -> { data },
          partial: PARTIAL,
          visibility: -> { RubylodeK8s::Settings.current.visibility }
        )
        true
      end

      def data(settings = RubylodeK8s::Settings.current)
        clusters = settings.clusters
        return { state: "unknown", summary: I18n.t("rubylode_k8s.status.not_set_up"), items: [] } if clusters.empty?

        reports = clusters.map { |cluster| [cluster, RubylodeK8s::ClusterStatus.report_for(cluster, settings)] }
        items = reports.map { |cluster, report| item_for(cluster, report) }.sort_by { |item| WORSE_FIRST.index(item[:state]) }
        { state: block_state(items), summary: RubylodeK8s::ClusterStatus.summary_for(reports.map(&:last)).text, items: items }
      end

      private

      # Down when a node is not Ready; a warning when pods are in trouble or were not checked; unknown when the cluster
      # could not be asked or has no nodes. Missing metrics are said in the detail but leave the state alone: running
      # without metrics-server is fine. The detail says what made it so.
      def item_for(cluster, report)
        return { name: cluster.name, state: "unknown", detail: I18n.t("rubylode_k8s.status.unavailable") } if report.unavailable?
        return { name: cluster.name, state: "unknown", detail: I18n.t("rubylode_k8s.summary.no_nodes") } if report.node_rows.empty?

        not_ready = report.node_rows.count { |row| row.status != "Ready" }
        trouble = Array(report.trouble_pods).size + report.more_trouble_count.to_i
        pods_unchecked = report.pods_failure_reason.present? || report.pods_truncated
        problems = []
        problems << I18n.t("rubylode_k8s.summary.nodes_not_ready", count: report.node_rows.size, not_ready: not_ready) if not_ready.positive?
        problems << I18n.t("rubylode_k8s.summary.pods_in_trouble", count: trouble) if trouble.positive?
        problems << I18n.t("rubylode_k8s.widget.pods_not_checked") if pods_unchecked
        state = if not_ready.positive? then "down"
        elsif problems.any? then "warning"
        else "ok"
        end
        parts = report.metrics_available ? problems : problems + [I18n.t("rubylode_k8s.status.no_metrics")]
        { name: cluster.name, state: state, detail: parts.empty? ? nil : parts.join(", ") }
      end

      # The worst item decides. A cluster that could not be asked makes a block that is otherwise fine a warning: nothing
      # can be said about it. Only when no cluster reports anything is the block unknown.
      def block_state(items)
        states = items.map { |item| item[:state] }
        return "down" if states.include?("down")
        return "warning" if states.include?("warning")
        return "unknown" if states.all?("unknown")

        states.include?("unknown") ? "warning" : "ok"
      end
    end
  end
end
