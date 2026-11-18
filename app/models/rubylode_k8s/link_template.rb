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
  # A link pattern from the Links setting, with {node}, {namespace} and {pod} where a name goes. Each value is
  # percent-encoded as it goes in. A placeholder is never allowed before the first / after the scheme (in the user
  # information, host or port), because Kubernetes names are domain names: a pod called evil.example.com would
  # otherwise choose where the link goes. Only http and https addresses with a host are links; the token is never
  # part of one.
  module LinkTemplate
    PLACEHOLDER = /\{(\w+)\}/
    AUTHORITY = %r{\Ahttps?://([^/?\#]*)}i

    class << self
      # The pattern with every placeholder that has a value replaced; other placeholders stay as written.
      def expand(pattern, values = {})
        pattern.to_s.gsub(PLACEHOLDER) do |placeholder|
          key = Regexp.last_match(1).to_sym
          values.key?(key) ? ERB::Util.url_encode(values[key].to_s) : placeholder
        end
      end

      # The expanded address, or nil when the pattern is empty, has a placeholder in its scheme, user information, host or
      # port, leaves a placeholder unreplaced, or does not give an http or https address with a host.
      def link_for(pattern, values = {})
        pattern = pattern.to_s.strip
        return nil if pattern.empty? || !fixed_authority?(pattern)

        address = expand(pattern, values)
        address.match?(/[{}]/) || !web_address?(address) ? nil : address
      end

      # Whether everything up to the first / ? or # after http:// or https:// is written out, with no placeholder in it.
      def fixed_authority?(pattern)
        authority = pattern[AUTHORITY, 1]
        !authority.to_s.empty? && !authority.match?(/[{}]/)
      end

      def web_address?(address)
        uri = URI.parse(address.to_s)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? && uri.userinfo.nil?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
