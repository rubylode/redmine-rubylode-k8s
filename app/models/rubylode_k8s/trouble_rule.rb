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


require "time"

module RubylodeK8s
  # Decides whether one pod, as the Kubernetes API describes it, is in trouble, and says why. The time is given, never
  # read, so the same pod gives the same answer in a test. Anything of an unexpected shape is read as absent.
  class TroubleRule
    WAITING_REASONS = %w[CrashLoopBackOff ImagePullBackOff ErrImagePull CreateContainerConfigError
                         CreateContainerError InvalidImageName RunContainerError].freeze
    RECENT_SECONDS = 3600
    OUT_OF_MEMORY_REASON = "OOMKilled".freeze

    # nil when the pod is fine, else a hash of reason, message, restart_count, last_restart_at and pending_since. The
    # first rule that matches wins.
    def self.trouble_for(pod, now:, pending_grace_minutes:, restart_threshold:)
      new(pod, now, pending_grace_minutes, restart_threshold).trouble
    end

    def initialize(pod, now, pending_grace_minutes, restart_threshold)
      @pod = pod.is_a?(Hash) ? pod : {}
      @now = now
      @pending_grace_minutes = pending_grace_minutes
      @restart_threshold = restart_threshold
    end

    def trouble
      waiting_trouble || failed_trouble || pending_trouble || out_of_memory_trouble || restarting_trouble
    end

    private

    def phase
      text_at(@pod, "status", "phase")
    end

    def statuses
      @statuses ||= %w[initContainerStatuses containerStatuses].flat_map { |key| hashes(hash_at(@pod, "status")[key]) }
    end

    def waiting_trouble
      status = statuses.find { |candidate| WAITING_REASONS.include?(text_at(candidate, "state", "waiting", "reason")) }
      return nil unless status

      result(text_at(status, "state", "waiting", "reason"), message: text_at(status, "state", "waiting", "message"),
             restart_count: restart_count_of(status), last_restart_at: finished_at_of(status, "lastState"))
    end

    def failed_trouble
      return nil unless phase == "Failed"

      result(text_at(@pod, "status", "reason").presence || "Failed", message: text_at(@pod, "status", "message"))
    end

    def pending_trouble
      return nil unless phase == "Pending"

      created_at = time_at(@pod, "metadata", "creationTimestamp")
      return nil unless created_at && @now - created_at >= @pending_grace_minutes * 60

      scheduling = hashes(hash_at(@pod, "status")["conditions"]).find { |condition| condition["type"] == "PodScheduled" && condition["status"] == "False" }
      result("Pending", message: scheduling && scheduling["message"].to_s.presence, pending_since: created_at)
    end

    def out_of_memory_trouble
      statuses.each do |status|
        %w[state lastState].each do |key|
          next unless text_at(status, key, "terminated", "reason") == OUT_OF_MEMORY_REASON

          finished_at = finished_at_of(status, key)
          return result(OUT_OF_MEMORY_REASON, restart_count: restart_count_of(status), last_restart_at: finished_at) if recent?(finished_at)
        end
      end
      nil
    end

    def restarting_trouble
      status = statuses.find { |candidate| restart_count_of(candidate) >= @restart_threshold && recent?(finished_at_of(candidate, "lastState")) }
      return nil unless status

      result("Restarting", restart_count: restart_count_of(status), last_restart_at: finished_at_of(status, "lastState"))
    end

    def result(reason, message: nil, restart_count: nil, last_restart_at: nil, pending_since: nil)
      { reason: reason, message: message, restart_count: restart_count, last_restart_at: last_restart_at, pending_since: pending_since }
    end

    def recent?(time)
      !time.nil? && @now - time < RECENT_SECONDS
    end

    def restart_count_of(status)
      status["restartCount"].is_a?(Integer) ? status["restartCount"] : 0
    end

    def finished_at_of(status, state_key)
      time_at(status, state_key, "terminated", "finishedAt")
    end

    def hashes(value)
      value.is_a?(Array) ? value.select { |element| element.is_a?(Hash) } : []
    end

    def hash_at(source, *keys)
      value = keys.reduce(source) { |current, key| current.is_a?(Hash) ? current[key] : nil }
      value.is_a?(Hash) ? value : {}
    end

    def text_at(source, *keys)
      value = keys.reduce(source) { |current, key| current.is_a?(Hash) ? current[key] : nil }
      value.is_a?(String) ? value : nil
    end

    def time_at(source, *keys)
      text = text_at(source, *keys)
      text && Time.iso8601(text)
    rescue ArgumentError
      nil
    end
  end
end
