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
  # Zeitwerk expects this file to define RubylodeK8s::Macros, so the registration lives in a method that init.rb calls.
  module Macros
    def self.register
      Redmine::WikiFormatting::Macros.register do
        desc <<~DESCRIPTION
          Shows the health of the nodes and the pods in trouble of the Kubernetes clusters set in the Rubylode Kubernetes settings.

            {{k8s_status}}
            {{k8s_status(title=Our clusters)}}

          Nothing is shown to people who are not allowed to see it.
        DESCRIPTION
        macro :k8s_status do |_object, arguments|
          _positional, options = extract_macro_options(arguments, :title)
          render partial: "rubylode_k8s/status", locals: { title: options[:title].presence }
        end
      end
    end
  end
end
