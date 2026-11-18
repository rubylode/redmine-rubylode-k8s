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

# Loads the demo data into the throwaway Redmine (bin/demo up runs it): two clusters, a person, a wiki page with the
# macro and the My page block. Safe to run again.
DEMO_PASSWORD = "demo-password-1".freeze
PLUGIN_ID = "redmine_rubylode_k8s".freeze

Redmine::DefaultData::Loader.load("en") if Tracker.none?
Setting.default_language = "en"
Setting.notified_events = [] # no mail from the demo
Setting.send_mail = nil if Setting.respond_to?(:send_mail=)

admin = User.find_by_login("admin")
admin.update_columns(must_change_passwd: false)
User.current = admin

# The fake cluster is reached by its service name over https. Its certificate authority and token are in the environment of
# the Redmine container (K8S_DEMO_CA, K8S_DEMO_TOKEN), never in these settings. Staging points at a closed port, so the
# page shows one cluster being unavailable while the other still answers. The links go to example.com, never a real host.
defaults = Redmine::Plugin.find(PLUGIN_ID).settings.fetch(:default)
Setting.send(:"plugin_#{PLUGIN_ID}=", defaults.merge(
  "clusters" => <<~LIST,
    Production | https://fake_kubernetes:8443 | K8S_DEMO_TOKEN | K8S_DEMO_CA
    Staging | https://fake_kubernetes:9 | K8S_DEMO_TOKEN | K8S_DEMO_CA
  LIST
  "links" => <<~LIST,
    Production | https://argocd.example.com/applications | https://nodes.example.com/{node} | https://argocd.example.com/applications?search={pod}
  LIST
  "show_on_welcome_page" => "1",
  "show_on_my_page" => "1",
  "show_on_project_overview" => "1",
  "show_on_matching_pages" => "1",
  "matching_page_paths" => "/issues",
  "show_in_top_menu" => "1",
  "cache_seconds" => "5",
  "failure_cache_seconds" => "5",
  "timeout_seconds" => "2"
))

sam = User.find_by_login("sam.rivera") || User.new(login: "sam.rivera", firstname: "Sam", lastname: "Rivera", mail: "sam.rivera@example.com",
                                                   language: "en").tap do |user|
  user.password = DEMO_PASSWORD
  user.password_confirmation = DEMO_PASSWORD
  user.must_change_passwd = false
  user.save!
end

project = Project.find_by(identifier: "operations") || Project.create!(name: "Operations", identifier: "operations", is_public: true,
                                                                       enabled_module_names: %w[wiki issue_tracking])
role = Role.find_by(name: "Developer")
Member.create!(project: project, user: sam, roles: [role]) if role && !project.members.exists?(user_id: sam.id)

project.create_wiki!(start_page: "Wiki") unless project.wiki
wiki = project.wiki
# The heading in the markup the demo's text formatting reads (Markdown or CommonMark unless it is Textile), so the
# screenshot shows a heading and not the raw markup. A page seeded earlier in the other markup is rewritten.
heading = Setting.text_formatting == "textile" ? "h1. Clusters" : "# Clusters"
wiki_text = "#{heading}\n\nWhat the clusters say right now:\n\n{{k8s_status}}\n"
page = wiki.find_page("Clusters")
if page.nil?
  page = WikiPage.new(wiki: wiki, title: "Clusters")
  page.content = WikiContent.new(text: wiki_text, author: admin)
  page.save!
elsif page.content.text != wiki_text
  page.content.text = wiki_text
  page.content.author = admin
  page.content.save!
end

[admin, sam].each do |user|
  preference = user.pref
  layout = preference.my_page_layout
  layout["top"] = (layout["top"].to_a | ["rubylode_k8s_status"])
  preference.my_page_layout = layout
  preference.save!
end
puts "demo data loaded"
