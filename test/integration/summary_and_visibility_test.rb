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

class RubylodeK8sSummaryAndVisibilityTest < Redmine::IntegrationTest
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

  test "the page opens with the summary" do
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-summary", text: "1 of 4 nodes not ready, 4 pods in trouble"
    assert_select ".rubylode-k8s-summary.is-trouble"
    assert_select ".rubylode-k8s-node:first-of-type .rubylode-k8s-node-name", text: "node-d"
    assert_select ".rubylode-k8s-no-pods-in-trouble", 0
  end

  test "pods that could not be checked are not reported as none in trouble" do
    @fake_kubernetes.forbidden_paths = ["/api/v1/pods"]
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-summary", text: "1 of 4 nodes not ready, pods not checked on 1 cluster"
    assert_select ".rubylode-k8s-no-pods-in-trouble", 0
  end

  test "by default any signed in person sees the page; the reason a cluster failed is for administrators alone" do
    @fake_kubernetes.failure = "server_error"
    log_user("jsmith", "jsmith")
    get "/status/k8s"

    assert_response :success
    assert_select ".rubylode-k8s-unavailable", 1
    assert_select ".rubylode-k8s-hint", 0

    post "/logout"
    log_user("admin", "admin")
    RubylodeK8s::ClusterStatus.cache.clear
    get "/status/k8s"
    assert_select ".rubylode-k8s-hint", 1
  end

  test "Administrators only turns a signed in person away, and still shows the page to an administrator" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}", "visibility" => "admins")
    log_user("jsmith", "jsmith")
    get "/status/k8s"
    assert_response :forbidden
    assert_select ".rubylode-k8s-node", 0

    post "/logout"
    log_user("admin", "admin")
    get "/status/k8s"
    assert_response :success
    assert_select ".rubylode-k8s-node", 4
  end

  test "an anonymous visitor is sent to sign in, whoever the setting allows" do
    %w[logged_in admins].each do |visibility|
      configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}", "visibility" => visibility)
      get "/status/k8s"

      assert_redirected_to %r{/login}, visibility
    end
    assert_empty @fake_kubernetes.seen_requests
  end

  test "Block title is the heading, Kubernetes when none is set" do
    log_user("admin", "admin")
    get "/status/k8s"
    assert_select "h2", text: "Kubernetes"

    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}", "block_title" => "Cluster health")
    get "/status/k8s"
    assert_select "h2", text: "Cluster health"
    assert_select "title", text: /Cluster health/
  end
end
