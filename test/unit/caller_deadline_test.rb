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


require "net/http"
require "timeout"
require_relative "../test_helper"

class RubylodeK8sCallerDeadlineTest < ActiveSupport::TestCase
  include RubylodeK8sTestHelpers

  # Defines RubylodeStatus::WidgetStatus::TookTooLong the way Rubylode Status does, for the length of the block.
  def with_status_plugin_time_limit
    status_module = Module.new
    widget_status = Class.new
    widget_status.const_set(:TookTooLong, Class.new(StandardError))
    status_module.const_set(:WidgetStatus, widget_status)
    Object.const_set(:RubylodeStatus, status_module)
    yield RubylodeStatus::WidgetStatus::TookTooLong
  ensure
    Object.send(:remove_const, :RubylodeStatus) if Object.const_defined?(:RubylodeStatus)
  end

  test "Rubylode Status's time limit is a caller's deadline, known by name, and so is a subclass of it" do
    with_status_plugin_time_limit do |took_too_long|
      assert RubylodeK8s::CallerDeadline.raised?(took_too_long.new)
      assert RubylodeK8s::CallerDeadline.raised?(Class.new(took_too_long).new)
    end
  end

  test "what Timeout.timeout raises inside its block when given no class is a caller's deadline" do
    assert defined?(Timeout::ExitException), "this Ruby's timeout has no ExitException"
    assert RubylodeK8s::CallerDeadline.raised?(Timeout::ExitException.new)
  end

  test "the plugin's own errors, net/http's time limits included, are not a caller's deadline" do
    [TypeError.new, ArgumentError.new, Net::ReadTimeout.new, Net::OpenTimeout.new, Timeout::Error.new, IOError.new,
     RubylodeK8s::KubernetesClient::Unavailable.new("down"), UnexpectedErrorForTest.new].each do |error|
      refute RubylodeK8s::CallerDeadline.raised?(error), error.class.name
    end
  end

  test "a registered class name counts, and stops counting once removed" do
    refute RubylodeK8s::CallerDeadline.raised?(CallerDeadlineForTest.new)
    with_caller_deadline_registered { assert RubylodeK8s::CallerDeadline.raised?(CallerDeadlineForTest.new) }
    refute RubylodeK8s::CallerDeadline.raised?(CallerDeadlineForTest.new)
    assert_equal RubylodeK8s::CallerDeadline::DEFAULT_CLASS_NAMES, RubylodeK8s::CallerDeadline.class_names
  end
end
