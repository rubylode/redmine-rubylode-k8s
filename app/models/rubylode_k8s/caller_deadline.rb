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

require "timeout"

module RubylodeK8s
  # Tells the time limit of whoever asked for the block apart from every other error. The plugin catches everything
  # else and turns it into "unavailable"; a caller's time limit alone goes on, so it is never cached as the cluster's
  # state and the caller can say it gave up.
  #
  # Classes are compared by name, so this works whether or not the plugin that raises them is installed. A subclass of
  # a listed class counts too.
  module CallerDeadline
    DEFAULT_CLASS_NAMES = ["RubylodeStatus::WidgetStatus::TookTooLong"].freeze

    class << self
      # The names of the classes that are a caller's time limit. Tests add their own and remove it afterwards.
      def class_names
        @class_names ||= DEFAULT_CLASS_NAMES.dup
      end

      # True when the error is a caller's time limit: a listed class, or what Timeout.timeout raises inside its block
      # when it was given no class.
      def raised?(error)
        return true if defined?(Timeout::ExitException) && error.is_a?(Timeout::ExitException)

        error.class.ancestors.any? { |ancestor| ancestor.name && class_names.include?(ancestor.name) }
      end
    end
  end
end
