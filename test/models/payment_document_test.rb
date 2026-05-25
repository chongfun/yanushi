require "test_helper"

class PaymentDocumentTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "should be valid with all fields" do
    doc = PaymentDocument.new(
      user: @user,
      attachment_file: "some file bytes",
      attachment_filename: "receipt.pdf",
      attachment_content_type: "application/pdf"
    )
    assert doc.valid?
  end

  test "should require user, file, filename, content_type" do
    doc = PaymentDocument.new
    assert_not doc.valid?
    assert_includes doc.errors[:user], "must exist"
    assert_includes doc.errors[:attachment_file], "can't be blank"
    assert_includes doc.errors[:attachment_filename], "can't be blank"
    assert_includes doc.errors[:attachment_content_type], "can't be blank"
  end
end
