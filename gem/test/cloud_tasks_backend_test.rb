# frozen_string_literal: true

require "test_helper"

class CloudTasksBackendTest < SolidGcp::TestCase
  # Fake client capturing create_task calls without touching Google.
  class FakeClient
    attr_reader :created

    def initialize
      @created = []
    end

    def queue_path(project:, location:, queue:)
      "projects/#{project}/locations/#{location}/queues/#{queue}"
    end

    def create_task(parent:, task:)
      @created << { parent: parent, task: task }
    end
  end

  def backend(client)
    SolidGcp::Backends::CloudTasks.new(client: client, config: SolidGcp.config)
  end

  test "builds a correct POST http_request task with OIDC" do
    client = FakeClient.new
    backend(client).enqueue(
      queue: "default",
      path: "/solid_gcp/perform",
      body: '{"solid_gcp":1}'
    )

    call = client.created.first
    assert_equal "projects/test-project/locations/us-central1/queues/solid-gcp-default", call[:parent]

    req = call[:task][:http_request]
    assert_equal :POST, req[:http_method]
    assert_equal "https://app.example.com/solid_gcp/perform", req[:url]
    assert_equal '{"solid_gcp":1}', req[:body]
    assert_equal "application/json", req[:headers]["Content-Type"]
    assert_equal "invoker@test-project.iam.gserviceaccount.com",
      req[:oidc_token][:service_account_email]
    assert_equal "https://app.example.com", req[:oidc_token][:audience]
    refute call[:task].key?(:schedule_time)
  end

  test "includes schedule_time when given" do
    client = FakeClient.new
    at = 3.minutes.from_now
    backend(client).enqueue(queue: "default", path: "/solid_gcp/perform",
      body: "{}", schedule_time: at)

    assert_in_delta at.to_f, client.created.first[:task][:schedule_time].to_f, 1.0
  end

  test "named tasks get a fully-qualified name" do
    client = FakeClient.new
    backend(client).enqueue(queue: "default", path: "/solid_gcp/sweep",
      body: "{}", name: "sweep-123")

    name = client.created.first[:task][:name]
    assert_equal "projects/test-project/locations/us-central1/queues/solid-gcp-default/tasks/sweep-123", name
  end
end
