require "test_helper"

class PaymentEmailTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "validates presence of message_id" do
    email = PaymentEmail.new(user: @user)
    assert_not email.valid?
    assert_includes email.errors[:message_id], "can't be blank"
  end

  test "validates uniqueness of message_id scoped to user" do
    PaymentEmail.create!(user: @user, message_id: "msg-12345", status: :pending)

    duplicate = PaymentEmail.new(user: @user, message_id: "msg-12345")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:message_id], "has already been taken"
  end

  test "defines status enum" do
    email = PaymentEmail.new(user: @user, message_id: "msg-12345", status: :matched)
    assert email.matched?
  end
end
