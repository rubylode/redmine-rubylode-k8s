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
require "net/http"

# The demo starts the fake with its timestamps shifted so the fixtures read as taken just now.
class RubylodeK8sFakeKubernetesApiShiftTest < ActiveSupport::TestCase
  def pods_answer_from(fake)
    store = OpenSSL::X509::Store.new
    store.add_cert(OpenSSL::X509::Certificate.new(FakeKubernetesApi.certificate_authority_pem))
    http = Net::HTTP.new("127.0.0.1", fake.port)
    http.use_ssl = true
    http.cert_store = store
    request = Net::HTTP::Get.new(FakeKubernetesApi::PODS_PATH)
    request["Authorization"] = "Bearer #{FakeKubernetesApi::TOKEN}"
    JSON.parse(http.request(request).body)
  end

  def import_pod(answer)
    answer.fetch("items").find { |pod| pod.dig("metadata", "name") == "import-28311-abcde" }
  end

  test "without the shift the fixtures keep their times" do
    fake = FakeKubernetesApi.new.start
    created = Time.parse(import_pod(pods_answer_from(fake)).dig("metadata", "creationTimestamp"))

    assert_equal FakeKubernetesApi::CAPTURED_AT - 14 * 60, created
  ensure
    fake&.stop
  end

  test "with the shift the capture moment lands on the moment the fake started" do
    before = Time.now.utc
    fake = FakeKubernetesApi.new(shift_to_now: true).start
    created = Time.parse(import_pod(pods_answer_from(fake)).dig("metadata", "creationTimestamp"))
    after = Time.now.utc

    assert_operator created, :>=, before - 14 * 60 - 1
    assert_operator created, :<=, after - 14 * 60 + 1
  ensure
    fake&.stop
  end
end
