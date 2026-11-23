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

require "redmine"

Redmine::Plugin.register :redmine_rubylode_k8s do
  name "Rubylode Kubernetes"
  author "Rubylode"
  author_url "https://github.com/rubylode"
  url "https://github.com/rubylode/redmine-rubylode-k8s"
  description "The health of the nodes and pods of one or more Kubernetes clusters, read from the Kubernetes API"
  version "1.1.0"
  requires_redmine version_or_higher: "5.1.0"

  # A link to the page in the top menu, shown only when the settings ask for it and only to the people allowed to see the block.
  # With Rubylode Status installed the block lives on its page, so this item goes.
  menu :top_menu, :rubylode_k8s_status, { controller: "rubylode_k8s_status", action: "show" },
       caption: proc { RubylodeK8s::Settings.current.block_title },
       if: proc {
         settings = RubylodeK8s::Settings.current
         !RubylodeK8s::StatusWidget.status_plugin_present? && settings.show_in_top_menu? && settings.visible_to?(User.current)
       }

  settings default: { "clusters" => "", "pending_grace_minutes" => "5", "restart_threshold" => "5",
                       "namespaces_to_ignore" => "", "links" => "", "cache_seconds" => "60", "failure_cache_seconds" => "30",
                       "timeout_seconds" => "3", "block_title" => "Kubernetes", "visibility" => "logged_in",
                       "show_on_welcome_page" => "0", "welcome_page_column" => "right", "show_on_my_page" => "0",
                       "show_on_project_overview" => "0", "project_overview_column" => "right", "show_in_top_menu" => "0",
                       "show_on_matching_pages" => "0", "matching_page_paths" => "" },
                partial: "settings/rubylode_k8s"
end

require_relative "lib/rubylode_k8s/macros"
RubylodeK8s::Macros.register
require_relative "lib/rubylode_k8s/hooks"
require_relative "lib/rubylode_k8s/settings_controller_patch"
require_relative "lib/rubylode_k8s/default_my_page_patch"
Redmine::MyPage.singleton_class.prepend(RubylodeK8s::DefaultMyPagePatch)

# Plugins load after the boot-time prepare callbacks have run, so apply the patch now and again after each code reload.
apply_settings_controller_patch = lambda do
  SettingsController.prepend RubylodeK8s::SettingsControllerPatch unless SettingsController.include?(RubylodeK8s::SettingsControllerPatch)
end
apply_settings_controller_patch.call
Rails.configuration.to_prepare(&apply_settings_controller_patch)

# Puts the block on the Status page when Rubylode Status is installed. See its docs/widget-contract.md.
# Redmine loads plugins in alphabetical order, so this plugin's init.rb may run before the Status plugin's: wait for all of them.
Rails.application.config.after_initialize do
  RubylodeK8s::StatusWidget.register
end
