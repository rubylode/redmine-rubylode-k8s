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

class RubylodeK8sStatusLinksTest < Redmine::IntegrationTest
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

  def configure_links(links)
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}", "links" => links)
  end

  def outside_links
    css_select(".rubylode-k8s a").select { |anchor| anchor["href"].to_s.start_with?("http") }
  end

  test "names link out when a pattern is set and stay text when not" do
    configure_links("Production | | https://nodes.example.com/n/{node} | https://pods.example.com/p?search={pod}")
    travel_to FakeKubernetesApi::CAPTURED_AT do
      log_user("admin", "admin")
      get "/status/k8s"
    end

    assert_response :success
    assert_select ".rubylode-k8s-node-name a[href=?]", "https://nodes.example.com/n/node-a", text: "node-a"
    assert_select ".rubylode-k8s-pod-name a[href=?]", "https://pods.example.com/p?search=billing-api-7d9f6c-x2k4p", text: "billing-api-7d9f6c-x2k4p"
    assert_select ".rubylode-k8s-cluster-name a", count: 0
    assert_select ".rubylode-k8s-cluster-name", text: "Production"
    assert_not_includes outside_links.map { |anchor| anchor["href"] }.join, FakeKubernetesApi::TOKEN
  end

  test "the cluster heading links when its pattern is set" do
    configure_links("Production | https://argocd.example.com/applications")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-cluster-name a[href=?]", "https://argocd.example.com/applications", text: "Production"
    assert_select ".rubylode-k8s-node-name a", count: 0
  end

  test "with no links line nothing on the page is a link to outside Redmine" do
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_empty outside_links
  end

  test "a saved pattern with a placeholder in the host leaves a name that is a domain as text" do
    @fake_kubernetes.pods_answer = { "kind" => "PodList", "items" => [
      { "metadata" => { "name" => "evil.example.com", "namespace" => "bulk", "creationTimestamp" => "2026-11-10T00:00:00Z" },
        "status" => { "phase" => "Failed", "reason" => "Error", "message" => "it broke" } }
    ] }
    configure_links("Production | | https://grafana.{node}/n | https://{pod}/x")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-pod .rubylode-k8s-pod-name", text: "evil.example.com"
    assert_select ".rubylode-k8s-pod-name a", count: 0
    assert_select ".rubylode-k8s-node-name a", count: 0
  end

  test "a saved pattern that does not expand to an http or https address is not rendered as a link" do
    configure_links("Production | javascript:alert(1) | {node} | //evil.example.com/{pod}")
    travel_to FakeKubernetesApi::CAPTURED_AT do
      log_user("admin", "admin")
      get "/status/k8s"
    end

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s a", count: 0
  end
end
