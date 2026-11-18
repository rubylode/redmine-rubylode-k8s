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

class RubylodeK8sQuantityTest < ActiveSupport::TestCase
  PARSED = {
    "250m" => Rational(1, 4),
    "2" => 2,
    "1Gi" => 1_073_741_824,
    "3977412Ki" => 4_072_869_888,
    "1500000n" => Rational(3, 2000),
    "250u" => Rational(1, 4000),
    "1.5k" => 1500,
    "12e3" => 12_000,
    "1E" => 10**18
  }.freeze

  PARSED.each do |text, expected|
    test "#{text.inspect} parses to #{expected}" do
      assert_equal Rational(expected), RubylodeK8s::Quantity.parse(text)
    end
  end

  ["", "abc", "5Kb"].each do |text|
    test "#{text.inspect} is not a quantity" do
      assert_nil RubylodeK8s::Quantity.parse(text)
    end
  end

  test "an enormous exponent or a long text is refused quickly" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_nil RubylodeK8s::Quantity.parse("1e999999999")
    assert_nil RubylodeK8s::Quantity.parse("1e-999999999")
    assert_nil RubylodeK8s::Quantity.parse("1e31")
    assert_nil RubylodeK8s::Quantity.parse("1" * 65)
    assert_equal Rational(10)**30, RubylodeK8s::Quantity.parse("1e30")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end

  test "nothing is not a quantity" do
    assert_nil RubylodeK8s::Quantity.parse(nil)
  end
end
