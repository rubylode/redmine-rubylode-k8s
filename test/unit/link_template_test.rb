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

class RubylodeK8s::LinkTemplateTest < ActiveSupport::TestCase
  test "placeholders are replaced with percent-encoded values" do
    assert_equal "https://x.example.com/?search=a%20b%2Fc",
                 RubylodeK8s::LinkTemplate.expand("https://x.example.com/?search={pod}", pod: "a b/c")
    assert_equal "https://x.example.com/n/node-a/ns/kube-system",
                 RubylodeK8s::LinkTemplate.expand("https://x.example.com/n/{node}/ns/{namespace}", node: "node-a", namespace: "kube-system")
  end

  test "an unknown placeholder is left as written" do
    assert_equal "https://x.example.com/{other}/a", RubylodeK8s::LinkTemplate.expand("https://x.example.com/{other}/{pod}", pod: "a")
  end

  test "only an http or https address with a host is a link" do
    assert_equal "https://x.example.com/a", RubylodeK8s::LinkTemplate.link_for("https://x.example.com/{pod}", pod: "a")
    assert_nil RubylodeK8s::LinkTemplate.link_for("javascript:alert(1)")
    assert_nil RubylodeK8s::LinkTemplate.link_for("/relative/{pod}", pod: "a")
    assert_nil RubylodeK8s::LinkTemplate.link_for("{pod}", pod: "https://evil.example.com")
    assert_nil RubylodeK8s::LinkTemplate.link_for("")
  end

  test "a placeholder in the scheme, host or port never makes a link" do
    assert_nil RubylodeK8s::LinkTemplate.link_for("https://{pod}/x", pod: "evil.example.com")
    assert_nil RubylodeK8s::LinkTemplate.link_for("https://grafana.{node}/n", node: "evil.example.com")
    assert_nil RubylodeK8s::LinkTemplate.link_for("https://x.example.com:{pod}/", pod: "8080")
    assert_nil RubylodeK8s::LinkTemplate.link_for("https://x.example.com/{other}", pod: "a")
  end
end
