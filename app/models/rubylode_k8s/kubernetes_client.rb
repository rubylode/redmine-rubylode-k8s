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

module RubylodeK8s
  # Asks one cluster's Kubernetes API for its nodes, with the cluster's token as a bearer token. Read-only.
  class KubernetesClient
    class Unavailable < StandardError
      attr_reader :status

      def initialize(message = nil, status: nil)
        super(message)
        @status = status
      end
    end

    PODS_PATH = "/api/v1/pods".freeze
    # Pods come in pages of this size, at most this many pages, and no new page is asked for once twice the timeout has
    # passed since the first (the way Argo CD bounds a long list). Whatever is left is not read, and the list says so.
    POD_PAGE_SIZE = 500
    POD_PAGE_LIMIT = 10
    DEADLINE_TIMEOUT_MULTIPLE = 2
    POD_FIELD_SELECTOR = "status.phase!=Succeeded".freeze
    PodList = Struct.new(:items, :truncated)
    NODES_PATH = "/api/v1/nodes".freeze
    NODE_METRICS_PATH = "/apis/metrics.k8s.io/v1beta1/nodes".freeze
    # The most of an answer that is read. Past it the call gives up.
    MAX_BODY_BYTES = 10 * 1024 * 1024
    LINE_BREAK = /[\r\n]/

    # A cluster that names a certificate authority variable never falls back to the system store: when the variable
    # holds no certificate the cluster is unavailable.
    # The token goes only to this cluster's address, over https with the cluster's certificate authority checked. A
    # redirect is never followed, so the token cannot reach another host. Every message is scrubbed of the token, and
    # no message of an error raised underneath is ever used, only its class.
    # The token is read once here, so one refresh uses one token.
    def initialize(cluster:, timeout_seconds:)
      @cluster = cluster
      @timeout_seconds = timeout_seconds
      @token = cluster.token
      @certificate_authority_pem = cluster.certificate_authority_pem
    end

    # The parsed answer of GET /api/v1/nodes. An answer that is not a list with items is unreadable, so the cluster is
    # unavailable and never shown as having no nodes.
    def nodes
      answer = get_json(NODES_PATH)
      raise Unavailable, I18n.t("rubylode_k8s.errors.answer_unreadable") unless answer.is_a?(Hash) && answer["items"].is_a?(Array)

      answer
    end

    # The parsed answer of GET /apis/metrics.k8s.io/v1beta1/nodes. A cluster without metrics-server answers 404.
    # An answer that is not a list with items is unreadable, so the bars say no metrics.
    def node_metrics
      answer = get_json(NODE_METRICS_PATH)
      raise Unavailable, I18n.t("rubylode_k8s.errors.answer_unreadable") unless answer.is_a?(Hash) && answer["items"].is_a?(Array)

      answer
    end

    # The pods that have not Succeeded, followed page by page. `truncated` is true when more were left unread because
    # of the page limit or the deadline. An answer that is not a pod list is Unavailable.
    def pods
      deadline = monotonic_seconds + @timeout_seconds * DEADLINE_TIMEOUT_MULTIPLE
      items = []
      continue_token = nil
      POD_PAGE_LIMIT.times do |page_index|
        return PodList.new(items, true) if page_index.positive? && monotonic_seconds > deadline

        answer = get_json(pods_path(continue_token))
        raise Unavailable, I18n.t("rubylode_k8s.errors.answer_unreadable") unless answer.is_a?(Hash) && answer["items"].is_a?(Array)

        items.concat(answer["items"])
        continue_token = answer.dig("metadata", "continue") if answer["metadata"].is_a?(Hash)
        return PodList.new(items, false) unless continue_token.is_a?(String) && !continue_token.empty?
      end
      PodList.new(items, true)
    end

    private

    def pods_path(continue_token)
      parameters = { "fieldSelector" => POD_FIELD_SELECTOR, "limit" => POD_PAGE_SIZE }
      parameters["continue"] = continue_token if continue_token
      "#{PODS_PATH}?#{URI.encode_www_form(parameters)}"
    end

    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def get_json(path)
      raise Unavailable, I18n.t("rubylode_k8s.errors.in_cluster_token_missing") if @token.empty? && @cluster.in_cluster
      raise Unavailable, I18n.t("rubylode_k8s.errors.token_missing", name: @cluster.name) if @token.empty?
      # Stripping took the line breaks off the ends; one left inside would split the header, so nothing is sent.
      if @token.match?(LINE_BREAK)
        raise Unavailable, I18n.t(@cluster.in_cluster ? "rubylode_k8s.errors.in_cluster_token_line_break" : "rubylode_k8s.errors.token_line_break", name: @cluster.name)
      end

      if @cluster.certificate_authority_required? && SecureTransport.certificates_in(@certificate_authority_pem).empty?
        raise Unavailable, I18n.t(@cluster.in_cluster ? "rubylode_k8s.errors.in_cluster_certificate_authority_missing" : "rubylode_k8s.errors.certificate_authority_missing", name: @cluster.name)
      end

      uri = URI("#{@cluster.address}#{path}")
      raise Unavailable, I18n.t("rubylode_k8s.errors.insecure_connection") unless SecureTransport.allowed?(uri)

      status, body = get(uri)
      raise Unavailable.new(I18n.t("rubylode_k8s.errors.redirect_refused"), status: status) if (300..399).cover?(status)
      raise Unavailable.new(I18n.t("rubylode_k8s.errors.kubernetes_status", status: status), status: status) unless status == 200

      JSON.parse(body)
    rescue Unavailable => error
      raise Unavailable.new(scrub(error.message), status: error.status)
    rescue JSON::ParserError
      raise Unavailable, I18n.t("rubylode_k8s.errors.answer_unreadable")
    rescue StandardError => error
      # Everything else (the network, TLS, net/http's own time limits, a header it refuses, a bug of ours) is the
      # cluster being unavailable, named by its class only: a message can carry the token. Only the time limit of
      # whoever asked goes on, so it is never cached as the cluster's state.
      raise if CallerDeadline.raised?(error)

      raise Unavailable, scrub(I18n.t("rubylode_k8s.errors.unreachable", error_class: error.class))
    end

    def scrub(message)
      @token.empty? ? message : message.gsub(@token, "[filtered]")
    end

    def get(uri)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/json"
      # hostname has no brackets round an IPv6 address; nil, nil keeps proxy settings in the environment from being used.
      http = Net::HTTP.new(uri.hostname, uri.port, nil, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert_store = SecureTransport.certificate_store_for(@certificate_authority_pem)
      http.open_timeout = @timeout_seconds
      http.read_timeout = @timeout_seconds
      # Net::HTTP retries a GET once after a read timeout, which doubles the wait and the calls to a stuck server.
      http.max_retries = 0
      answer = nil
      http.start do |connection|
        connection.request(request) { |response| answer = [response.code.to_i, read_limited_body(response)] }
      end
      answer
    end

    def read_limited_body(response)
      body = +""
      response.read_body do |chunk|
        body << chunk
        raise Unavailable, I18n.t("rubylode_k8s.errors.answer_too_large") if body.bytesize > MAX_BODY_BYTES
      end
      body
    end
  end
end
