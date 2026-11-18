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

require "socket"
require "openssl"
require "json"
require "uri"
require "time"

# A tiny stand-in for a Kubernetes API server, for the demo and the integration tests. Standard library only, so it
# loads without Redmine.
#
# It speaks https, because the plugin refuses plain http even on loopback. `FakeKubernetesApi.certificate_authority_pem`
# is the certificate authority (one per process, made with OpenSSL) that signs every server's certificate; a client that
# trusts it can reach the server on 127.0.0.1, localhost and any `host_names:` given. No certificate file is kept anywhere.
#
# It answers the calls the plugin makes from the scrubbed fixtures in test/support/fixtures/kubernetes, with the status
# codes and `Status` bodies a real API server gives:
#
#   GET /api/v1/nodes                            200 with the node list
#   GET /api/v1/pods                             200 with the pod list; `limit` and `continue` page through it, as
#                                                Kubernetes does (the `fieldSelector` is recorded, not applied)
#   GET /apis/metrics.k8s.io/v1beta1/nodes       200 with the node metrics, or 404 when `metrics_missing` is set
#
# Every call needs "Authorization: Bearer <token>" for one of `accepted_tokens` and answers 401 without it. Any other
# path answers 404, and any other method on these paths 405.
#
# It can be told to fail: `failure = "server_error"` (500), `"timeout"` (holds the connection for timeout_seconds, then
# closes it without an answer), or `"unauthorized"` (401 even with a good token). `redirect_to = "https://other"` makes it
# answer every call with a 302 to that base, which is how tests check that the token never follows a redirect to another
# host. `forbidden_paths = ["/api/v1/pods"]` answers those paths with 403, and `metrics_missing = true` answers the
# metrics path with 404, as a cluster without metrics-server does. Each request is recorded (method, path, query, Host
# and Authorization headers) in `seen_requests`, so tests can assert where a token went.
#
# For tests: `nodes_answer`, `pods_answer` and `metrics_answer` replace the fixture answers (a Hash, served as JSON),
# `accepted_tokens` can change between requests to rotate the token, and `pod_body_bytes = n` makes the pod list
# answer with a valid JSON body of n bytes.
#
# The same controls work over https for the demo: POST /__fail/<server_error|timeout|unauthorized|none>,
# POST /__redirect_to (body: a base URL, or empty to clear it), POST /__reset, GET /__requests (JSON).
#
# For the demo, `POST /__scenario/<all_ready|one_not_ready|no_metrics|unavailable>` resets the fake and sets that
# situation up: all_ready answers with every node Ready and no pod in trouble, one_not_ready is the fixtures as they
# are, no_metrics answers the metrics path with 404, and unavailable answers every call with a 500.
#
# `shift_to_now: true` moves every timestamp in the answers by the time between the fixtures' capture moment
# (CAPTURED_AT) and the moment the fake started, so the fixtures read as taken just now and "Pending 14 min" stays a
# fresh pod. Tests leave it off and keep the fixed times.
#
# Run it on its own:  ruby test/support/fake_kubernetes_api.rb
# (FAKE_KUBERNETES_PORT, FAKE_KUBERNETES_TOKEN and FAKE_KUBERNETES_HOST_NAMES to change it, and
# FAKE_KUBERNETES_SHIFT_TO_NOW=1 to shift the times). It then writes its certificate authority to
# FAKE_KUBERNETES_CA_PATH, for bin/demo.
class FakeKubernetesApi
  CAPTURED_AT = Time.utc(2026, 11, 16, 12)
  TOKEN = "fake.kubernetes.token-not-a-secret".freeze
  FIXTURES = File.expand_path("fixtures/kubernetes", __dir__).freeze
  FAILURES = %w[server_error timeout unauthorized].freeze
  NODES_PATH = "/api/v1/nodes".freeze
  PODS_PATH = "/api/v1/pods".freeze
  METRICS_PATH = "/apis/metrics.k8s.io/v1beta1/nodes".freeze
  KUBERNETES_PATHS = [NODES_PATH, PODS_PATH, METRICS_PATH].freeze
  CERTIFICATE_LIFETIME_SECONDS = 24 * 60 * 60
  CERTIFICATE_AUTHORITY_LOCK = Mutex.new
  TIMESTAMP = /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/
  SCENARIOS = %w[all_ready one_not_ready no_metrics unavailable].freeze
  # The pods of the fixtures that are in trouble (or about to be), left out of the all_ready scenario.
  PODS_IN_TROUBLE = %w[billing-api-7d9f6c-x2k4p import-28311-abcde cache-0 report-6f2b1-m3kd8 nightly-check-29110-zz9kq].freeze

  attr_reader :port
  attr_accessor :failure, :redirect_to, :timeout_seconds, :accepted_tokens, :forbidden_paths, :metrics_missing,
                :nodes_answer, :pods_answer, :metrics_answer, :pod_body_bytes

  # The certificate authority every fake server's certificate is signed by, as PEM text.
  def self.certificate_authority_pem
    certificate_authority.fetch(:certificate).to_pem
  end

  def self.certificate_authority
    CERTIFICATE_AUTHORITY_LOCK.synchronize do
      @certificate_authority ||= begin
        key = OpenSSL::PKey::EC.generate("prime256v1")
        certificate = new_certificate(subject: "Fake Kubernetes certificate authority", public_key: key, serial: 1)
        extensions = OpenSSL::X509::ExtensionFactory.new(certificate, certificate)
        certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
        certificate.add_extension(extensions.create_extension("keyUsage", "keyCertSign,cRLSign", true))
        certificate.sign(key, OpenSSL::Digest.new("SHA256"))
        { key: key, certificate: certificate }
      end
    end
  end

  def self.new_certificate(subject:, public_key:, serial:)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = serial
    certificate.subject = OpenSSL::X509::Name.parse("/CN=#{subject}")
    certificate.issuer = certificate.subject
    certificate.public_key = public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + CERTIFICATE_LIFETIME_SECONDS
    certificate
  end

  def initialize(accepted_tokens: [TOKEN], port: 0, host: "127.0.0.1", host_names: [], failure: nil, timeout_seconds: 5, shift_to_now: false)
    @accepted_tokens = Array(accepted_tokens)
    @host = host
    @requested_port = port
    @host_names = host_names
    @failure = failure
    @timeout_seconds = timeout_seconds
    @shift_seconds = shift_to_now ? Time.now.utc - CAPTURED_AT : 0
    @seen_requests = []
    @forbidden_paths = []
    @lock = Mutex.new
  end

  def start
    @server = OpenSSL::SSL::SSLServer.new(TCPServer.new(@host, @requested_port), ssl_context)
    @server.start_immediately = false
    @port = @server.to_io.addr[1]
    @thread = Thread.new { accept_loop }
    self
  end

  def stop
    @server&.close
    @thread&.join(2)
  end

  def url
    host = @host.include?(":") ? "[#{@host}]" : @host
    "https://#{host}:#{@port}"
  end

  def seen_requests
    @lock.synchronize { @seen_requests.dup }
  end

  def reset!
    @lock.synchronize { @seen_requests.clear }
    self.failure = nil
    self.redirect_to = nil
    self.forbidden_paths = []
    self.metrics_missing = false
    self.nodes_answer = nil
    self.pods_answer = nil
    self.metrics_answer = nil
    self.pod_body_bytes = nil
  end

  private

  def ssl_context
    authority = self.class.certificate_authority
    key = OpenSSL::PKey::EC.generate("prime256v1")
    certificate = self.class.new_certificate(subject: "fake-kubernetes-api", public_key: key, serial: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond))
    certificate.issuer = authority.fetch(:certificate).subject
    extensions = OpenSSL::X509::ExtensionFactory.new(authority.fetch(:certificate), certificate)
    certificate.add_extension(extensions.create_extension("basicConstraints", "CA:FALSE", true))
    certificate.add_extension(extensions.create_extension("keyUsage", "digitalSignature", true))
    certificate.add_extension(extensions.create_extension("extendedKeyUsage", "serverAuth"))
    certificate.add_extension(extensions.create_extension("subjectAltName", subject_alternative_names))
    certificate.sign(authority.fetch(:key), OpenSSL::Digest.new("SHA256"))

    context = OpenSSL::SSL::SSLContext.new
    context.cert = certificate
    context.key = key
    context
  end

  def subject_alternative_names
    names = ["127.0.0.1", "localhost", @host, *@host_names].uniq.reject { |name| name == "0.0.0.0" }
    names.map { |name| name.match?(/\A[\d.]+\z|:/) ? "IP:#{name}" : "DNS:#{name}" }.join(",")
  end

  def accept_loop
    loop do
      client = @server.accept
      Thread.new(client) { |connection| handle(connection) }
    rescue OpenSSL::SSL::SSLError
      next
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(client)
    client.sync_close = true
    client.accept
    request_line = client.gets.to_s
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = headers["content-length"] ? client.read(headers["content-length"].to_i).to_s : ""
    method, target = request_line.split(" ")
    status, content_type, payload = respond(method.to_s, target.to_s, headers, body)
    return if status == :hang

    client.write("HTTP/1.1 #{status}\r\nContent-Type: #{content_type}\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
    nil
  rescue StandardError => error
    report_fault(client, error)
  ensure
    client.close
  end

  # A bug in the fake itself must show: it goes to stderr and the client gets a 500 carrying the message.
  def report_fault(client, error)
    $stderr.puts "FakeKubernetesApi fault: #{error.class}: #{error.message}"
    payload = JSON.generate("kind" => "Status", "status" => "Failure", "reason" => "InternalError", "code" => 500, "message" => "#{error.class}: #{error.message}")
    client.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
    nil
  end

  def respond(method, target, headers, body)
    route, query = target.split("?", 2)
    params = URI.decode_www_form(query.to_s).to_h
    unless route.start_with?("/__")
      @lock.synchronize do
        @seen_requests << { method: method, path: route, query: params, host: headers["host"], authorization: headers["authorization"] }
      end
    end

    return control(method, route, body) if route.start_with?("/__")
    return ["302 Found\r\nLocation: #{redirect_to}#{target}", "text/plain; charset=utf-8", ""] if redirect_to
    return hang if failure == "timeout"
    return status_answer("500 Internal Server Error", "errors/server_error.json") if failure == "server_error"
    return status_answer("401 Unauthorized", "errors/unauthorized.json") if failure == "unauthorized" || !accepted?(headers["authorization"])
    return status_answer("404 Not Found", "errors/not_found.json") unless KUBERNETES_PATHS.include?(route)
    return status_answer("405 Method Not Allowed", "errors/method_not_allowed.json") unless method == "GET"
    return status_answer("403 Forbidden", "errors/forbidden.json") if forbidden_paths.include?(route)

    kubernetes_route(route, params)
  end

  def accepted?(authorization)
    accepted_tokens.any? { |token| authorization == "Bearer #{token}" }
  end

  def kubernetes_route(route, params)
    case route
    when NODES_PATH then json("200 OK", nodes_answer || read_fixture("nodes.json"))
    when PODS_PATH then pod_list(params)
    when METRICS_PATH
      return status_answer("404 Not Found", "errors/not_found.json") if metrics_missing

      json("200 OK", metrics_answer || read_fixture("node_metrics.json"))
    end
  end

  # With `limit`, the answer holds that many pods and a `continue` token for the next page, which is the offset.
  def pod_list(params)
    return ["200 OK", "application/json", padded_pod_list(pod_body_bytes)] if pod_body_bytes

    answer = pods_answer || read_fixture("pods.json")
    limit = params["limit"].to_i
    return json("200 OK", answer) unless limit.positive?

    offset = params["continue"].to_i
    items = answer.fetch("items")
    page = items[offset, limit] || []
    metadata = answer.fetch("metadata", {}).reject { |key, _| %w[continue remainingItemCount].include?(key) }
    next_offset = offset + limit
    metadata = metadata.merge("continue" => next_offset.to_s, "remainingItemCount" => items.size - next_offset) if next_offset < items.size
    json("200 OK", answer.merge("metadata" => metadata, "items" => page))
  end

  def padded_pod_list(bytes)
    skeleton = JSON.generate("kind" => "PodList", "apiVersion" => "v1", "metadata" => {}, "items" => [], "padding" => "")
    JSON.generate("kind" => "PodList", "apiVersion" => "v1", "metadata" => {}, "items" => [], "padding" => "x" * [bytes - skeleton.bytesize, 0].max)
  end

  def control(method, route, body)
    if method == "POST" && route.start_with?("/__fail/")
      mode = route.delete_prefix("/__fail/")
      return json("404 Not Found", "message" => "unknown failure") unless FAILURES.include?(mode) || mode == "none"

      self.failure = mode == "none" ? nil : mode
      json("200 OK", "failure" => failure)
    elsif method == "POST" && route == "/__redirect_to"
      self.redirect_to = body.strip.empty? ? nil : body.strip
      json("200 OK", "redirect_to" => redirect_to)
    elsif method == "POST" && route == "/__reset"
      reset!
      json("200 OK", "reset" => true)
    elsif method == "POST" && route.start_with?("/__scenario/")
      name = route.delete_prefix("/__scenario/")
      return json("404 Not Found", "message" => "unknown scenario") unless SCENARIOS.include?(name)

      apply_scenario(name)
      json("200 OK", "scenario" => name)
    elsif route == "/__requests"
      json("200 OK", seen_requests)
    else
      status_answer("404 Not Found", "errors/not_found.json")
    end
  end

  def apply_scenario(name)
    reset!
    case name
    when "all_ready"
      self.nodes_answer = all_nodes_ready
      self.pods_answer = fixture_pods_without(PODS_IN_TROUBLE)
    when "no_metrics" then self.metrics_missing = true
    when "unavailable" then self.failure = "server_error"
    end
  end

  def all_nodes_ready
    answer = read_fixture("nodes.json")
    answer.fetch("items").each do |node|
      node.fetch("status").fetch("conditions").each do |condition|
        condition["status"] = condition["type"] == "Ready" ? "True" : "False"
      end
    end
    answer
  end

  def fixture_pods_without(names)
    answer = read_fixture("pods.json")
    answer.merge("items" => answer.fetch("items").reject { |pod| names.include?(pod.dig("metadata", "name")) })
  end

  def hang
    sleep timeout_seconds
    [:hang]
  end

  def read_fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, name)))
  end

  def json(status, data)
    [status, "application/json", shifted(JSON.generate(data))]
  end

  # Every timestamp moved forward by the shift, so the fixtures' capture moment becomes the moment the fake started.
  def shifted(payload)
    return payload if @shift_seconds.zero?

    payload.gsub(TIMESTAMP) { |stamp| (Time.parse(stamp) + @shift_seconds).utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
  end

  def status_answer(status, fixture)
    [status, "application/json", File.read(File.join(FIXTURES, fixture))]
  end
end

if $PROGRAM_NAME == __FILE__
  server = FakeKubernetesApi.new(
    accepted_tokens: [ENV.fetch("FAKE_KUBERNETES_TOKEN", FakeKubernetesApi::TOKEN)],
    port: ENV.fetch("FAKE_KUBERNETES_PORT", "8443").to_i, host: "0.0.0.0",
    host_names: ENV.fetch("FAKE_KUBERNETES_HOST_NAMES", "").split(",").map(&:strip).reject(&:empty?),
    shift_to_now: ENV["FAKE_KUBERNETES_SHIFT_TO_NOW"] == "1"
  ).start
  certificate_authority_path = ENV["FAKE_KUBERNETES_CA_PATH"]
  File.write(certificate_authority_path, FakeKubernetesApi.certificate_authority_pem) if certificate_authority_path && !certificate_authority_path.empty?
  puts "Fake Kubernetes API on port #{server.port}"
  $stdout.flush
  sleep
end
