class PaymentIngestion < ApplicationRecord
  belongs_to :user
  belongs_to :tenant, optional: true
  belongs_to :lease, optional: true
  belongs_to :tenant_payment, optional: true
  belongs_to :payment_document, optional: true

  validates :source, presence: true
  validates :status, presence: true

  validate :ensure_not_duplicate_payment
  validate :validate_parse_status

  enum :status, {
    pending: "pending",
    matched: "matched",
    unmatched: "unmatched",
    ambiguous: "ambiguous",
    confirmed: "confirmed",
    failed: "failed"
  }

  PAYMENT_METHODS = [
    [ "Chase Zelle", "zelle" ],
    [ "Venmo", "venmo" ],
    [ "P2P", "p2p" ]
  ].freeze

  scope :reviewable, -> { where(status: [ :matched, :unmatched, :ambiguous, :failed ]) }

  def confirmable?
    tenant.present? && lease.present? && amount.present? && payment_date.present? && !duplicate_exists?
  end

  def confirm!(create_alias: false)
    raise PaymentIngestions::ConfirmationError, "Cannot confirm: missing required fields or duplicate exists" unless confirmable?
    raise PaymentIngestions::ConfirmationError, "Already confirmed" if confirmed?

    transaction do
      # Note: uses current attributes on the ingestion record (which may have been edited by the user)
      payment = TenantPayment.create!(
        lease: lease,
        amount: amount,
        payment_date: payment_date,
        payment_method: payment_method,
        transaction_number: transaction_number
      )

      if create_alias
        # Create alias for payer name if it's not already matched and is not the tenant's canonical name
        if payer_name.present? && payer_name.downcase != tenant.name.downcase && !tenant.tenant_aliases.exists?(alias_name: payer_name)
          tenant.tenant_aliases.create!(alias_name: payer_name)
        end
        # Create alias for payer username if it's not already matched
        if payer_username.present? && !tenant.tenant_aliases.exists?(alias_name: payer_username)
          tenant.tenant_aliases.create!(alias_name: payer_username)
        end
      end

      update!(status: :confirmed, tenant_payment: payment)
      payment
    end
  rescue ActiveRecord::RecordNotUnique
    raise PaymentIngestions::ConfirmationError, "This transaction has already been recorded in another tenant payment."
  end

  def duplicate_exists?
    return false if transaction_number.blank? || payment_method.blank?
    scope = TenantPayment.joins(lease: :rental_property)
                         .where(rental_properties: { user_id: user_id })
                         .where(payment_method: payment_method, transaction_number: transaction_number)
    scope = scope.where.not(id: tenant_payment_id) if tenant_payment_id.present?
    scope.exists?
  end

  def ingestion_duplicate_exists?
    return false if transaction_number.blank? || payment_method.blank?
    scope = self.class.where(user_id: user_id, payment_method: payment_method, transaction_number: transaction_number)
    scope = scope.where.not(id: id) if persisted?
    scope.exists?
  end

  def attachment_attached?
    payment_document.present?
  end

  def attachment_image?
    payment_document&.attachment_content_type&.start_with?("image/")
  end

  private

  def validate_parse_status
    if failed? && error_message.present? && amount.blank? && tenant.blank?
      errors.add(:base, "Parsing failed: #{error_message}")
    end
  end

  def ensure_not_duplicate_payment
    if duplicate_exists?
      errors.add(:base, "This payment receipt has already been confirmed and recorded in a tenant payment.")
    elsif ingestion_duplicate_exists?
      errors.add(:base, "This payment receipt has already been uploaded and is pending review.")
    end
  end
end
