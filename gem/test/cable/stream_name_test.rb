# frozen_string_literal: true

require "test_helper"

class CableStreamNameTest < SolidGcp::TestCase
  StreamName = SolidGcp::Cable::StreamName

  test "coerces string/symbol parts joined by colon" do
    assert_equal "job_runs", StreamName.from(:job_runs)
    assert_equal "a:b", StreamName.from("a", :b)
  end

  test "uses to_gid_param for GlobalID-able parts" do
    record = Struct.new(:gid) do
      def to_gid_param = "gid://app/Widget/7"
    end.new

    assert_equal "gid://app/Widget/7", StreamName.from(record)
  end

  test "doc id is sha256 of the stream name" do
    name = StreamName.from(:job_runs)
    assert_equal Digest::SHA256.hexdigest(name), StreamName.doc_id(name)
  end

  test "sign/verify round-trips" do
    name = StreamName.from(:job_runs)
    signed = StreamName.sign(name)

    assert_equal name, StreamName.verify(signed)
  end

  test "tampered signed name fails verification" do
    signed = StreamName.sign(StreamName.from(:job_runs))

    assert_nil StreamName.verify("#{signed}x")
    assert_nil StreamName.verify("garbage")
  end
end