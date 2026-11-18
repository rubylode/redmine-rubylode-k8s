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

class RubylodeK8sTroubleRuleTest < ActiveSupport::TestCase
  NOW = FakeKubernetesApi::CAPTURED_AT
  PODS = JSON.parse(File.read(File.expand_path("../support/fixtures/kubernetes/pods.json", __dir__))).fetch("items")

  def pod_named(prefix)
    PODS.find { |pod| pod.dig("metadata", "name").start_with?(prefix) }
  end

  def trouble_for(pod, pending_grace_minutes: 5, restart_threshold: 5)
    RubylodeK8s::TroubleRule.trouble_for(pod, now: NOW, pending_grace_minutes: pending_grace_minutes, restart_threshold: restart_threshold)
  end

  def running_pod(restart_count:, finished_at:, state: { "running" => {} })
    { "metadata" => { "name" => "inline", "namespace" => "shop", "creationTimestamp" => "2026-11-10T00:00:00Z" },
      "status" => { "phase" => "Running", "containerStatuses" => [
        { "restartCount" => restart_count, "state" => state,
          "lastState" => { "terminated" => { "reason" => "Error", "finishedAt" => finished_at.utc.iso8601 } } }
      ] } }
  end

  test "a container waiting in CrashLoopBackOff is in trouble with its restarts" do
    trouble = trouble_for(pod_named("billing-api"))

    assert_equal "CrashLoopBackOff", trouble[:reason]
    assert_equal 12, trouble[:restart_count]
    assert_equal Time.utc(2026, 11, 16, 11, 52), trouble[:last_restart_at]
  end

  test "a pod pending past the grace is in trouble with the scheduler's message" do
    trouble = trouble_for(pod_named("import"))

    assert_equal "Pending", trouble[:reason]
    assert_equal "0/3 nodes are available: insufficient memory", trouble[:message]
    assert_equal Time.utc(2026, 11, 16, 11, 46), trouble[:pending_since]
  end

  test "a container killed for memory within the hour is OOMKilled" do
    trouble = trouble_for(pod_named("cache-0"))

    assert_equal "OOMKilled", trouble[:reason]
    assert_equal 1, trouble[:restart_count]
  end

  test "a failed pod gives its reason" do
    assert_equal "Error", trouble_for(pod_named("nightly-check"))[:reason]
  end

  test "seven restarts three hours ago and a pod pending two minutes are not in trouble" do
    assert_nil trouble_for(pod_named("web"))
    assert_nil trouble_for(pod_named("report"))
  end

  test "restarting depends on the threshold" do
    pod = running_pod(restart_count: 7, finished_at: NOW - 600)

    assert_equal "Restarting", trouble_for(pod, restart_threshold: 7)[:reason]
    assert_nil trouble_for(pod, restart_threshold: 8)
  end

  test "an old restart is not restarting however many there were" do
    assert_nil trouble_for(running_pod(restart_count: 50, finished_at: NOW - 7200))
  end

  test "a longer grace forgives the pending pod" do
    assert_nil trouble_for(pod_named("import"), pending_grace_minutes: 15)
  end

  test "an init container waiting in ImagePullBackOff counts" do
    pod = { "metadata" => { "name" => "init" }, "status" => { "phase" => "Pending",
      "initContainerStatuses" => [{ "restartCount" => 0, "state" => { "waiting" => { "reason" => "ImagePullBackOff", "message" => "Back-off pulling image" } } }] } }

    assert_equal "ImagePullBackOff", trouble_for(pod)[:reason]
  end

  test "a pod of the wrong shape is not in trouble and does not raise" do
    assert_nil trouble_for("nonsense")
    assert_nil trouble_for({ "status" => { "containerStatuses" => "x", "phase" => ["Pending"] }, "metadata" => [] })
  end
end
