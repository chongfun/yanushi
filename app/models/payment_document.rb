class PaymentDocument < ShardedRecord
  belongs_to :user
  has_many :payment_ingestions, dependent: :destroy

  validates :attachment_file, presence: true
  validates :attachment_filename, presence: true
  validates :attachment_content_type, presence: true
  validates :status, presence: true

  enum :status, {
    processing: "processing",
    success: "success",
    failed: "failed"
  }
end
