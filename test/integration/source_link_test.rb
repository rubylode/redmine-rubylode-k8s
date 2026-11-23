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

class RubylodeK8sSourceLinkTest < Redmine::IntegrationTest
  include RubylodeK8sTestHelpers

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issue_statuses, :trackers, :projects_trackers, :enumerations, :enabled_modules

  CLUSTER_PAGE = "https://argocd.example.com/applications".freeze

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

  test "the page draws one link to the cluster's page beside its heading" do
    configure_links("Production | #{CLUSTER_PAGE}")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select "a.rubylode-k8s-source-link.external[href=?]", CLUSTER_PAGE, text: "Open the cluster's page", count: 1
    assert_select "a.rubylode-k8s-source-link[target]", count: 0
    assert_select ".rubylode-k8s-cluster-head .rubylode-k8s-cluster-name"
    assert_select ".rubylode-k8s-cluster-head a.rubylode-k8s-source-link"
  end

  test "the link is drawn in the Status page widget variant and in the compact variant" do
    configure_links("Production | #{CLUSTER_PAGE}")
    User.current = User.find(1)
    view = ApplicationController.new.view_context

    [{ widget: {} }, { compact: true }].each do |locals|
      html = Nokogiri::HTML.fragment(view.render(partial: "rubylode_k8s/status", locals: locals))

      assert_equal ["Open the cluster's page"], html.css("a.rubylode-k8s-source-link").map(&:text), locals.inspect
    end
  ensure
    User.current = nil
  end

  test "the link is drawn when the cluster cannot be reached" do
    configure_links("Production | #{CLUSTER_PAGE}")
    @fake_kubernetes.failure = "server_error"
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select "a.rubylode-k8s-source-link[href=?]", CLUSTER_PAGE, count: 1
  end

  test "a cluster without a cluster link has no link" do
    configure_links("Production | | https://nodes.example.com/{node}")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-source-link", count: 0
  end

  test "a cluster link that is not a web address draws no link" do
    configure_links("Production | javascript:alert(1)")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-source-link", count: 0
  end

  test "the not set up hint for an administrator has no link" do
    configure_plugin("clusters" => "", "links" => "Production | #{CLUSTER_PAGE}")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-source-link", count: 0
  end

  test "a person the block is hidden from gets no link" do
    configure_links("Production | #{CLUSTER_PAGE}")
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "links" => "Production | #{CLUSTER_PAGE}", "visibility" => "admins")
    log_user("jsmith", "jsmith")
    get "/status/k8s"

    assert_select ".rubylode-k8s-source-link", count: 0
  end
end
