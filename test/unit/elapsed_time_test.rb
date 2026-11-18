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

require_relative "../test_helper"

class RubylodeK8sElapsedTimeTest < ActiveSupport::TestCase
  {
    0 => "0 min", 59 => "0 min", 840 => "14 min", 3599 => "59 min",
    3600 => "1 h", 10_800 => "3 h", 86_399 => "23 h",
    86_400 => "1 d", 172_800 => "2 d", -30 => "0 min"
  }.each do |seconds, expected|
    test "#{seconds} seconds is #{expected}" do
      assert_equal expected, RubylodeK8s::ElapsedTime.short(seconds)
    end
  end
end
