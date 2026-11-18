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

class RubylodeK8sUsageLevelTest < ActiveSupport::TestCase
  test "below 80 percent is normal" do
    assert_equal :normal, RubylodeK8s::UsageLevel.for(79.4)
  end

  test "the level follows the rounded number the label shows" do
    assert_equal :warning, RubylodeK8s::UsageLevel.for(79.6)
    assert_equal :critical, RubylodeK8s::UsageLevel.for(89.6)
    assert_equal :warning, RubylodeK8s::UsageLevel.for(89.4)
  end

  test "a number that is not finite has no level and no width" do
    [Float::INFINITY, -Float::INFINITY, Float::NAN].each do |value|
      assert_nil RubylodeK8s::UsageLevel.for(value)
      assert_nil RubylodeK8s::UsageLevel.clamp(value)
    end
  end

  test "80 percent is a warning" do
    assert_equal :warning, RubylodeK8s::UsageLevel.for(80)
  end

  test "90 percent is critical" do
    assert_equal :critical, RubylodeK8s::UsageLevel.for(90)
  end

  test "no reading has no level" do
    assert_nil RubylodeK8s::UsageLevel.for(nil)
  end

  test "clamp gives a whole number from 0 to 100" do
    assert_equal 100, RubylodeK8s::UsageLevel.clamp(140.4)
    assert_equal 24, RubylodeK8s::UsageLevel.clamp(24.2)
    assert_nil RubylodeK8s::UsageLevel.clamp(nil)
  end
end
