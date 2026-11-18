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
  # The service account a pod is given: where Kubernetes mounts its token and certificate authority. The token is
  # rotated by Kubernetes, so it is read again on every call and never kept.
  module InClusterAccount
    KEYWORD = "in-cluster".freeze
    ADDRESS = "https://kubernetes.default.svc".freeze
    DIRECTORY = "/var/run/secrets/kubernetes.io/serviceaccount".freeze
    TOKEN_FILE_NAME = "token".freeze
    CERTIFICATE_AUTHORITY_FILE_NAME = "ca.crt".freeze

    class << self
      # For tests: another address and another folder in place of the real ones. nil restores the real one.
      attr_writer :address, :directory

      def address
        @address || ADDRESS
      end

      def directory
        @directory || DIRECTORY
      end

      def token
        read_file(TOKEN_FILE_NAME).strip
      end

      def certificate_authority_pem
        read_file(CERTIFICATE_AUTHORITY_FILE_NAME)
      end

      def token_file_present?
        !token.empty?
      end

      def certificate_authority_file_present?
        !SecureTransport.certificates_in(certificate_authority_pem).empty?
      end

      private

      # The text of a file in the folder, or an empty text when it is missing or cannot be read.
      def read_file(name)
        File.read(File.join(directory, name))
      rescue SystemCallError
        ""
      end
    end
  end
end
