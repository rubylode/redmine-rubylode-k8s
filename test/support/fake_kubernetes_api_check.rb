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

require "net/http"
require "openssl"
require "json"
require "stringio"
require_relative "fake_kubernetes_api"

# A quick proof that the fake API works without Redmine:  ruby test/support/fake_kubernetes_api_check.rb
# The full Minitest suite for it comes with the plugin.
failures = []
check = ->(description, passed) { (passed ? puts("ok    #{description}") : (puts("FAIL  #{description}"); failures << description)) }

server = FakeKubernetesApi.new.start
store = OpenSSL::X509::Store.new
store.add_cert(OpenSSL::X509::Certificate.new(FakeKubernetesApi.certificate_authority_pem))

get = lambda do |path, token: FakeKubernetesApi::TOKEN, host: "127.0.0.1"|
  http = Net::HTTP.new(host, server.port)
  http.use_ssl = true
  http.cert_store = store
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER
  request = Net::HTTP::Get.new(path)
  request["Authorization"] = "Bearer #{token}" if token
  http.request(request)
end

begin
  check.("401 without the token", get.("/api/v1/nodes", token: nil).code == "401")
  check.("401 with a wrong token", get.("/api/v1/nodes", token: "wrong").code == "401")
  nodes = get.("/api/v1/nodes")
  check.("200 with the token, over a connection that trusts the certificate authority", nodes.code == "200")
  items = JSON.parse(nodes.body).fetch("items")
  check.("four nodes, one not ready", items.size == 4 && items.count { |node| node.dig("status", "conditions").any? { |condition| condition["type"] == "Ready" && condition["status"] != "True" } } == 1)
  check.("the certificate also serves localhost", get.("/api/v1/nodes", host: "localhost").code == "200")
  check.("three metrics entries", JSON.parse(get.("/apis/metrics.k8s.io/v1beta1/nodes").body).fetch("items").size == 3)
  page = JSON.parse(get.("/api/v1/pods?limit=20").body)
  check.("pods are paged: 20 and a continue token", page.fetch("items").size == 20 && page.dig("metadata", "continue") == "20")
  check.("the last page has no continue token", !JSON.parse(get.("/api/v1/pods?limit=20&continue=40").body).fetch("metadata").key?("continue"))
  server.metrics_missing = true
  check.("404 for metrics when missing", get.("/apis/metrics.k8s.io/v1beta1/nodes").code == "404")
  server.forbidden_paths = ["/api/v1/pods"]
  check.("403 for a forbidden path", get.("/api/v1/pods").code == "403")
  check.("requests are recorded with Host and Authorization", begin
    last_request = server.seen_requests.last
    last_request[:method] == "GET" && last_request[:path] == "/api/v1/pods" && last_request[:host] == "127.0.0.1:#{server.port}" &&
      last_request[:authorization] == "Bearer #{FakeKubernetesApi::TOKEN}"
  end)
  server.reset!
  unserialisable_answer = Object.new
  def unserialisable_answer.to_json(*) = raise("cannot serialise this answer")
  server.nodes_answer = { "items" => unserialisable_answer }
  original_stderr = $stderr
  $stderr = StringIO.new
  fault = get.("/api/v1/nodes")
  logged_fault = $stderr.string
  $stderr = original_stderr
  check.("a fault inside the fake answers 500 with the message and is logged, not a silent close",
         fault.code == "500" && fault.body.include?("InternalError") && logged_fault.include?("FakeKubernetesApi fault"))
  server.reset!
  untrusted =Net::HTTP.new("127.0.0.1", server.port)
  untrusted.use_ssl = true
  check.("a client that does not trust the certificate authority is refused", begin
    untrusted.get("/api/v1/nodes")
    false
  rescue OpenSSL::SSL::SSLError
    true
  end)
ensure
  server.stop
end

puts(failures.empty? ? "all checks passed" : "#{failures.size} failed")
exit(failures.empty? ? 0 : 1)
