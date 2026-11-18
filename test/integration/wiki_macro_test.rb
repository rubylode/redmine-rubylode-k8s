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

class RubylodeK8sWikiMacroTest < Redmine::IntegrationTest
  include RubylodeK8sTestHelpers

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :issue_statuses, :trackers,
           :projects_trackers, :enumerations, :enabled_modules, :wikis, :wiki_pages, :wiki_contents, :wiki_content_versions

  setup do
    use_memory_cache
    start_fake_kubernetes
  end

  teardown do
    stop_fake_kubernetes
    restore_cache
  end

  def get_wiki_page(text, login: "jsmith")
    page = WikiPage.new(wiki: Project.find(1).wiki, title: "Status_#{SecureRandom.hex(3)}")
    page.content = WikiContent.new(text: text, author: User.find(2))
    page.save!
    log_user(login, login)
    get "/projects/ecookbook/wiki/#{page.title}"
    assert_response :success
  end

  test "the macro draws the status block inside the wiki page" do
    get_wiki_page("Our clusters:\n\n{{k8s_status}}")

    assert_select ".wiki .rubylode-k8s-summary", text: "1 of 4 nodes not ready, 4 pods in trouble"
    assert_select ".wiki td.rubylode-k8s-node-name", text: "node-a"
  end

  test "the macro takes a title" do
    get_wiki_page("{{k8s_status(title=Customer-facing)}}")

    assert_select ".wiki h3.rubylode-k8s-title", text: /\ACustomer-facing/
  end

  test "the macro uses the block title setting when it has no title" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}", "block_title" => "Company clusters")
    get_wiki_page("{{k8s_status}}")

    assert_select ".wiki h3.rubylode-k8s-title", text: /\ACompany clusters/
  end

  test "a person the permission setting excludes sees nothing where the macro stands" do
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}", "visibility" => "admins")
    get_wiki_page("before {{k8s_status}} after")

    assert_select ".wiki .rubylode-k8s", 0
    assert_select ".wiki", text: /before\s+after/
  end

  test "the macro is listed among the wiki macros" do
    assert Redmine::WikiFormatting::Macros.available_macros.key?(:k8s_status)
  end

  test "a wiki page still answers when every cluster is down" do
    @fake_kubernetes.failure = "server_error"
    get_wiki_page("Intro\n\n{{k8s_status}}")

    assert_select ".wiki .rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".wiki", text: /Intro/
  end

  test "an anonymous visitor to a public wiki page sees no cluster data and Kubernetes is not asked" do
    page = WikiPage.new(wiki: Project.find(1).wiki, title: "Status_public")
    page.content = WikiContent.new(text: "Intro {{k8s_status}}", author: User.find(2))
    page.save!

    get "/projects/ecookbook/wiki/Status_public"

    assert_response :success
    assert_select ".wiki", text: /Intro/
    assert_select ".wiki .rubylode-k8s", 0
    assert_empty @fake_kubernetes.seen_requests
  end

  test "a wiki page still answers when the plugin fails unexpectedly, and never shows the token" do
    log = captured_log { raising_on_call(1, UnexpectedErrorForTest) { get_wiki_page("Intro\n\n{{k8s_status}}") } }

    assert_select ".wiki .rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".wiki", text: /Intro/
    refute_includes response.body, FakeKubernetesApi::TOKEN
    refute_includes log, FakeKubernetesApi::TOKEN
  end
end
