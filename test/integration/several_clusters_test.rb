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

class RubylodeK8sSeveralClustersTest < Redmine::IntegrationTest
  include RubylodeK8sTestHelpers

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issue_statuses, :trackers, :projects_trackers, :enumerations, :enabled_modules

  SECOND_TOKEN = "second.kubernetes.token-not-a-secret".freeze
  SECOND_TOKEN_VARIABLE = "K8S_STAGING_TOKEN".freeze
  SECOND_CERTIFICATE_AUTHORITY_VARIABLE = "K8S_STAGING_CA".freeze

  setup do
    use_memory_cache
    @first_fake = start_fake_kubernetes
    @second_fake = FakeKubernetesApi.new(accepted_tokens: [SECOND_TOKEN]).start
    ENV[SECOND_TOKEN_VARIABLE] = SECOND_TOKEN
    ENV[SECOND_CERTIFICATE_AUTHORITY_VARIABLE] = FakeKubernetesApi.certificate_authority_pem
    @account_directory = Dir.mktmpdir("rubylode-k8s-account")
    RubylodeK8s::InClusterAccount.directory = @account_directory
    configure_two_clusters
  end

  teardown do
    @second_fake&.stop
    stop_fake_kubernetes
    ENV.delete(SECOND_TOKEN_VARIABLE)
    ENV.delete(SECOND_CERTIFICATE_AUTHORITY_VARIABLE)
    RubylodeK8s::InClusterAccount.directory = nil
    RubylodeK8s::InClusterAccount.address = nil
    FileUtils.remove_entry(@account_directory)
    restore_cache
  end

  def configure_two_clusters(overrides = {})
    configure_plugin({ "clusters" => "Production | #{@first_fake.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}\n" \
                                     "Staging | #{@second_fake.url} | #{SECOND_TOKEN_VARIABLE} | #{SECOND_CERTIFICATE_AUTHORITY_VARIABLE}",
                       "cache_seconds" => "60", "failure_cache_seconds" => "60", "timeout_seconds" => "1" }.merge(overrides))
  end

  def write_account(token: nil, certificate_authority: FakeKubernetesApi.certificate_authority_pem)
    File.write(File.join(@account_directory, "token"), token) if token
    File.write(File.join(@account_directory, "ca.crt"), certificate_authority) if certificate_authority
  end

  def section_texts
    css_select(".rubylode-k8s-cluster").map { |section| section.text.squish }
  end

  test "two clusters give two sections in the order of the settings" do
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-cluster", 2
    assert_equal %w[Production Staging], css_select(".rubylode-k8s-cluster-name").map(&:text)
    assert_select ".rubylode-k8s-node", 8
  end

  test "a cluster that answers 500, or is slower than the timeout, is unavailable alone; only an administrator sees why" do
    log_user("admin", "admin")
    %w[server_error timeout].each do |failure|
      RubylodeK8s::ClusterStatus.cache.clear
      @second_fake.reset!
      @second_fake.failure = failure
      @second_fake.timeout_seconds = 2
      get "/status/k8s"

      assert_select ".rubylode-k8s-node", 4, failure
      assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
      assert_select ".rubylode-k8s-unavailable", 1
      assert_select ".rubylode-k8s-hint", 1
      assert_match(/Staging/, section_texts.last)
      assert_match(/Status unavailable/, section_texts.last)
    end

    post "/logout"
    log_user("jsmith", "jsmith")
    RubylodeK8s::ClusterStatus.cache.clear
    @second_fake.failure = "server_error"
    get "/status/k8s"
    assert_select ".rubylode-k8s-unavailable", 1
    assert_select ".rubylode-k8s-hint", 0
  end

  test "after a failure the cluster is not asked again within the failure cache time" do
    @second_fake.failure = "server_error"
    log_user("admin", "admin")
    get "/status/k8s"
    asked = @second_fake.seen_requests.size
    assert_operator asked, :>, 0
    get "/status/k8s"

    assert_equal asked, @second_fake.seen_requests.size
    assert_select ".rubylode-k8s-unavailable", 1
  end

  test "each token is sent only to its own cluster" do
    log_user("admin", "admin")
    get "/status/k8s"

    assert_equal ["Bearer #{FakeKubernetesApi::TOKEN}"], @first_fake.seen_requests.map { |seen| seen[:authorization] }.uniq
    assert_equal ["Bearer #{SECOND_TOKEN}"], @second_fake.seen_requests.map { |seen| seen[:authorization] }.uniq
  end

  test "a redirect to another host is not followed with the token" do
    @first_fake.redirect_to = @second_fake.url
    log_user("admin", "admin")
    get "/status/k8s"

    refute(@second_fake.seen_requests.any? { |seen| seen[:authorization] == "Bearer #{FakeKubernetesApi::TOKEN}" })
    assert_equal ["Bearer #{SECOND_TOKEN}"], @second_fake.seen_requests.map { |seen| seen[:authorization] }.uniq
    assert_select ".rubylode-k8s-unavailable", 1
    assert_match(/Production.*Status unavailable.*redirect/, section_texts.first)
  end

  test "a plain http address is refused, loopback included" do
    configure_plugin("clusters" => "Plain | http://127.0.0.1:#{@first_fake.port} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "cache_seconds" => "60")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".rubylode-k8s-hint", text: /https/
    assert_empty @first_fake.seen_requests
  end

  test "neither token is in the page, the log or the reason, even when a cluster fails" do
    @first_fake.failure = "unauthorized"
    @second_fake.failure = "server_error"
    log_user("admin", "admin")
    log = captured_log { get "/status/k8s" }

    [FakeKubernetesApi::TOKEN, SECOND_TOKEN].each do |token|
      refute_includes response.body, token
      refute_includes log, token
    end
    assert_select ".rubylode-k8s-unavailable", 2
  end

  test "a variable that is unset, or does not start with K8S_, makes that cluster unavailable and is never read or sent" do
    ENV["PLAIN_SECRET_VARIABLE"] = SECOND_TOKEN
    ENV.delete(SECOND_TOKEN_VARIABLE)
    configure_two_clusters("clusters" => "Production | #{@first_fake.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}\n" \
                                         "Unset | #{@second_fake.url} | #{SECOND_TOKEN_VARIABLE} | #{SECOND_CERTIFICATE_AUTHORITY_VARIABLE}\n" \
                                         "Outside | #{@second_fake.url} | PLAIN_SECRET_VARIABLE | #{SECOND_CERTIFICATE_AUTHORITY_VARIABLE}")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-unavailable", 2
    assert_empty @second_fake.seen_requests
    refute_includes response.body, SECOND_TOKEN
  ensure
    ENV.delete("PLAIN_SECRET_VARIABLE")
  end

  test "an answer bigger than 10 MB is refused, and an administrator is told why" do
    @first_fake.pod_body_bytes = RubylodeK8s::KubernetesClient::MAX_BODY_BYTES + 1024
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-pods-unchecked", 1
    assert_select ".rubylode-k8s-hint", text: /too large/
  end

  test "a node answer that is a JSON string or an array makes the cluster unavailable as unreadable, not without nodes" do
    log_user("admin", "admin")
    ["not a node list", [{ "metadata" => { "name" => "node-a" } }]].each do |answer|
      RubylodeK8s::ClusterStatus.cache.clear
      @first_fake.nodes_answer = answer
      get "/status/k8s"

      assert_select ".rubylode-k8s-node", 4, answer.class.name
      assert_select ".rubylode-k8s-unavailable", 1
      assert_select ".rubylode-k8s-hint", text: /The answer from Kubernetes could not be read/
      assert_match(/Production.*Status unavailable/, section_texts.first)
      refute_match(/No nodes found/, section_texts.first)
    end
  end

  test "node items of the wrong shape make the cluster unavailable as unreadable and never raise into the page" do
    @first_fake.nodes_answer = { "kind" => "NodeList", "items" => [1, "node", { "metadata" => "x", "status" => "y" }] }
    log_user("admin", "admin")
    get "/status/k8s"

    assert_response :success
    assert_select ".rubylode-k8s-unavailable", 1
    assert_select ".rubylode-k8s-hint", text: /The answer from Kubernetes could not be read/
  end

  test "a token read with a trailing newline is stripped before it is sent" do
    ENV[TOKEN_VARIABLE] = "#{FakeKubernetesApi::TOKEN}\n"
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 8
    assert_select ".rubylode-k8s-unavailable", 0
    assert_equal ["Bearer #{FakeKubernetesApi::TOKEN}"], @first_fake.seen_requests.map { |seen| seen[:authorization] }.uniq
  end

  test "an in-cluster line uses the mounted token and CA" do
    write_account(token: FakeKubernetesApi::TOKEN)
    RubylodeK8s::InClusterAccount.address = @first_fake.url
    configure_plugin("clusters" => "Here | in-cluster", "cache_seconds" => "60")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-node", 4
    assert_select ".rubylode-k8s-cluster-name", text: "Here"
    assert_equal ["Bearer #{FakeKubernetesApi::TOKEN}"], @first_fake.seen_requests.map { |seen| seen[:authorization] }.uniq
  end

  test "a rotated in-cluster token is read again on the next refresh" do
    @first_fake.accepted_tokens = %w[first second]
    RubylodeK8s::InClusterAccount.address = @first_fake.url
    configure_plugin("clusters" => "Here | in-cluster", "cache_seconds" => "0", "failure_cache_seconds" => "0")
    log_user("admin", "admin")
    write_account(token: "first")
    get "/status/k8s"
    write_account(token: "second")
    get "/status/k8s"

    headers = @first_fake.seen_requests.map { |seen| seen[:authorization] }
    assert_equal ["Bearer first", "Bearer second"], [headers.first, headers.last]
    assert_includes headers, "Bearer first"
    assert_select ".rubylode-k8s-node", 4
  end

  test "an in-cluster line without the token file is unavailable with a clear reason" do
    write_account
    RubylodeK8s::InClusterAccount.address = @first_fake.url
    configure_plugin("clusters" => "Here | in-cluster", "cache_seconds" => "60")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-unavailable", text: "Status unavailable"
    assert_select ".rubylode-k8s-hint", text: /service account token/
    assert_empty @first_fake.seen_requests
  end

  test "an in-cluster token with a line break inside is refused in words about the token file" do
    write_account(token: "first-half\nsecond-half")
    RubylodeK8s::InClusterAccount.address = @first_fake.url
    configure_plugin("clusters" => "Here | in-cluster", "cache_seconds" => "60")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-hint", text: /The service account token of this pod holds a line break/
    assert_select ".rubylode-k8s-hint", text: /token variable/, count: 0
    assert_empty @first_fake.seen_requests
  end

  test "an in-cluster line without a certificate in ca.crt is unavailable" do
    write_account(token: FakeKubernetesApi::TOKEN, certificate_authority: "nothing here")
    RubylodeK8s::InClusterAccount.address = @first_fake.url
    configure_plugin("clusters" => "Here | in-cluster", "cache_seconds" => "60")
    log_user("admin", "admin")
    get "/status/k8s"

    assert_select ".rubylode-k8s-hint", text: /ca\.crt/
    assert_empty @first_fake.seen_requests
  end
end
