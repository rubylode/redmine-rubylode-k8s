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

class RubylodeK8sStatusPageTest < Redmine::IntegrationTest
  include RubylodeK8sTestHelpers

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issue_statuses, :trackers, :projects_trackers, :enumerations, :enabled_modules

  TOKEN_VARIABLE_WITHOUT_CERTIFICATE = "K8S_TEXT_CA"

  setup do
    use_memory_cache
    start_fake_kubernetes
  end

  teardown do
    stop_fake_kubernetes
    restore_cache
  end

  test "an administrator sees one row per node" do
    log_user("admin", "admin")
    get "/status/k8s"

    assert_response :success
    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-node .rubylode-k8s-node-name", text: "node-a"
    assert_select ".rubylode-k8s-node .rubylode-k8s-node-status", text: "Ready", count: 3
    assert_select ".rubylode-k8s-node .rubylode-k8s-node-status", text: "NotReady: MemoryPressure", count: 1
  end

  test "the call carries the token from the named variable over https" do
    log_user("admin", "admin")
    get "/status/k8s"

    request = @fake_kubernetes.seen_requests.find { |seen| seen[:path] == "/api/v1/nodes" }
    assert_equal "Bearer fake.kubernetes.token-not-a-secret", request[:authorization]
    assert @fake_kubernetes.url.start_with?("https://")
  end

  test "the cluster's CA variable is trusted, and without it the certificate of the fake is refused" do
    log_user("admin", "admin")
    get "/status/k8s"
    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-unavailable", 0

    RubylodeK8s::ClusterStatus.cache.clear
    @fake_kubernetes.reset!
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE}")
    get "/status/k8s"

    assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".rubylode-k8s-hint", text: /SSLError/
    assert_select ".rubylode-k8s-node", 0
    assert_empty @fake_kubernetes.seen_requests
  end

  test "a second look within the cache time does not ask Kubernetes again" do
    log_user("admin", "admin")
    get "/status/k8s"
    get "/status/k8s"

    assert_response :success
    assert_select ".rubylode-k8s-node", 4
    assert_equal 1, @fake_kubernetes.seen_requests.count { |seen| seen[:path] == "/api/v1/nodes" }
  end

  test "a CA variable that holds no certificate makes the cluster unavailable and never falls back to the system store" do
    log_user("admin", "admin")
    ["K8S_UNSET_CA", "NOT_ALLOWED_CA", TOKEN_VARIABLE_WITHOUT_CERTIFICATE].each do |variable|
      ENV[TOKEN_VARIABLE_WITHOUT_CERTIFICATE] = "this is not a certificate"
      ENV["NOT_ALLOWED_CA"] = FakeKubernetesApi.certificate_authority_pem
      RubylodeK8s::ClusterStatus.cache.clear
      @fake_kubernetes.reset!
      configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{variable}")
      get "/status/k8s"

      assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
      assert_select ".rubylode-k8s-hint", text: /holds no certificate/
      assert_empty @fake_kubernetes.seen_requests, variable
    end
  ensure
    ENV.delete("NOT_ALLOWED_CA")
    ENV.delete(TOKEN_VARIABLE_WITHOUT_CERTIFICATE)
  end

  test "an unexpected error inside the client shows the cluster unavailable with its class, is cached, and never shows the token" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "failure_cache_seconds" => "60")
    log_user("admin", "admin")
    [TypeError.new("no implicit conversion of #{FakeKubernetesApi::TOKEN}"), UnexpectedErrorForTest.new].each do |error|
      RubylodeK8s::ClusterStatus.cache.clear
      log = captured_log { raising_on_call(1, error) { get "/status/k8s" } }

      assert_response :success
      assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
      assert_select ".rubylode-k8s-hint", text: /#{Regexp.escape(error.class.name)}/
      assert cached_report_for_first_cluster["unavailable"], error.class.name
      refute_includes response.body, FakeKubernetesApi::TOKEN
      refute_includes log, FakeKubernetesApi::TOKEN
      refute_includes cached_report_for_first_cluster.to_s, FakeKubernetesApi::TOKEN
    end
  end

  test "an unexpected error while the rows are built shows the cluster unavailable with its class and never shows the token" do
    log_user("admin", "admin")
    log = captured_log do
      replacing_method(RubylodeK8s::ClusterStatus, :node_rows_from, ->(*) { raise UnexpectedErrorForTest }) { get "/status/k8s" }
    end

    assert_response :success
    assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".rubylode-k8s-hint", text: /could not be read \(.*UnexpectedErrorForTest\)/
    assert cached_report_for_first_cluster["unavailable"]
    refute_includes response.body, FakeKubernetesApi::TOKEN
    refute_includes log, FakeKubernetesApi::TOKEN
  end

  test "a person who is not an administrator sees the cluster unavailable without the error's class" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "visibility" => "logged_in")
    log_user("jsmith", "jsmith")
    raising_on_call(1, UnexpectedErrorForTest) { get "/status/k8s" }

    assert_response :success
    assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".rubylode-k8s-hint", 0
    refute_includes response.body, "UnexpectedErrorForTest"
  end

  test "a token with a line break inside is refused and never sent" do
    ENV[TOKEN_VARIABLE] = "first-half\nsecond-half"
    log_user("admin", "admin")
    log = captured_log { get "/status/k8s" }

    assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".rubylode-k8s-hint", text: /holds a line break/
    assert_empty @fake_kubernetes.seen_requests
    ["first-half", "second-half"].each do |part|
      refute_includes response.body, part
      refute_includes log, part
    end
  end
end
