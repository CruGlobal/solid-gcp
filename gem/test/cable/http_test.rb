# frozen_string_literal: true

require "test_helper"

class CableHttpTest < SolidGcp::TestCase
  # Counts calls and replays a scripted sequence of responses/exceptions.
  class ScriptedHttp
    attr_reader :calls

    def initialize(*script)
      @script = script
      @calls = 0
    end

    def post(_url, _body, _headers)
      @calls += 1
      item = @script[@calls - 1] || @script.last
      raise item if item.is_a?(Class) && item <= Exception

      item
    end
  end

  def ok
    SolidGcp::Cable::Response.new(200, "{}")
  end

  test "2xx returns the response without retry" do
    http = ScriptedHttp.new(ok)
    response = SolidGcp::Cable.request(http, "u", "b", {}, action: "test")

    assert_equal 200, response.code
    assert_equal 1, http.calls
  end

  test "retries once on 5xx then raises HttpError with status + body excerpt" do
    http = ScriptedHttp.new(SolidGcp::Cable::Response.new(500, "boom-body"))

    error = assert_raises(SolidGcp::Cable::HttpError) do
      SolidGcp::Cable.request(http, "u", "b", {}, action: "Firestore commit")
    end

    assert_equal 2, http.calls, "5xx should be retried exactly once"
    assert_match(/Firestore commit failed \(500\)/, error.message)
    assert_match(/boom-body/, error.message)
    assert_kind_of SolidGcp::Error, error
  end

  test "5xx that recovers on retry returns the second response" do
    http = ScriptedHttp.new(SolidGcp::Cable::Response.new(503, "later"), ok)

    response = SolidGcp::Cable.request(http, "u", "b", {}, action: "test")

    assert_equal 200, response.code
    assert_equal 2, http.calls
  end

  test "4xx is never retried" do
    http = ScriptedHttp.new(SolidGcp::Cable::Response.new(400, "bad request"))

    error = assert_raises(SolidGcp::Cable::HttpError) do
      SolidGcp::Cable.request(http, "u", "b", {}, action: "signBlob")
    end

    assert_equal 1, http.calls, "4xx must not be retried"
    assert_match(/signBlob failed \(400\)/, error.message)
  end

  test "retries once on a transient network error then raises" do
    http = ScriptedHttp.new(Errno::ECONNRESET)

    error = assert_raises(SolidGcp::Cable::HttpError) do
      SolidGcp::Cable.request(http, "u", "b", {}, action: "test")
    end

    assert_equal 2, http.calls
    assert_match(/after retry/, error.message)
  end

  test "network error that recovers on retry succeeds" do
    http = ScriptedHttp.new(Net::OpenTimeout, ok)

    response = SolidGcp::Cable.request(http, "u", "b", {}, action: "test")

    assert_equal 200, response.code
    assert_equal 2, http.calls
  end

  # DefaultHttp must set explicit open/read timeouts so a hung endpoint can't
  # block a request thread indefinitely.
  test "DefaultHttp sets open and read timeouts" do
    recorder = Struct.new(:open_timeout, :read_timeout, :use_ssl).new
    def recorder.request(_req)
      fake = Object.new
      def fake.code = "200"
      def fake.body = "{}"
      fake
    end

    Net::HTTP.singleton_class.send(:alias_method, :orig_new, :new)
    Net::HTTP.define_singleton_method(:new) { |*| recorder }
    begin
      SolidGcp::Cable::DefaultHttp.new.post("https://example.com/x", "body", {})
    ensure
      Net::HTTP.define_singleton_method(:new, Net::HTTP.method(:orig_new))
      Net::HTTP.singleton_class.send(:remove_method, :orig_new)
    end

    assert_equal SolidGcp::Cable::OPEN_TIMEOUT, recorder.open_timeout
    assert_equal SolidGcp::Cable::READ_TIMEOUT, recorder.read_timeout
  end
end
