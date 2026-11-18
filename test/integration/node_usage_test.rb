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

class RubylodeK8sNodeUsageTest < Redmine::IntegrationTest
  include RubylodeK8sTestHelpers

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issue_statuses, :trackers, :projects_trackers, :enumerations, :enabled_modules

  setup do
    use_memory_cache
    start_fake_kubernetes
  end

  teardown do
    stop_fake_kubernetes
    restore_cache
  end

  test "bars show usage and the status names a pressure condition" do
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-bar", 6
    assert_select ".rubylode-k8s-bar.is-normal", 6
    assert_select ".rubylode-k8s-node-status", text: "NotReady: MemoryPressure"
    assert_select ".rubylode-k8s-percent", text: "24%"
    assert_select ".rubylode-k8s-percent", text: "44%"
    assert_select ".rubylode-k8s-no-metrics", 2
  end

  test "without the Metrics API the bars say no metrics and the nodes still show" do
    @fake_kubernetes.metrics_missing = true
    log_user("admin", "admin")
    get "/status/k8s"

    assert_response :success
    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-unavailable", 0
    assert_select ".rubylode-k8s-bar", 0
    assert_select ".rubylode-k8s-no-metrics", 8
  end

  test "metrics refused with 403 behave the same, and only an administrator sees why" do
    @fake_kubernetes.forbidden_paths = [FakeKubernetesApi::METRICS_PATH]
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-bar", 0
    assert_select ".rubylode-k8s-hint", text: /403/
    assert_not_includes response.body, FakeKubernetesApi::TOKEN

    post "/logout"
    log_user("jsmith", "jsmith")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-no-metrics", 8
    assert_select ".rubylode-k8s-hint", 0
  end

  test "bars carry the level class" do
    memory_total = 13_974_828
    @fake_kubernetes.metrics_answer = { "items" => [
      { "metadata" => { "name" => "node-a" }, "usage" => { "cpu" => "100m", "memory" => "#{(memory_total * 0.91).to_i}Ki" } }
    ] }
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-bar.is-critical", 1
    assert_select ".rubylode-k8s-bar.is-normal", 1
  end
  test "a metrics answer of the wrong shape says no metrics and the nodes still show" do
    log_user("admin", "admin")
    [[], { "kind" => "NodeMetricsList" }].each do |answer|
      RubylodeK8s::ClusterStatus.cache.clear
      @fake_kubernetes.metrics_answer = answer
      get "/status/k8s"

      assert_select ".rubylode-k8s-node", 4
      assert_select ".rubylode-k8s-unavailable", 0
      assert_select ".rubylode-k8s-no-metrics", 8
    end
  end
end
