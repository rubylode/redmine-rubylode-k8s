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

require "openssl"

module RubylodeK8s
  # The rule for where a token may travel: over https only, loopback included.
  module SecureTransport
    CERTIFICATE_PATTERN = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m

    def self.allowed?(uri)
      uri.scheme == "https" && !uri.host.to_s.empty?
    end

    def self.certificates_in(certificate_authority_pem)
      certificate_authority_pem.to_s.scan(CERTIFICATE_PATTERN)
    end

    # The certificates to trust: every one in the text, or the system's own when the text holds none.
    def self.certificate_store_for(certificate_authority_pem)
      store = OpenSSL::X509::Store.new
      certificates = certificates_in(certificate_authority_pem)
      if certificates.empty?
        store.set_default_paths
      else
        certificates.each { |certificate| store.add_cert(OpenSSL::X509::Certificate.new(certificate)) }
      end
      store
    end
  end
end
