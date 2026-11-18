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

# The macro can be rendered where there is no request at all, for example in a notification email.
class RubylodeK8sStatusPartialWithoutRequestTest < ActiveSupport::TestCase
  include RubylodeK8sTestHelpers

  fixtures :users, :email_addresses

  setup do
    use_memory_cache
    start_fake_kubernetes
    User.current = User.find(1)
  end

  teardown do
    User.current = nil
    stop_fake_kubernetes
    restore_cache
  end

  test "the partial renders without a request, and carries no stylesheet link" do
    view = ApplicationController.new.view_context
    assert_nil view.request

    html = view.render(partial: "rubylode_k8s/status")

    assert_includes html, "node-a"
    refute_includes html, "rubylode_k8s.css"
  end
end
