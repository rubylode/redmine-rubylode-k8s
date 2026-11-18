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

require_relative "../test_helper"

class RubylodeK8sClusterStatusTest < ActiveSupport::TestCase
  NODES = JSON.parse(File.read(File.expand_path("../support/fixtures/kubernetes/nodes.json", __dir__)))
  METRICS = JSON.parse(File.read(File.expand_path("../support/fixtures/kubernetes/node_metrics.json", __dir__)))

  test "each node becomes a row with its name and status" do
    rows = RubylodeK8s::ClusterStatus.node_rows_from(NODES)

    assert_equal %w[node-a node-b node-c node-d], rows.map(&:name)
    assert_equal %w[Ready Ready Ready NotReady], rows.map(&:status)
  end

  test "a node whose Ready condition is Unknown, and one with no Ready condition, are Unknown" do
    answer = { "items" => [
      { "metadata" => { "name" => "node-e" }, "status" => { "conditions" => [{ "type" => "Ready", "status" => "Unknown" }] } },
      { "metadata" => { "name" => "node-f" }, "status" => { "conditions" => [{ "type" => "MemoryPressure", "status" => "False" }] } },
      { "metadata" => { "name" => "node-g" }, "status" => {} }
    ] }

    assert_equal %w[Unknown Unknown Unknown], RubylodeK8s::ClusterStatus.node_rows_from(answer).map(&:status)
  end

  test "percent is usage over allocatable" do
    row = RubylodeK8s::ClusterStatus.node_rows_from(NODES, METRICS).find { |candidate| candidate.name == "node-a" }

    assert_equal 24, row.cpu_percent.round
    assert_equal 44, row.memory_percent.round
    assert_kind_of Float, row.cpu_percent
  end

  test "a node missing from the metrics answer shows no metrics while the others show bars" do
    rows = RubylodeK8s::ClusterStatus.node_rows_from(NODES, METRICS)
    missing = rows.find { |row| row.name == "node-d" }
    present = rows.find { |row| row.name == "node-a" }

    assert_nil missing.cpu_percent
    assert_nil missing.memory_percent
    assert_equal 24, present.cpu_percent.round
  end

  test "without a metrics answer no node has percents" do
    rows = RubylodeK8s::ClusterStatus.node_rows_from(NODES)

    assert_equal [nil], rows.map(&:cpu_percent).uniq
  end

  test "zero allocatable gives no percent" do
    nodes = { "items" => [{ "metadata" => { "name" => "node-e" }, "status" => { "allocatable" => { "cpu" => "0", "memory" => "1Gi" } } }] }
    metrics = { "items" => [{ "metadata" => { "name" => "node-e" }, "usage" => { "cpu" => "1", "memory" => "1Mi" } }] }
    row = RubylodeK8s::ClusterStatus.node_rows_from(nodes, metrics).first

    assert_nil row.cpu_percent
    assert row.memory_percent
  end

  test "a node with MemoryPressure True names it, and one without pressure names nothing" do
    rows = RubylodeK8s::ClusterStatus.node_rows_from(NODES)

    assert_equal ["MemoryPressure"], rows.find { |row| row.name == "node-d" }.failing_conditions
    assert_equal [], rows.find { |row| row.name == "node-a" }.failing_conditions
  end

  test "a node without a Ready condition is Unknown" do
    answer = { "items" => [{ "metadata" => { "name" => "node-h" }, "status" => { "conditions" => [] } }] }

    assert_equal "Unknown", RubylodeK8s::ClusterStatus.node_rows_from(answer).first.status
  end
  PODS = JSON.parse(File.read(File.expand_path("../support/fixtures/kubernetes/pods.json", __dir__))).fetch("items")

  def trouble_settings(namespaces_to_ignore = "")
    RubylodeK8s::Settings.new("pending_grace_minutes" => "5", "restart_threshold" => "5", "namespaces_to_ignore" => namespaces_to_ignore)
  end

  test "the pods in trouble are listed by namespace then name" do
    pods = RubylodeK8s::ClusterStatus.trouble_pods_from(PODS, now: FakeKubernetesApi::CAPTURED_AT, settings: trouble_settings)

    assert_equal [%w[batch-test nightly-check-29110-zz9kq], %w[jobs import-28311-abcde], %w[shop billing-api-7d9f6c-x2k4p], %w[shop cache-0]],
                 pods.map { |pod| [pod.namespace, pod.name] }
    assert_equal %w[Failed Pending Running Running], pods.map(&:phase)
  end

  test "an ignored namespace is never listed" do
    pods = RubylodeK8s::ClusterStatus.trouble_pods_from(PODS, now: FakeKubernetesApi::CAPTURED_AT, settings: trouble_settings("batch-test"))

    assert_equal 3, pods.size
    assert_not_includes pods.map(&:namespace), "batch-test"
  end

  test "ignored namespaces may be separated by commas, spaces or lines" do
    pods = RubylodeK8s::ClusterStatus.trouble_pods_from(PODS, now: FakeKubernetesApi::CAPTURED_AT, settings: trouble_settings("batch-test, jobs\nshop"))

    assert_empty pods
  end
  test "a percent that is not finite is no percent" do
    original = RubylodeK8s::Quantity.method(:parse)
    RubylodeK8s::Quantity.define_singleton_method(:parse) { |text| text == "huge" ? Rational(10**400) : Rational(1) }
    nodes = { "items" => [{ "metadata" => { "name" => "node-e" }, "status" => { "allocatable" => { "cpu" => "1", "memory" => "1" } } }] }
    metrics = { "items" => [{ "metadata" => { "name" => "node-e" }, "usage" => { "cpu" => "huge", "memory" => "1" } }] }
    row = RubylodeK8s::ClusterStatus.node_rows_from(nodes, metrics).first

    assert_nil row.cpu_percent
    assert_equal 100.0, row.memory_percent
  ensure
    RubylodeK8s::Quantity.define_singleton_method(:parse) { |*arguments| original.call(*arguments) }
  end

  test "a metrics answer of the wrong shape gives no percents and no error" do
    [[], { "kind" => "NodeMetricsList" }, { "items" => "no" }, { "items" => [1, nil, { "metadata" => "x", "usage" => 5 }] }].each do |answer|
      rows = RubylodeK8s::ClusterStatus.node_rows_from(NODES, answer)

      assert_equal 4, rows.size
      assert_equal [nil], rows.map(&:cpu_percent).uniq
    end
  end

  def summary_text(**counts)
    defaults = { node_count: 3, not_ready_count: 0, trouble_count: 0, pods_unchecked_cluster_count: 0, unavailable_cluster_count: 0 }
    RubylodeK8s::ClusterStatus::Summary.new(**defaults.merge(counts)).text
  end

  def report_with(**fields)
    node_rows = fields.delete(:node_rows) || [RubylodeK8s::ClusterStatus::NodeRow.new(name: "node-a", status: "Ready", failing_conditions: [])]
    RubylodeK8s::ClusterStatus::Report.new(node_rows: node_rows, trouble_pods: [], more_trouble_count: 0, unavailable: false, **fields)
  end

  test "the summary says" do
    assert_equal "All 3 nodes ready, no pods in trouble", summary_text
    assert_equal "1 of 3 nodes not ready, 2 pods in trouble", summary_text(not_ready_count: 1, trouble_count: 2)
    assert_equal "All 3 nodes ready, 2 pods in trouble", summary_text(trouble_count: 2)
    assert_equal "All 1 node ready, 1 pod in trouble", summary_text(node_count: 1, trouble_count: 1)
  end

  test "the summary state is trouble, unavailable, no nodes or all fine" do
    assert_equal :all_fine, RubylodeK8s::ClusterStatus::Summary.new(node_count: 3, not_ready_count: 0, trouble_count: 0, pods_unchecked_cluster_count: 0, unavailable_cluster_count: 0).state
    assert_equal :trouble, RubylodeK8s::ClusterStatus::Summary.new(node_count: 3, not_ready_count: 1, trouble_count: 0, pods_unchecked_cluster_count: 0, unavailable_cluster_count: 1).state
    assert_equal :unavailable, RubylodeK8s::ClusterStatus::Summary.new(node_count: 3, not_ready_count: 0, trouble_count: 0, pods_unchecked_cluster_count: 0, unavailable_cluster_count: 1).state
    assert_equal :no_nodes, RubylodeK8s::ClusterStatus::Summary.new(node_count: 0, not_ready_count: 0, trouble_count: 0, pods_unchecked_cluster_count: 0, unavailable_cluster_count: 0).state
  end

  test "nodes that are fine with pods unchecked are unavailable, not all fine" do
    summary = RubylodeK8s::ClusterStatus::Summary.new(node_count: 3, not_ready_count: 0, trouble_count: 0, pods_unchecked_cluster_count: 1, unavailable_cluster_count: 0)

    assert_equal :unavailable, summary.state
  end

  test "no nodes with one cluster unavailable is unavailable, not no nodes" do
    summary = RubylodeK8s::ClusterStatus.summary_for([RubylodeK8s::ClusterStatus::Report.unavailable_because("Timeout")])

    assert_equal 0, summary.node_count
    assert_equal :unavailable, summary.state
  end

  test "an unavailable cluster is not counted, and the summary says so" do
    reports = [report_with, RubylodeK8s::ClusterStatus::Report.unavailable_because("Timeout")]
    summary = RubylodeK8s::ClusterStatus.summary_for(reports)

    assert_equal 1, summary.node_count
    assert_equal 1, summary.unavailable_cluster_count
    assert_equal "All 1 node ready, no pods in trouble. 1 cluster unavailable", summary.text
    assert_equal "2 clusters unavailable", RubylodeK8s::ClusterStatus.summary_for([RubylodeK8s::ClusterStatus::Report.unavailable_because("a"), RubylodeK8s::ClusterStatus::Report.unavailable_because("b")]).text
  end

  test "trouble beyond the listed pods is counted, and not ready includes Unknown" do
    nodes = [RubylodeK8s::ClusterStatus::NodeRow.new(name: "node-a", status: "Unknown", failing_conditions: []),
             RubylodeK8s::ClusterStatus::NodeRow.new(name: "node-b", status: "Ready", failing_conditions: [])]
    pod = RubylodeK8s::ClusterStatus::TroublePod.new(namespace: "apps", name: "web", phase: "Pending", reason: "Pending")
    summary = RubylodeK8s::ClusterStatus.summary_for([report_with(node_rows: nodes, trouble_pods: [pod], more_trouble_count: 14)])

    assert_equal "1 of 2 nodes not ready, 15 pods in trouble", summary.text
  end

  test "pods not checked are said, never counted as none in trouble" do
    unchecked = report_with(pods_failure_reason: "Kubernetes answered 500")
    truncated = report_with(pods_truncated: true, pods_checked_count: 5000)
    pod = RubylodeK8s::ClusterStatus::TroublePod.new(namespace: "apps", name: "web", phase: "Pending", reason: "Pending")

    assert_equal "All 1 node ready, pods not checked on 1 cluster", RubylodeK8s::ClusterStatus.summary_for([unchecked]).text
    assert_equal "All 2 nodes ready, pods not checked on 2 clusters", RubylodeK8s::ClusterStatus.summary_for([unchecked, truncated]).text
    assert_equal "All 1 node ready, 1 pod in trouble, pods not checked on 1 cluster",
                 RubylodeK8s::ClusterStatus.summary_for([report_with(pods_failure_reason: "x", trouble_pods: [pod])]).text
  end

  test "nodes that are not ready come first, then by name" do
    nodes = RubylodeK8s::ClusterStatus.node_rows_from(NODES)

    assert_equal %w[node-d node-a node-b node-c], nodes.sort_by { |row| RubylodeK8s::ClusterStatus.node_order_key(row) }.map(&:name)
    unknown = { "items" => [{ "metadata" => { "name" => "node-0" }, "status" => {} }, { "metadata" => { "name" => "node-z" }, "status" => { "conditions" => [{ "type" => "Ready", "status" => "False" }] } },
                            { "metadata" => { "name" => "node-b" }, "status" => { "conditions" => [{ "type" => "Ready", "status" => "True" }] } }] }
    assert_equal %w[node-0 node-z node-b], RubylodeK8s::ClusterStatus.node_rows_from(unknown).sort_by { |row| RubylodeK8s::ClusterStatus.node_order_key(row) }.map(&:name)
  end
end
