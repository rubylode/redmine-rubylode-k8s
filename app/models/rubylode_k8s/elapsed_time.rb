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
  # How long ago something was, in the short form the block prints: "14 min", "3 h", "2 d".
  module ElapsedTime
    module_function

    def short(seconds)
      seconds = [seconds.to_i, 0].max
      minutes = seconds / 60
      return I18n.t("rubylode_k8s.elapsed.minutes", count: minutes) if minutes < 60

      hours = minutes / 60
      return I18n.t("rubylode_k8s.elapsed.hours", count: hours) if hours < 24

      I18n.t("rubylode_k8s.elapsed.days", count: hours / 24)
    end
  end
end
