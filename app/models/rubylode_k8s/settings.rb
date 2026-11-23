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

module RubylodeK8s
  # The saved plugin settings, read into plain values.
  class Settings
    PLUGIN_ID = "redmine_rubylode_k8s".freeze
    COMMENT_PREFIX = "#".freeze
    DEFAULT_BLOCK_TITLE = "Kubernetes".freeze
    DEFAULT_PENDING_GRACE_MINUTES = 5
    DEFAULT_RESTART_THRESHOLD = 5
    DEFAULT_CACHE_SECONDS = 60
    DEFAULT_FAILURE_CACHE_SECONDS = 30
    DEFAULT_TIMEOUT_SECONDS = 3
    VISIBILITIES = %w[logged_in admins].freeze
    COLUMNS = %w[left right].freeze
    # Only variables meant for this plugin may be read, so the settings cannot send another secret (the secret key
    # base, a database password) to an address of the administrator's choosing.
    TOKEN_VARIABLE_PATTERN = /\AK8S_[A-Z0-9_]+\z/

    # One cluster from a line `Name | address | token variable | certificate authority variable`. The token and the
    # certificate authority are read from the environment each time they are needed and never stored in the settings.
    # Without a certificate authority the system's trusted ones are used.
    # A line `Name | in-cluster` is the cluster this server runs in: it uses the pod's service account, whose token and
    # certificate authority are files that are read on every call.
    Cluster = Struct.new(:name, :address, :token_variable, :certificate_authority_variable, :in_cluster, keyword_init: true) do
      # Stripped, as the token file is: a token from a Kubernetes secret often ends in a newline, and CR or LF in the
      # header would fail every call.
      def token
        in_cluster ? InClusterAccount.token : environment_value(token_variable).strip
      end

      # The one rule for "there is a token variable value": the page and the client both go by the stripped token.
      def token_set?
        !token.empty?
      end

      def certificate_authority_pem
        in_cluster ? InClusterAccount.certificate_authority_pem : environment_value(certificate_authority_variable)
      end

      # A variable holding only spaces or line breaks is as good as unset.
      def certificate_authority_variable_set?
        !certificate_authority_pem.strip.empty?
      end

      # Only a cluster without a certificate authority variable (and not in-cluster) may use the system's store.
      def certificate_authority_required?
        in_cluster || !certificate_authority_variable.to_s.empty?
      end

      private

      def environment_value(variable)
        return "" unless TOKEN_VARIABLE_PATTERN.match?(variable.to_s)

        ENV.fetch(variable, "").to_s
      end
    end

    def self.current
      new(Setting.send(:"plugin_#{PLUGIN_ID}") || {})
    end

    def initialize(values)
      @values = values.to_h.transform_keys(&:to_s)
    end

    def clusters
      @values["clusters"].to_s.lines.map(&:strip).reject { |line| line.empty? || line.start_with?(COMMENT_PREFIX) }.map do |line|
        name, address, token_variable, certificate_authority_variable = line.split("|", 4).map(&:strip)
        if token_variable.nil? && address == InClusterAccount::KEYWORD
          next Cluster.new(name: name.to_s, address: InClusterAccount.address, token_variable: "", certificate_authority_variable: "", in_cluster: true)
        end

        Cluster.new(name: name.to_s, address: address.to_s.chomp("/"), token_variable: token_variable.to_s,
                    certificate_authority_variable: certificate_authority_variable.to_s, in_cluster: false)
      end
    end

    # The link patterns of one cluster from the Links setting; each is empty when the cluster has no line or that pattern.
    LinkPatterns = Struct.new(:cluster, :node, :pod, keyword_init: true)

    # One line per cluster: Name | cluster link | node link | pod link.
    def links_for(cluster_name)
      @values["links"].to_s.lines.map(&:strip).reject { |line| line.empty? || line.start_with?(COMMENT_PREFIX) }.each do |line|
        name, cluster, node, pod = line.split("|", 4).map(&:strip)
        return LinkPatterns.new(cluster: cluster.to_s, node: node.to_s, pod: pod.to_s) if name == cluster_name
      end
      LinkPatterns.new(cluster: "", node: "", pod: "")
    end

    # The address the visible "Open the cluster's page" link goes to: the cluster link of that cluster, when it is an
    # http or https address. Nil when there is none, so no link is drawn.
    def source_link_address(cluster_name)
      LinkTemplate.link_for(links_for(cluster_name).cluster)
    end

    def block_title
      title = @values["block_title"].to_s.strip
      title.empty? ? DEFAULT_BLOCK_TITLE : title
    end

    def visibility
      VISIBILITIES.include?(@values["visibility"].to_s) ? @values["visibility"].to_s : "logged_in"
    end

    # Anonymous never; the signed in, or administrators only.
    def visible_to?(user)
      return false unless user&.logged?

      visibility == "admins" ? user.admin? : true
    end

    def show_on_welcome_page?
      flag?("show_on_welcome_page")
    end

    def welcome_page_column
      column("welcome_page_column")
    end

    def show_on_my_page?
      flag?("show_on_my_page")
    end

    def show_on_project_overview?
      flag?("show_on_project_overview")
    end

    def project_overview_column
      column("project_overview_column")
    end

    def show_in_top_menu?
      flag?("show_in_top_menu")
    end

    def show_on_matching_pages?
      flag?("show_on_matching_pages")
    end

    def matching_page_paths_text
      @values["matching_page_paths"].to_s
    end

    # The path patterns of the list, empty while the box is off.
    def matching_page_patterns
      show_on_matching_pages? ? PathMatcher.parse(matching_page_paths_text).patterns : []
    end

    # Minutes a pod may stay Pending before it counts as in trouble.
    def pending_grace_minutes
      whole_number("pending_grace_minutes", default: DEFAULT_PENDING_GRACE_MINUTES, minimum: 0)
    end

    # Restarts in all, with the last one within the hour, from which a container counts as restarting.
    def restart_threshold
      whole_number("restart_threshold", default: DEFAULT_RESTART_THRESHOLD, minimum: 1)
    end

    # Namespaces whose pods are never listed, from names separated by commas, spaces or lines.
    def namespaces_to_ignore
      @values["namespaces_to_ignore"].to_s.split(/[\s,]+/).reject(&:empty?)
    end

    # Seconds a report is kept. A typed 0 means no caching; an empty field means the default.
    def cache_seconds
      whole_number("cache_seconds", default: DEFAULT_CACHE_SECONDS, minimum: 0)
    end

    # Seconds a failed cluster is not asked again. A typed 0 means it is asked every time.
    def failure_cache_seconds
      whole_number("failure_cache_seconds", default: DEFAULT_FAILURE_CACHE_SECONDS, minimum: 0)
    end

    # Seconds to connect, and to wait for each read. Never 0, which would fail every call at once.
    def timeout_seconds
      whole_number("timeout_seconds", default: DEFAULT_TIMEOUT_SECONDS, minimum: 1)
    end

    private

    def flag?(key)
      @values[key].to_s == "1"
    end

    def column(key)
      COLUMNS.include?(@values[key].to_s) ? @values[key].to_s : "right"
    end

    # A setting that is a whole number, raised to the minimum; the default when it is empty or not one.
    def whole_number(name, default:, minimum:)
      text = @values[name].to_s.strip
      text.match?(/\A\d+\z/) ? [text.to_i, minimum].max : default
    end
  end
end
