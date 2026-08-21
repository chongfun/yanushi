class SourceDocument < ApplicationRecord
  belongs_to :user
  has_many :imported_transactions, dependent: :destroy

  enum :document_type, {
    unknown: "unknown",
    zelle: "zelle",
    venmo: "venmo",
    chase_statement: "chase_statement"
  }, validate: true

  enum :status, {
    processing: "processing",
    success: "success",
    failed: "failed"
  }, validate: true

  before_validation :compute_attachment_sha256, on: :create

  validates :attachment_file, presence: true
  validates :attachment_filename, presence: true
  validates :attachment_content_type, presence: true
  validates :attachment_sha256, presence: true
  validates :attachment_sha256, uniqueness: { scope: :user_id, message: "has already been uploaded" }
  validates :status, presence: true
  validates :document_type, presence: true

  validate :prevent_immutable_attributes_mutation, on: :update
  validate :prevent_mutation_if_confirmed_transactions_exist, on: :update

  before_destroy :prevent_destroy_if_confirmed_transactions_exist, prepend: true

  def accounting_user
    user
  end

  private

    def compute_attachment_sha256
      if attachment_file.present? && attachment_sha256.blank?
        self.attachment_sha256 = Digest::SHA256.hexdigest(attachment_file.to_s)
      end
    end

    def prevent_immutable_attributes_mutation
      if will_save_change_to_user_id?
        errors.add(:user, "cannot be changed after document creation")
      end

      attachment_attributes = %w[attachment_file attachment_filename attachment_content_type attachment_sha256]
      changed_attachments = changes_to_save.keys & attachment_attributes
      if changed_attachments.any?
        errors.add(:base, "Cannot modify attachment after document creation")
      end
    end

    def prevent_mutation_if_confirmed_transactions_exist
      return unless persisted?
      return unless imported_transactions.where(status: "confirmed").exists?

      changed = changes_to_save.keys - %w[updated_at]
      if changed.any?
        errors.add(:base, "Cannot modify a document with confirmed transactions")
      end
    end

    def prevent_destroy_if_confirmed_transactions_exist
      if imported_transactions.where(status: "confirmed").exists?
        errors.add(:base, "Cannot delete document with confirmed transactions")
        throw(:abort)
      end
    end
end
