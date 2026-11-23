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

class RubylodeK8sSettingsSourceLinkTest < ActiveSupport::TestCase
  def settings_with(links)
    RubylodeK8s::Settings.new("links" => links)
  end

  test "the address is the cluster link of that cluster" do
    settings = settings_with("Production | https://argocd.example.com/applications | | \nStaging | https://staging.example.com/")

    assert_equal "https://argocd.example.com/applications", settings.source_link_address("Production")
    assert_equal "https://staging.example.com/", settings.source_link_address("Staging")
  end

  test "a cluster with an empty cluster link, or no line, has no address" do
    settings = settings_with("Production | | https://nodes.example.com/{node}")

    assert_nil settings.source_link_address("Production")
    assert_nil settings.source_link_address("Elsewhere")
    assert_nil RubylodeK8s::Settings.new({}).source_link_address("Production")
  end

  test "an address that is not http or https is no address" do
    assert_nil settings_with("Production | javascript:alert(1)").source_link_address("Production")
    assert_nil settings_with("Production | //evil.example.com/x").source_link_address("Production")
    assert_nil settings_with("Production | ftp://files.example.com/").source_link_address("Production")
  end
end
