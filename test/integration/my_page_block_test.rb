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

class RubylodeK8sMyPageBlockTest < Redmine::IntegrationTest
  include RubylodeK8sTestHelpers

  fixtures :projects, :users, :email_addresses, :user_preferences, :roles, :members, :member_roles,
           :issue_statuses, :trackers, :projects_trackers, :enumerations, :enabled_modules

  setup do
    use_memory_cache
    start_fake_kubernetes
  end

  teardown do
    stop_fake_kubernetes
    restore_cache
  end

  test "the block is in Redmine's list of My page blocks, named Kubernetes" do
    assert Redmine::MyPage.blocks.key?("rubylode_k8s_status")
    assert_includes Redmine::MyPage.block_options.map(&:last), "rubylode_k8s_status"
    assert_includes Redmine::MyPage.block_options.map(&:first), "Kubernetes"
  end

  test "a person who added the block sees the status on My page" do
    preference = User.find(2).pref
    preference.my_page_layout = { "top" => ["rubylode_k8s_status"] }
    preference.save!

    log_user("jsmith", "jsmith")
    get "/my/page"

    assert_response :success
    assert_select "#block-rubylode_k8s_status .rubylode-k8s-summary", text: "1 of 4 nodes not ready, 4 pods in trouble"
  end
end
