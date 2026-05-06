require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "belongs to user" do
    session = sessions(:one)
    assert_instance_of User, session.user
  end
end
