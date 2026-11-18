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

require File.expand_path("../../../test/test_helper", __dir__)
require "logger"
require "stringio"
require_relative "support/fake_kubernetes_api"

module RubylodeK8sTestHelpers
  PLUGIN_ID = "redmine_rubylode_k8s"
  TOKEN_VARIABLE = "K8S_PRODUCTION_TOKEN"
  CERTIFICATE_AUTHORITY_VARIABLE = "K8S_PRODUCTION_CA"

  # Starts the fake Kubernetes API on a free port, puts its token and certificate authority in the environment and
  # points one cluster line at it.
  def start_fake_kubernetes(cache_seconds: "60")
    @fake_kubernetes = FakeKubernetesApi.new.start
    ENV[TOKEN_VARIABLE] = FakeKubernetesApi::TOKEN
    ENV[CERTIFICATE_AUTHORITY_VARIABLE] = FakeKubernetesApi.certificate_authority_pem
    configure_plugin("clusters" => "Production | #{@fake_kubernetes.url} | #{TOKEN_VARIABLE} | #{CERTIFICATE_AUTHORITY_VARIABLE}",
                     "cache_seconds" => cache_seconds)
    @fake_kubernetes
  end

  def stop_fake_kubernetes
    @fake_kubernetes&.stop
    ENV.delete(TOKEN_VARIABLE)
    ENV.delete(CERTIFICATE_AUTHORITY_VARIABLE)
  end

  def configure_plugin(overrides = {})
    defaults = Redmine::Plugin.find(PLUGIN_ID).settings[:default]
    Setting.send(:"plugin_#{PLUGIN_ID}=", defaults.merge(overrides.transform_keys(&:to_s)))
  end

  def use_memory_cache
    @original_cache = RubylodeK8s::ClusterStatus.cache
    RubylodeK8s::ClusterStatus.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def restore_cache
    RubylodeK8s::ClusterStatus.cache = @original_cache
  end

  # Runs the block with Rails.logger writing into a string, and returns that string.
  def captured_log
    output = StringIO.new
    replacing_method(Rails, :logger, ->(*) { Logger.new(output) }) { yield }
    output.string
  end

  # Stands in for the time limit of whoever asked for the block (Rubylode Status's TookTooLong): a StandardError that
  # the plugin must let through, once it is registered with CallerDeadline.
  class CallerDeadlineForTest < StandardError; end

  # An error of the plugin's own that nobody expected, with the token in its message, as net/http's header errors can.
  class UnexpectedErrorForTest < StandardError
    def initialize(message = "a header value carries #{FakeKubernetesApi::TOKEN}")
      super
    end
  end

  # Registers CallerDeadlineForTest as a caller's time limit for the length of the block.
  def with_caller_deadline_registered
    RubylodeK8s::CallerDeadline.class_names << CallerDeadlineForTest.name
    yield
  ensure
    RubylodeK8s::CallerDeadline.class_names.delete(CallerDeadlineForTest.name)
  end

  # Raises the error inside the given call to Kubernetes (1 nodes, 2 metrics, 3 the first page of pods), in the middle
  # of the request, while the token is being put on it.
  def raising_on_call(call_number, error)
    original = RubylodeK8s::SecureTransport.method(:certificate_store_for)
    calls = 0
    replacement = lambda do |*arguments|
      calls += 1
      raise error if calls == call_number

      original.call(*arguments)
    end
    replacing_method(RubylodeK8s::SecureTransport, :certificate_store_for, replacement) { yield }
  end

  def cached_report_for_first_cluster
    RubylodeK8s::ClusterStatus.cache.read(RubylodeK8s::ClusterStatus.cache_key_for(RubylodeK8s::Settings.current.clusters.first))
  end

  # Minitest 6 ships without stubs, so a singleton method is swapped by hand for the length of the block.
  def replacing_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name) { |*arguments, **keywords, &block| replacement.call(*arguments, **keywords, &block) }
    yield
  ensure
    target.define_singleton_method(name) { |*arguments, **keywords, &block| original.call(*arguments, **keywords, &block) }
  end

  # Stands in for Rubylode Status's registry: it only remembers what it was called with.
  class FakeStatusRegistry
    attr_reader :calls

    def initialize
      @calls = []
    end

    def register(**arguments)
      @calls << arguments
    end
  end

  def with_fake_status_registry
    registry = FakeStatusRegistry.new
    registry_module = Module.new
    registry_module.define_singleton_method(:register) { |**arguments| registry.register(**arguments) }
    Object.const_set(:RubylodeStatus, Module.new)
    RubylodeStatus.const_set(:Registry, registry_module)
    yield registry
  ensure
    Object.send(:remove_const, :RubylodeStatus) if Object.const_defined?(:RubylodeStatus)
  end
end
