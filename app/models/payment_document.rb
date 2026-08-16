class PaymentDocument < ApplicationRecord
  belongs_to :user
  has_many :payment_ingestions, dependent: :destroy

  validates :attachment_file, presence: true
  validates :attachment_filename, presence: true
  validates :attachment_content_type, presence: true
  validates :status, presence: true

  before_destroy :prevent_destroy_if_confirmed_ingestions_exist, prepend: true

  enum :status, {
    processing: "processing",
    success: "success",
    failed: "failed"
  }

  def accounting_user
    user
  end

  private

    def prevent_destroy_if_confirmed_ingestions_exist
      if payment_ingestions.confirmed.exists?
        errors.add(:base, "Cannot delete document with confirmed payment ingestions")
        throw(:abort)
      end
    end
end
