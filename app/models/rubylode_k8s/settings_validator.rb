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

require "uri"

module RubylodeK8s
  # Checks the settings form before it is saved. Returns a list of messages, empty when everything is fine.
  # Empty values are fine where the plugin has a default or the setting is optional.
  class SettingsValidator
    NUMBER_FIELDS = { "cache_seconds" => 0, "failure_cache_seconds" => 0, "timeout_seconds" => 1,
                      "pending_grace_minutes" => 0, "restart_threshold" => 1 }.freeze
    NAMESPACE_PATTERN = /\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/
    MAXIMUM_LINK_FIELDS = 4
    # The placeholders each kind of link may hold, with a sample value that stands in for each while it is checked.
    LINK_SAMPLE_VALUES = { "cluster" => {}, "node" => { node: "node" }, "pod" => { namespace: "namespace", pod: "pod" } }.freeze

    def self.errors_for(raw_settings)
      new(raw_settings).errors
    end

    def initialize(raw_settings)
      @settings = (raw_settings || {}).to_h.stringify_keys
    end

    def errors
      messages = cluster_errors
      messages.concat(namespace_errors)
      messages.concat(link_errors)
      messages << t("column_invalid") unless columns_valid?
      messages << t("block_title_blank") if @settings.key?("block_title") && @settings["block_title"].to_s.strip.empty?
      messages << t("visibility_invalid") unless visibility_valid?
      messages.concat(number_errors)
      messages.concat(path_errors)
      messages
    end

    private

    def t(key, **options)
      I18n.t("rubylode_k8s.errors.#{key}", **options)
    end

    # Each line that holds something, with its line number in the text the person typed.
    def numbered_lines(key)
      @settings[key].to_s.lines.each_with_index.filter_map do |line, index|
        text = line.strip
        [index + 1, text] unless text.empty? || text.start_with?(Settings::COMMENT_PREFIX)
      end
    end

    def cluster_errors
      names = []
      numbered_lines("clusters").flat_map do |line_number, text|
        fields = text.split("|", -1).map(&:strip)
        problems = cluster_line_problems(fields, names)
        names << fields.first
        problems.map { |message| t("cluster_line_prefix", line_number: line_number, message: message) }
      end
    end

    def cluster_line_problems(fields, names)
      name, address, token_variable, certificate_authority_variable = fields
      problems = []
      problems << t("line_name_missing") if name.empty?
      problems << t("line_name_duplicate", name: name) if names.include?(name)
      if address == InClusterAccount::KEYWORD
        problems << t("in_cluster_takes_no_more_fields") if fields.size > 2
      elsif !(3..4).cover?(fields.size)
        problems << t("cluster_line_field_count", found: fields.size)
      else
        problems.concat(address_problems(address))
        problems << t("token_variable_invalid") unless token_variable.match?(Settings::TOKEN_VARIABLE_PATTERN)
        if !certificate_authority_variable.to_s.empty? && !certificate_authority_variable.match?(Settings::TOKEN_VARIABLE_PATTERN)
          problems << t("certificate_authority_variable_invalid")
        end
      end
      problems
    end

    def address_problems(address)
      uri = URI.parse(address)
      return [t("address_invalid")] unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
      return [t("address_has_extras")] if uri.userinfo || uri.query || uri.fragment
      return [t("plain_http_refused")] unless SecureTransport.allowed?(uri)

      []
    rescue URI::InvalidURIError
      [t("address_invalid")]
    end

    def namespace_errors
      numbered_lines("namespaces_to_ignore").filter_map do |line_number, text|
        next if NAMESPACE_PATTERN.match?(text)

        t("namespace_line_prefix", line_number: line_number, message: t("namespace_invalid", name: text))
      end
    end

    def link_errors
      known = Settings.new("clusters" => @settings["clusters"]).clusters.map(&:name)
      names = []
      numbered_lines("links").flat_map do |line_number, text|
        fields = text.split("|", -1).map(&:strip)
        problems = link_line_problems(fields, known, names)
        names << fields.first
        problems.map { |message| t("link_line_prefix", line_number: line_number, message: message) }
      end
    end

    def link_line_problems(fields, known, names)
      return [t("link_line_field_count", maximum: MAXIMUM_LINK_FIELDS, found: fields.size)] if fields.size > MAXIMUM_LINK_FIELDS

      name, *patterns = fields
      problems = []
      problems << t("line_name_missing") if name.empty?
      problems << t("line_name_duplicate", name: name) if names.include?(name)
      problems << t("link_unknown_cluster", name: name) if !name.empty? && !known.include?(name)
      %w[cluster node pod].zip(patterns).each do |kind, pattern|
        next if pattern.to_s.empty?

        problems.concat(link_pattern_problems(kind, pattern))
      end
      problems
    end

    def link_pattern_problems(kind, pattern)
      samples = LINK_SAMPLE_VALUES.fetch(kind)
      kind_name = t("link_kind_#{kind}")
      wrong = pattern.scan(LinkTemplate::PLACEHOLDER).flatten.uniq.reject { |name| samples.key?(name.to_sym) }
      return wrong.map { |name| t("link_placeholder_not_allowed", placeholder: "{#{name}}", kind: kind_name, allowed: allowed_placeholders(samples)) } if wrong.any?
      return [t("link_authority_has_placeholder", kind: kind_name)] if pattern.match?(%r{\Ahttps?://}i) && !LinkTemplate.fixed_authority?(pattern)

      LinkTemplate.link_for(pattern, samples) ? [] : [t("link_invalid", kind: kind_name)]
    end

    def allowed_placeholders(samples)
      samples.empty? ? t("link_no_placeholders") : samples.keys.map { |name| "{#{name}}" }.join(", ")
    end

    def columns_valid?
      %w[welcome_page_column project_overview_column].all? { |key| !@settings.key?(key) || Settings::COLUMNS.include?(@settings[key].to_s) }
    end

    def path_errors
      PathMatcher.parse(@settings["matching_page_paths"]).errors.map do |line_error|
        line_error.line_number.zero? ? line_error.message : t("path_line_prefix", line_number: line_error.line_number, message: line_error.message)
      end
    end

    def visibility_valid?
      !@settings.key?("visibility") || Settings::VISIBILITIES.include?(@settings["visibility"].to_s)
    end

    def number_errors
      NUMBER_FIELDS.filter_map do |key, minimum|
        value = @settings[key].to_s.strip
        next if value.empty?

        valid = value.match?(/\A\d+\z/) && value.to_i >= minimum
        t("number_invalid", field: I18n.t("rubylode_k8s.settings.#{key}.label"), minimum: minimum) unless valid
      end
    end
  end
end
