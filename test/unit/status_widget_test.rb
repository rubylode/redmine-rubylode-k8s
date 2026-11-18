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
require_relative "../test_helper"

class RubylodeK8sStatusWidgetTest < ActiveSupport::TestCase
  include RubylodeK8sTestHelpers

  setup do
    use_memory_cache
    start_fake_kubernetes
  end

  teardown do
    stop_fake_kubernetes
    restore_cache
  end

  # The fixture's node list with every node Ready.
  def nodes_all_ready
    answer = JSON.parse(File.read(File.expand_path("../support/fixtures/kubernetes/nodes.json", __dir__)))
    answer["items"].each do |node|
      node["status"]["conditions"].each { |condition| condition["status"] = "True" if condition["type"] == "Ready" }
    end
    answer
  end

  def without_pods_in_trouble
    { "kind" => "PodList", "apiVersion" => "v1", "metadata" => {}, "items" => [] }
  end

  def a_fine_cluster(fake)
    fake.nodes_answer = nodes_all_ready
    fake.pods_answer = without_pods_in_trouble
  end

  test "a cluster with a NotReady node is down" do
    data = RubylodeK8s::StatusWidget.data

    assert_equal "down", data[:state]
    assert_equal "1 of 4 nodes not ready, 4 pods in trouble", data[:summary]
    assert_equal [{ name: "Production", state: "down", detail: "1 of 4 nodes not ready, 4 pods in trouble" }], data[:items]
  end

  test "a cluster whose nodes and pods are fine is ok" do
    a_fine_cluster(@fake_kubernetes)
    data = RubylodeK8s::StatusWidget.data

    assert_equal "ok", data[:state]
    assert_equal "All 4 nodes ready, no pods in trouble", data[:summary]
    assert_equal [{ name: "Production", state: "ok", detail: nil }], data[:items]
  end

  test "pods in trouble alone make a warning" do
    @fake_kubernetes.nodes_answer = nodes_all_ready
    data = RubylodeK8s::StatusWidget.data

    assert_equal "warning", data[:state]
    assert_equal [{ name: "Production", state: "warning", detail: "4 pods in trouble" }], data[:items]
  end

  test "pods that could not be checked alone make a warning" do
    a_fine_cluster(@fake_kubernetes)
    @fake_kubernetes.forbidden_paths = ["/api/v1/pods"]
    data = RubylodeK8s::StatusWidget.data

    assert_equal "warning", data[:state]
    assert_equal [{ name: "Production", state: "warning", detail: "pods not checked" }], data[:items]
  end

  test "metrics missing alone are ok, and the detail says no metrics" do
    a_fine_cluster(@fake_kubernetes)
    @fake_kubernetes.metrics_missing = true
    data = RubylodeK8s::StatusWidget.data

    assert_equal "ok", data[:state]
    assert_equal [{ name: "Production", state: "ok", detail: "no metrics" }], data[:items]
  end

  test "metrics missing with pods unchecked is a warning, and the detail says both" do
    a_fine_cluster(@fake_kubernetes)
    @fake_kubernetes.metrics_missing = true
    @fake_kubernetes.forbidden_paths = ["/api/v1/pods"]
    data = RubylodeK8s::StatusWidget.data

    assert_equal [{ name: "Production", state: "warning", detail: "pods not checked, no metrics" }], data[:items]
  end

  test "a caller's time limit during the nodes, metrics or pods reaches the caller and caches nothing" do
    with_caller_deadline_registered do
      { "nodes" => 1, "metrics" => 2, "pods" => 3 }.each do |step, call_number|
        RubylodeK8s::ClusterStatus.cache.clear
        assert_raises(CallerDeadlineForTest, step) do
          raising_on_call(call_number, CallerDeadlineForTest) { RubylodeK8s::StatusWidget.data }
        end
        assert_nil cached_report_for_first_cluster, step
      end
    end

    data = RubylodeK8s::StatusWidget.data
    assert_equal [{ name: "Production", state: "down", detail: "1 of 4 nodes not ready, 4 pods in trouble" }], data[:items]
  end

  test "a caller's time limit while the rows are built reaches the caller and caches nothing" do
    with_caller_deadline_registered do
      replacing_method(RubylodeK8s::ClusterStatus, :node_rows_from, ->(*) { raise CallerDeadlineForTest }) do
        assert_raises(CallerDeadlineForTest) { RubylodeK8s::StatusWidget.data }
      end
    end

    assert_nil cached_report_for_first_cluster
  end

  test "a caller's time limit while the cache is read reaches the caller, and Kubernetes is not asked" do
    cache = RubylodeK8s::ClusterStatus.cache
    with_caller_deadline_registered do
      replacing_method(cache, :read, ->(*) { raise CallerDeadlineForTest }) do
        assert_raises(CallerDeadlineForTest) { RubylodeK8s::StatusWidget.data }
      end
    end

    assert_nil cached_report_for_first_cluster
    assert_empty @fake_kubernetes.seen_requests
  end

  test "a caller's time limit while the cache is written reaches the caller and caches nothing" do
    cache = RubylodeK8s::ClusterStatus.cache
    with_caller_deadline_registered do
      replacing_method(cache, :write, ->(*) { raise CallerDeadlineForTest }) do
        assert_raises(CallerDeadlineForTest) { RubylodeK8s::StatusWidget.data }
      end
    end

    assert_nil cached_report_for_first_cluster
  end

  test "a caller's time limit while the cache is cleared reaches the caller" do
    with_caller_deadline_registered do
      replacing_method(RubylodeK8s::ClusterStatus.cache, :delete, ->(*) { raise CallerDeadlineForTest }) do
        assert_raises(CallerDeadlineForTest) { RubylodeK8s::ClusterStatus.forget(RubylodeK8s::Settings.current.clusters) }
      end
    end
  end

  test "a cache that fails to read, write or clear otherwise is a miss, and the block still answers" do
    cache = RubylodeK8s::ClusterStatus.cache
    failing = ->(*) { raise IOError, "cache down" }
    replacing_method(cache, :read, failing) do
      replacing_method(cache, :write, failing) do
        replacing_method(cache, :delete, failing) do
          RubylodeK8s::ClusterStatus.forget(RubylodeK8s::Settings.current.clusters)
          data = RubylodeK8s::StatusWidget.data

          assert_equal [{ name: "Production", state: "down", detail: "1 of 4 nodes not ready, 4 pods in trouble" }], data[:items]
        end
      end
    end
  end

  test "an unexpected error during the nodes makes the cluster unknown, never raises, and is cached as a failure" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "failure_cache_seconds" => "60")
    [TypeError, UnexpectedErrorForTest].each do |error_class|
      RubylodeK8s::ClusterStatus.cache.clear
      data = raising_on_call(1, error_class) { RubylodeK8s::StatusWidget.data }

      assert_equal [{ name: "Production", state: "unknown", detail: "Status unavailable" }], data[:items], error_class.name
      assert cached_report_for_first_cluster["unavailable"], error_class.name
      assert_includes cached_report_for_first_cluster["failure_reason"], error_class.name
      refute_includes cached_report_for_first_cluster["failure_reason"], FakeKubernetesApi::TOKEN
    end
  end

  test "an unexpected error during the metrics or pods only leaves that part out" do
    a_fine_cluster(@fake_kubernetes)
    data = raising_on_call(2, UnexpectedErrorForTest) { RubylodeK8s::StatusWidget.data }
    assert_equal [{ name: "Production", state: "ok", detail: "no metrics" }], data[:items]

    RubylodeK8s::ClusterStatus.cache.clear
    data = raising_on_call(3, UnexpectedErrorForTest) { RubylodeK8s::StatusWidget.data }
    assert_equal [{ name: "Production", state: "warning", detail: "pods not checked" }], data[:items]
  end

  test "an unexpected error while the rows or the pods are read makes that part unreadable and never raises" do
    replacing_method(RubylodeK8s::ClusterStatus, :node_rows_from, ->(*) { raise UnexpectedErrorForTest }) do
      data = RubylodeK8s::StatusWidget.data
      assert_equal [{ name: "Production", state: "unknown", detail: "Status unavailable" }], data[:items]
    end
    assert_match(/could not be read \(.*UnexpectedErrorForTest\)/, cached_report_for_first_cluster["failure_reason"])

    RubylodeK8s::ClusterStatus.cache.clear
    a_fine_cluster(@fake_kubernetes)
    replacing_method(RubylodeK8s::ClusterStatus, :trouble_pods_from, ->(*, **) { raise TypeError }) do
      data = RubylodeK8s::StatusWidget.data
      assert_equal [{ name: "Production", state: "warning", detail: "pods not checked" }], data[:items]
    end
  end

  test "the plugin's own failures still never raise, and are cached as failures" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "failure_cache_seconds" => "60")
    @fake_kubernetes.failure = "server_error"
    data = RubylodeK8s::StatusWidget.data

    assert_equal [{ name: "Production", state: "unknown", detail: "Status unavailable" }], data[:items]
    assert cached_report_for_first_cluster["unavailable"]
  end

  test "a cluster without nodes is unknown" do
    @fake_kubernetes.nodes_answer = { "kind" => "NodeList", "items" => [] }
    data = RubylodeK8s::StatusWidget.data

    assert_equal "unknown", data[:state]
    assert_equal [{ name: "Production", state: "unknown", detail: "No nodes found" }], data[:items]
  end

  test "the block reports the worst cluster, and the worst cluster comes first" do
    a_fine_cluster(@fake_kubernetes)
    second = FakeKubernetesApi.new.start
    configure_plugin("clusters" => "Staging | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}\n" \
                                   "Production | #{second.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}")
    data = RubylodeK8s::StatusWidget.data

    assert_equal "down", data[:state]
    assert_equal %w[Production Staging], data[:items].map { |item| item[:name] }
    assert_equal %w[down ok], data[:items].map { |item| item[:state] }
  ensure
    second&.stop
  end

  test "an unavailable cluster is unknown, the block a warning when another is fine" do
    a_fine_cluster(@fake_kubernetes)
    second = FakeKubernetesApi.new(failure: "server_error").start
    configure_plugin("clusters" => "Staging | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}\n" \
                                   "Production | #{second.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}")
    data = RubylodeK8s::StatusWidget.data

    assert_equal "warning", data[:state]
    assert_equal({ name: "Production", state: "unknown", detail: "Status unavailable" }, data[:items].first)
    assert_equal "All 4 nodes ready, no pods in trouble. 1 cluster unavailable", data[:summary]
  ensure
    second&.stop
  end

  test "when no cluster can be asked the block is unknown" do
    @fake_kubernetes.failure = "server_error"
    data = RubylodeK8s::StatusWidget.data

    assert_equal "unknown", data[:state]
    assert_equal [{ name: "Production", state: "unknown", detail: "Status unavailable" }], data[:items]
  end

  test "without clusters the block is unknown and not set up" do
    configure_plugin("clusters" => "")
    data = RubylodeK8s::StatusWidget.data

    assert_equal "unknown", data[:state]
    assert_equal "Kubernetes is not set up yet", data[:summary]
    assert_empty data[:items]
  end

  test "registering passes the key, path and partial" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "block_title" => "Our clusters", "visibility" => "admins")
    with_fake_status_registry do |registry|
      assert RubylodeK8s::StatusWidget.register

      call = registry.calls.fetch(0)
      assert_equal "k8s", call[:key]
      assert_equal "/status/k8s", call[:path]
      assert_equal "rubylode_k8s/status", call[:partial]
      assert_equal "Our clusters", call[:title].call
      assert_equal "admins", call[:visibility].call
      assert_equal RubylodeK8s::StatusWidget.data, call[:data].call
    end
  end

  test "registration is skipped when the Status plugin is not there" do
    refute defined?(RubylodeStatus::Registry)
    refute RubylodeK8s::StatusWidget.register
  end

  test "the Status plugin counts as present exactly when its registry is defined" do
    refute RubylodeK8s::StatusWidget.status_plugin_present?
    with_fake_status_registry { assert RubylodeK8s::StatusWidget.status_plugin_present? }
    refute RubylodeK8s::StatusWidget.status_plugin_present?
  end
end
