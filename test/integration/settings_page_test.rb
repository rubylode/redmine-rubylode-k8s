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
require "tmpdir"

class RubylodeK8sSettingsPageTest < Redmine::IntegrationTest
  include RubylodeK8sTestHelpers

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issue_statuses, :trackers, :projects_trackers, :enumerations, :enabled_modules

  SETTINGS_PATH = "/settings/plugin/redmine_rubylode_k8s".freeze
  SECRET_TOKEN = "super.secret.kubernetes.token-DO-NOT-LEAK".freeze
  SET_VARIABLE = "K8S_SETTINGS_TEST_SET".freeze
  UNSET_VARIABLE = "K8S_SETTINGS_TEST_UNSET".freeze
  CERTIFICATE_VARIABLE = "K8S_SETTINGS_TEST_CA".freeze
  EMPTY_CERTIFICATE_VARIABLE = "K8S_SETTINGS_TEST_EMPTY_CA".freeze

  setup do
    configure_plugin
    ENV[SET_VARIABLE] = SECRET_TOKEN
    ENV[CERTIFICATE_VARIABLE] = FakeKubernetesApi.certificate_authority_pem
    ENV[EMPTY_CERTIFICATE_VARIABLE] = ""
    ENV.delete(UNSET_VARIABLE)
    @account_directory = Dir.mktmpdir("rubylode-k8s-settings")
    RubylodeK8s::InClusterAccount.directory = @account_directory
  end

  teardown do
    [SET_VARIABLE, CERTIFICATE_VARIABLE, EMPTY_CERTIFICATE_VARIABLE].each { |name| ENV.delete(name) }
    RubylodeK8s::InClusterAccount.directory = nil
    FileUtils.remove_entry(@account_directory)
  end

  def good_settings(overrides = {})
    Redmine::Plugin.find(PLUGIN_ID).settings[:default].merge(
      "clusters" => "Production | https://k8s.example.com | #{SET_VARIABLE} | #{CERTIFICATE_VARIABLE}\nStaging | https://staging.example.com | #{UNSET_VARIABLE}"
    ).merge(overrides)
  end

  def saved
    Setting.send(:"plugin_#{PLUGIN_ID}")
  end

  def assert_refused(overrides, message_pattern)
    post SETTINGS_PATH, params: { settings: good_settings(overrides) }

    assert_response :unprocessable_entity
    assert_select "#errorExplanation li", text: message_pattern
    assert_equal "", saved["clusters"], "nothing was saved"
    assert_equal "", saved["links"], "nothing was saved"
  end

  test "saving valid cluster lines stores them as plugin settings" do
    log_user("admin", "admin")
    post SETTINGS_PATH, params: { settings: good_settings("clusters" => "# the clusters\n\nProduction | https://k8s.example.com | #{SET_VARIABLE}\nHere | in-cluster\nStaging | https://s.example.com | #{SET_VARIABLE} | #{CERTIFICATE_VARIABLE}") }

    assert_redirected_to SETTINGS_PATH
    assert_equal %w[Production Here Staging], RubylodeK8s::Settings.current.clusters.map(&:name)
    assert RubylodeK8s::Settings.current.clusters[1].in_cluster
  end

  test "each bad cluster line is refused with its line number" do
    log_user("admin", "admin")
    assert_refused({ "clusters" => "Production" }, /Clusters, line 1: needs 2 fields \(Name \| in-cluster\) or 3 to 4/)
    assert_refused({ "clusters" => "Production | https://k8s.example.com | #{SET_VARIABLE} | #{CERTIFICATE_VARIABLE} | extra" },
                   /Clusters, line 1: needs 2 fields .* or 3 to 4 .*found 5/)
    assert_refused({ "clusters" => "# note\nProduction | ftp://k8s.example.com | #{SET_VARIABLE}" }, %r{Clusters, line 2: the address must start with https://})
    assert_refused({ "clusters" => "Production | k8s.example.com | #{SET_VARIABLE}" }, %r{Clusters, line 1: the address must start with https://})
    assert_refused({ "clusters" => "Production | http://k8s.example.com | #{SET_VARIABLE}" }, /Clusters, line 1: .*https/)
    assert_refused({ "clusters" => "Production | http://localhost:8080 | #{SET_VARIABLE}" }, /Clusters, line 1: .*https/)
    assert_refused({ "clusters" => "Production | https://k8s.example.com | SECRET_KEY_BASE" }, /Clusters, line 1: the token variable must start with K8S_/)
    assert_refused({ "clusters" => "Production | https://k8s.example.com | #{SET_VARIABLE} | SECRET_KEY_BASE" },
                   /Clusters, line 1: the certificate authority variable must start with K8S_/)
    assert_refused({ "clusters" => "Here | in-cluster | K8S_X" }, /Clusters, line 1: in-cluster takes no more fields/)
    assert_refused({ "clusters" => " | https://k8s.example.com | #{SET_VARIABLE}" }, /Clusters, line 1: the name is empty/)
    assert_refused({ "clusters" => "Production | https://a.example.com | K8S_A\nProduction | https://b.example.com | K8S_B" },
                   /Clusters, line 2: .*Production.* already used/)
  end

  test "an address with credentials, a query or a fragment is refused with its line number" do
    log_user("admin", "admin")
    assert_refused({ "clusters" => "Production | https://user:pass@k8s.example.com | #{SET_VARIABLE}" },
                   /Clusters, line 1: .*without a user name, a query or a fragment/)
    assert_refused({ "clusters" => "# note\nProduction | https://k8s.example.com?x=1 | #{SET_VARIABLE}" },
                   /Clusters, line 2: .*without a user name, a query or a fragment/)
    assert_refused({ "clusters" => "Production | https://k8s.example.com/#top | #{SET_VARIABLE}" },
                   /Clusters, line 1: .*without a user name, a query or a fragment/)
  end

  test "a namespace that is not a valid name is refused with its line number" do
    log_user("admin", "admin")
    assert_refused({ "namespaces_to_ignore" => "kube-system\nBad_Name" }, /Namespaces to ignore, line 2: .*Bad_Name/)
    assert_refused({ "namespaces_to_ignore" => "-leading" }, /Namespaces to ignore, line 1/)
    assert_refused({ "namespaces_to_ignore" => "a, b" }, /Namespaces to ignore, line 1/)

    post SETTINGS_PATH, params: { settings: good_settings("namespaces_to_ignore" => "kube-system\n\nmonitoring-2") }
    assert_redirected_to SETTINGS_PATH
  end

  test "pending grace, restart threshold, cache, failure cache and timeout outside their bounds are refused" do
    log_user("admin", "admin")
    assert_refused({ "pending_grace_minutes" => "-1" }, /Pending grace minutes must be a whole number of at least 0/)
    assert_refused({ "restart_threshold" => "0" }, /Restart threshold must be a whole number of at least 1/)
    assert_refused({ "cache_seconds" => "-1" }, /Cache seconds must be a whole number of at least 0/)
    assert_refused({ "failure_cache_seconds" => "soon" }, /Failure cache seconds must be a whole number of at least 0/)
    assert_refused({ "timeout_seconds" => "0" }, /Timeout seconds must be a whole number of at least 1/)
  end

  test "the page says whether each variable is set and never shows a value" do
    configure_plugin("clusters" => good_settings["clusters"] +
                                   "\nOther | https://o.example.com | SECRET_KEY_BASE\nEmptyAuthority | https://e.example.com | #{SET_VARIABLE} | #{EMPTY_CERTIFICATE_VARIABLE}")
    log_user("admin", "admin")
    get SETTINGS_PATH

    assert_response :success
    assert_select ".rubylode-k8s-variable-state li", 4
    assert_select ".rubylode-k8s-variable-state li", text: /Production: token variable #{SET_VARIABLE} set; CA variable #{CERTIFICATE_VARIABLE} set/
    assert_select ".rubylode-k8s-variable-state li", text: /Staging: token variable #{UNSET_VARIABLE} not set; CA system trust store/
    assert_select ".rubylode-k8s-variable-state li", text: /Other: token variable SECRET_KEY_BASE not allowed/
    assert_select ".rubylode-k8s-variable-state li", text: /EmptyAuthority: token variable #{SET_VARIABLE} set; CA variable #{EMPTY_CERTIFICATE_VARIABLE} not set/
    assert_not_includes response.body, SECRET_TOKEN
    assert_not_includes response.body, "BEGIN CERTIFICATE"
  end

  test "a token variable holding only spaces or a line break reads as not set, as the plugin treats it" do
    blank_variables = { "K8S_SETTINGS_TEST_SPACES" => "   ", "K8S_SETTINGS_TEST_NEWLINE" => "\n" }
    blank_variables.each { |name, value| ENV[name] = value }
    configure_plugin("clusters" => "Spaces | https://s.example.com | K8S_SETTINGS_TEST_SPACES\nNewline | https://n.example.com | K8S_SETTINGS_TEST_NEWLINE\n" \
                                   "Real | https://r.example.com | #{SET_VARIABLE}")
    log_user("admin", "admin")
    get SETTINGS_PATH

    assert_select ".rubylode-k8s-variable-state li", text: /Spaces: token variable K8S_SETTINGS_TEST_SPACES not set/
    assert_select ".rubylode-k8s-variable-state li", text: /Newline: token variable K8S_SETTINGS_TEST_NEWLINE not set/
    assert_select ".rubylode-k8s-variable-state li", text: /Real: token variable #{SET_VARIABLE} set/
    assert_not_includes response.body, SECRET_TOKEN
  ensure
    blank_variables.each_key { |name| ENV.delete(name) }
  end

  test "a CA variable holding only spaces or a line break reads as not set, and a real one as set" do
    ENV["K8S_SETTINGS_TEST_SPACES_CA"] = "  \n "
    configure_plugin("clusters" => "Blank | https://b.example.com | #{SET_VARIABLE} | K8S_SETTINGS_TEST_SPACES_CA\n" \
                                   "Real | https://r.example.com | #{SET_VARIABLE} | #{CERTIFICATE_VARIABLE}")
    log_user("admin", "admin")
    get SETTINGS_PATH

    assert_select ".rubylode-k8s-variable-state li", text: /Blank: token variable #{SET_VARIABLE} set; CA variable K8S_SETTINGS_TEST_SPACES_CA not set/
    assert_select ".rubylode-k8s-variable-state li", text: /Real: token variable #{SET_VARIABLE} set; CA variable #{CERTIFICATE_VARIABLE} set/
    assert_not_includes response.body, "BEGIN CERTIFICATE"
  ensure
    ENV.delete("K8S_SETTINGS_TEST_SPACES_CA")
  end

  test "for an in-cluster line the page says whether the token and CA files exist" do
    configure_plugin("clusters" => "Here | in-cluster")
    File.write(File.join(@account_directory, "token"), SECRET_TOKEN)
    log_user("admin", "admin")
    get SETTINGS_PATH

    assert_select ".rubylode-k8s-variable-state li", text: /Here: token file found; CA file not found/
    assert_not_includes response.body, SECRET_TOKEN

    File.write(File.join(@account_directory, "ca.crt"), FakeKubernetesApi.certificate_authority_pem)
    File.delete(File.join(@account_directory, "token"))
    get SETTINGS_PATH
    assert_select ".rubylode-k8s-variable-state li", text: /Here: token file not found; CA file found/
  end

  test "the page has every setting" do
    log_user("admin", "admin")
    get SETTINGS_PATH

    %w[clusters links pending_grace_minutes restart_threshold namespaces_to_ignore cache_seconds failure_cache_seconds timeout_seconds
       block_title visibility show_on_welcome_page welcome_page_column show_on_my_page show_on_project_overview
       project_overview_column show_on_matching_pages matching_page_paths show_in_top_menu].each do |field|
      assert_select "[name=?]", "settings[#{field}]"
    end
  end

  test "saving clears the cache, so the next page load asks Kubernetes again" do
    use_memory_cache
    server = start_fake_kubernetes
    log_user("admin", "admin")
    get "/status/k8s"
    get "/status/k8s"
    assert_equal 1, server.seen_requests.count { |seen| seen[:path] == "/api/v1/nodes" }

    post SETTINGS_PATH, params: { settings: saved }
    get "/status/k8s"
    assert_equal 2, server.seen_requests.count { |seen| seen[:path] == "/api/v1/nodes" }
  ensure
    stop_fake_kubernetes
    restore_cache
  end

  test "cleared number fields fall back to their defaults, and the status page still answers and caches" do
    use_memory_cache
    server = start_fake_kubernetes
    log_user("admin", "admin")
    cleared = %w[cache_seconds failure_cache_seconds timeout_seconds pending_grace_minutes restart_threshold].to_h { |field| [field, ""] }
    post SETTINGS_PATH, params: { settings: saved.merge(cleared) }
    assert_redirected_to SETTINGS_PATH

    settings = RubylodeK8s::Settings.current
    assert_equal [60, 30, 3, 5, 5], [settings.cache_seconds, settings.failure_cache_seconds, settings.timeout_seconds,
                                     settings.pending_grace_minutes, settings.restart_threshold]
    get "/status/k8s"
    get "/status/k8s"
    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-unavailable", 0
    assert_equal 1, server.seen_requests.count { |seen| seen[:path] == "/api/v1/nodes" }
  ensure
    stop_fake_kubernetes
    restore_cache
  end

  test "a typed 0 turns the caches off, and the timeout and restart threshold never go below 1" do
    settings = RubylodeK8s::Settings.new("cache_seconds" => "0", "failure_cache_seconds" => "0", "timeout_seconds" => "0", "restart_threshold" => "0")

    assert_equal [0, 0, 1, 1], [settings.cache_seconds, settings.failure_cache_seconds, settings.timeout_seconds, settings.restart_threshold]
  end

  test "someone who is not an administrator cannot open or save the settings" do
    log_user("jsmith", "jsmith")
    get SETTINGS_PATH
    assert_response :forbidden
    post SETTINGS_PATH, params: { settings: good_settings }
    assert_response :forbidden
    assert_equal "", saved["clusters"]
  end

  test "the not set up hint links an administrator to the settings" do
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-hint a[href=?]", SETTINGS_PATH
  end

  test "the validation patch is applied to the settings controller" do
    assert SettingsController.include?(RubylodeK8s::SettingsControllerPatch)
  end

  test "each bad links line is refused with its line number" do
    log_user("admin", "admin")
    assert_refused({ "links" => "Nowhere | https://a.example.com" }, /Links, line 1: no cluster named Nowhere/)
    assert_refused({ "links" => "# note\nProduction | https://a.example.com | | | extra" }, /Links, line 2: needs at most 4 fields.*found 5/)
    assert_refused({ "links" => "Production | javascript:alert(1)" }, %r{Links, line 1: the cluster link must start with http:// or https://})
    assert_refused({ "links" => "Production | | /nodes/{node}" }, %r{Links, line 1: the node link must start with http:// or https://})
    assert_refused({ "links" => "Production | | | //evil.example.com/{pod}" }, /Links, line 1: the pod link must start with/)
    assert_refused({ "links" => "Production | https://u:p@a.example.com" }, /Links, line 1: the cluster link .*user name/)
    assert_refused({ "links" => "Production | https://a.example.com\nProduction | https://b.example.com" }, /Links, line 2: .*Production.* already used/)
  end

  test "a name could pick the domain of a link, so a placeholder before the first slash is refused with its line number" do
    log_user("admin", "admin")
    assert_refused({ "links" => "Production | | | https://{pod}/x" }, %r{Links, line 1: the pod link cannot have a placeholder before the first /})
    assert_refused({ "links" => "# note\nProduction | | https://grafana.{node}/n |" }, %r{Links, line 2: the node link cannot have a placeholder before the first /})
    assert_refused({ "links" => "Production | | | https://x.example.com:{pod}/" }, /Links, line 1: the pod link cannot have a placeholder/)
  end

  test "a placeholder of another kind, or an unknown one, is refused with its line number and the link kind" do
    log_user("admin", "admin")
    assert_refused({ "links" => "Production | | https://a.example.com/{pod}" }, /Links, line 1: \{pod\} cannot be used in the node link: it takes \{node\}/)
    assert_refused({ "links" => "Production | https://a.example.com/{node}" }, /Links, line 1: \{node\} cannot be used in the cluster link: it takes no placeholders/)
    assert_refused({ "links" => "Production | | | https://a.example.com/p?x={other}" }, /Links, line 1: \{other\} cannot be used in the pod link: it takes \{namespace\}, \{pod\}/)
    assert_refused({ "links" => "Production | | https://a.example.com/{node" }, /Links, line 1: the node link must start with/)
  end

  test "a data or mixed-case javascript link is refused" do
    log_user("admin", "admin")
    assert_refused({ "links" => "Production | data:text/html,x" }, %r{Links, line 1: the cluster link must start with http:// or https://})
    assert_refused({ "links" => "Production | JaVaScRiPt:alert(1)" }, %r{Links, line 1: the cluster link must start with http:// or https://})
  end

  test "a refused save shows the form again without any token or certificate" do
    log_user("admin", "admin")
    post SETTINGS_PATH, params: { settings: good_settings("links" => "Nowhere | https://a.example.com") }

    assert_response 422
    assert_select "#errorExplanation li"
    assert_not_includes response.body, SECRET_TOKEN
    assert_not_includes response.body, "BEGIN CERTIFICATE"
  end

  test "valid links lines are stored and read back per cluster" do
    log_user("admin", "admin")
    links = "# links\nProduction | https://argocd.example.com/applications | | https://argocd.example.com/applications?search={pod}"
    post SETTINGS_PATH, params: { settings: good_settings("links" => links) }

    assert_redirected_to SETTINGS_PATH
    patterns = RubylodeK8s::Settings.current.links_for("Production")
    assert_equal "https://argocd.example.com/applications", patterns.cluster
    assert_equal "", patterns.node
    assert_equal "https://argocd.example.com/applications?search={pod}", patterns.pod
    assert_equal "", RubylodeK8s::Settings.current.links_for("Staging").cluster
  end
end
