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
  # A Kubernetes resource quantity ("250m", "3977412Ki", "1500000n") as an exact Rational.
  module Quantity
    BINARY = { "Ki" => 2**10, "Mi" => 2**20, "Gi" => 2**30, "Ti" => 2**40, "Pi" => 2**50, "Ei" => 2**60 }.freeze
    DECIMAL = { "n" => Rational(1, 10**9), "u" => Rational(1, 10**6), "m" => Rational(1, 1000), "" => 1,
                "k" => 10**3, "M" => 10**6, "G" => 10**9, "T" => 10**12, "P" => 10**15, "E" => 10**18 }.freeze
    PATTERN = /\A(\d+(?:\.\d+)?)(?:[eE]([+-]?\d+)|(Ki|Mi|Gi|Ti|Pi|Ei|[numkMGTPE]))?\z/

    # Longer text, and a power of ten past this, are read as not a quantity: 10**999999999 would hang the request.
    MAX_LENGTH = 64
    MAX_EXPONENT = 30

    # A Rational, or nil when the text is not a quantity.
    def self.parse(text)
      text = text.to_s.strip
      return nil if text.length > MAX_LENGTH

      match = PATTERN.match(text) or return nil
      number = Rational(match[1])
      if match[2]
        exponent = match[2].to_i
        return nil if exponent.abs > MAX_EXPONENT

        return number * Rational(10)**exponent
      end

      number * (BINARY[match[3]] || DECIMAL[match[3].to_s])
    end
  end
end
