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

class RubylodeK8sPodsInTroubleTest < Redmine::IntegrationTest
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

  def running_pod(index, namespace: "bulk")
    { "metadata" => { "name" => "pod-#{index}", "namespace" => namespace, "creationTimestamp" => "2026-11-10T00:00:00Z" },
      "status" => { "phase" => "Running" } }
  end

  def failed_pod(index)
    { "metadata" => { "name" => format("failed-%03d", index), "namespace" => "bulk", "creationTimestamp" => "2026-11-10T00:00:00Z" },
      "status" => { "phase" => "Failed", "reason" => "Error", "message" => "it broke" } }
  end

  test "only the pods in trouble are listed" do
    travel_to FakeKubernetesApi::CAPTURED_AT do
      log_user("admin", "admin")
      get "/status/k8s"
    end

    assert_response :success
    assert_select ".rubylode-k8s-pod", 4
    assert_select ".rubylode-k8s-pod .rubylode-k8s-pod-name", text: "billing-api-7d9f6c-x2k4p"
    assert_select ".rubylode-k8s-pod .rubylode-k8s-pod-detail", text: /12 restarts, the last 8 min ago/
    assert_select ".rubylode-k8s-pod .rubylode-k8s-pod-detail", text: /Pending 14 min/
    assert_select ".rubylode-k8s-pod .rubylode-k8s-pod-name", text: /web-/, count: 0
    request = @fake_kubernetes.seen_requests.find { |seen| seen[:path] == "/api/v1/pods" }
    assert_equal "status.phase!=Succeeded", request[:query]["fieldSelector"]
    assert_equal "500", request[:query]["limit"]
  end

  test "pods refused with 403 leave the nodes showing and say the pods were not checked" do
    @fake_kubernetes.forbidden_paths = [FakeKubernetesApi::PODS_PATH]
    travel_to FakeKubernetesApi::CAPTURED_AT do
      log_user("admin", "admin")
      get "/status/k8s"
    end

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-unavailable", 0
    assert_select ".rubylode-k8s-pod", 0
    assert_select ".rubylode-k8s-pods-unchecked", text: "Pods could not be checked"
    assert_select ".rubylode-k8s-hint", text: /403/
    assert_not_includes response.body, FakeKubernetesApi::TOKEN

    post "/logout"
    log_user("jsmith", "jsmith")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-pods-unchecked", text: "Pods could not be checked"
    assert_select ".rubylode-k8s-hint", 0
  end

  test "pods answered with the wrong shape leave the nodes showing and keep the token out" do
    @fake_kubernetes.pods_answer = { "items" => "not a list" }
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-pods-unchecked", 1
    assert_not_includes response.body, FakeKubernetesApi::TOKEN
  end

  test "a cluster with more pods than the page cap is asked for 10 pages and says so" do
    @fake_kubernetes.pods_answer = { "metadata" => {}, "items" => (1..5001).map { |index| running_pod(index) } }
    log_user("admin", "admin")
    get "/status/k8s"

    pod_requests = @fake_kubernetes.seen_requests.select { |seen| seen[:path] == "/api/v1/pods" }
    assert_equal 10, pod_requests.size
    assert_equal ["500"], pod_requests.map { |seen| seen[:query]["limit"] }.uniq
    assert_select ".rubylode-k8s-pods-truncated", text: "Only the first 5000 pods were checked"
    assert_select ".rubylode-k8s-node", 4
  end

  test "exactly the page cap of pods is not truncated" do
    @fake_kubernetes.pods_answer = { "metadata" => {}, "items" => (1..5000).map { |index| running_pod(index) } }
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-pods-truncated", 0
  end

  test "more than 20 pods in trouble show 20 and a count of the rest" do
    @fake_kubernetes.pods_answer = { "metadata" => {}, "items" => (1..34).map { |index| failed_pod(index) } }
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-pod", 20
    assert_select ".rubylode-k8s-pods-more", text: "and 14 more"
  end

  test "Namespaces to ignore are left out of the list" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "namespaces_to_ignore" => "batch-test")
    travel_to FakeKubernetesApi::CAPTURED_AT do
      log_user("admin", "admin")
      get "/status/k8s"
    end

    assert_select ".rubylode-k8s-pod", 3
    assert_select ".rubylode-k8s-pod-name", text: /nightly-check/, count: 0
  end
end
