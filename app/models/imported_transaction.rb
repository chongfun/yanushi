class ImportedTransaction < ApplicationRecord
  KINDS = %w[unknown tenant_receipt security_deposit].freeze
  STATUSES = %w[pending matched unmatched ambiguous confirmed failed].freeze
  PAYMENT_METHOD_OPTIONS = [
    [ "All payment methods", "" ],
    [ "Zelle", "zelle" ],
    [ "Venmo", "venmo" ],
    [ "P2P", "p2p" ],
    [ "Check", "check" ],
    [ "Cash", "cash" ],
    [ "Bank transfer", "bank_transfer" ],
    [ "Other", "other" ]
  ].freeze

  enum :transaction_kind, {
    unknown: "unknown",
    tenant_receipt: "tenant_receipt",
    security_deposit: "security_deposit"
  }, validate: true

  enum :status, {
    pending: "pending",
    matched: "matched",
    unmatched: "unmatched",
    ambiguous: "ambiguous",
    confirmed: "confirmed",
    failed: "failed"
  }, validate: true

  belongs_to :user
  belongs_to :source_document
  belongs_to :matched_party, class_name: "Party", optional: true
  belongs_to :matched_tenancy, class_name: "Tenancy", optional: true
  belongs_to :confirmed_source, polymorphic: true, optional: true

  normalizes :payment_method, with: ->(m) { m&.strip&.downcase }
  normalizes :external_reference, with: ->(r) { r.presence&.strip }

  validates :source, presence: true
  validates :status, presence: true
  validates :transaction_kind, presence: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :external_reference, length: { maximum: 255 }, allow_blank: true
  validates :external_reference,
            uniqueness: {
              scope: [ :user_id, :source, :payment_method ],
              allow_nil: true,
              allow_blank: true,
              message: "has already been imported for this payment method"
            }

  validate :validate_parse_status
  validate :validate_confirmed_source_consistency
  validate :source_document_owned_by_user
  validate :prevent_mutation_after_confirmed, on: :update

  before_destroy :prevent_destroy_if_confirmed

  scope :reviewable, -> { where(status: %w[matched unmatched ambiguous failed]) }

  def amount
    return nil if amount_cents.nil?

    BigDecimal(amount_cents.to_s) / 100
  end

  def amount=(value)
    if value.blank?
      self.amount_cents = nil
      @amount_error = nil
      return
    end

    val_str = value.is_a?(Numeric) ? value.to_s : value.to_s.strip
    unless val_str =~ /\A-?\d+(\.\d+)?\z/
      @amount_error = "is not a valid number"
      self.amount_cents = nil
      return
    end

    if val_str.include?(".")
      decimals = val_str.split(".").last
      if decimals.length > 2 && decimals[2..].to_i != 0
        @amount_error = "cannot have fractional cents"
        self.amount_cents = nil
        return
      end
    end

    cents = (BigDecimal(val_str) * 100).round
    if cents <= 0
      @amount_error = "must be greater than 0"
      self.amount_cents = nil
      return
    end

    @amount_error = nil
    self.amount_cents = cents
  end

  def confirmable?
    return false if confirmed?
    return false if matched_party_id.blank? || matched_tenancy_id.blank?
    cents = amount_cents
    return false if cents.nil? || cents <= 0
    return false if occurred_on.blank?
    return false if unknown?

    if tenant_receipt?
      return false if payment_method.blank?
    elsif security_deposit?
      t = matched_tenancy || (matched_tenancy_id ? Tenancy.find_by(id: matched_tenancy_id) : nil)
      return false if t&.security_deposit.blank?
    end

    true
  end

  def reviewable?
    status.in?(%w[matched unmatched ambiguous failed])
  end

  def accounting_user
    user
  end

  def proposed_alias_for(party = matched_party)
    return unless party

    if (name = payer_name) && party.alias_candidate?(name)
      name
    elsif (username = payer_username) && party.alias_candidate?(username)
      username
    end
  end

  private

    def validate_parse_status
      errors.add(:amount, @amount_error) if @amount_error.present?
    end

    def validate_confirmed_source_consistency
      if confirmed?
        if confirmed_source_type.blank? || confirmed_source_id.blank?
          errors.add(:confirmed_source, "must be present for confirmed transaction")
          return
        end

        if unknown?
          errors.add(:base, "Unknown transaction kind cannot be confirmed")
          return
        end

        if tenant_receipt?
          unless confirmed_source_type == "Receipt"
            errors.add(:confirmed_source, "must be a Receipt for tenant receipts")
            return
          end

          receipt = confirmed_source
          unless receipt.is_a?(Receipt)
            errors.add(:confirmed_source, "must reference an existing Receipt")
            return
          end

          errors.add(:confirmed_source, "accounting user must match imported transaction user") if receipt.user_id != user_id
          errors.add(:confirmed_source, "tenancy must match matched tenancy") if receipt.tenancy_id != matched_tenancy_id
          errors.add(:confirmed_source, "payer party must match matched party") if receipt.payer_party_id != matched_party_id
          errors.add(:confirmed_source, "amount must match imported transaction amount") if receipt.amount_cents != amount_cents
          errors.add(:confirmed_source, "received date must match imported transaction date") if receipt.received_on != occurred_on
          errors.add(:confirmed_source, "payment method must match imported transaction payment method") if receipt.payment_method != payment_method
          errors.add(:confirmed_source, "external reference must match imported transaction external reference") if receipt.external_reference != external_reference
        elsif security_deposit?
          unless confirmed_source_type == "SecurityDepositTransaction"
            errors.add(:confirmed_source, "must be a SecurityDepositTransaction for security deposits")
            return
          end

          deposit_txn = confirmed_source
          unless deposit_txn.is_a?(SecurityDepositTransaction)
            errors.add(:confirmed_source, "must reference an existing SecurityDepositTransaction")
            return
          end

          deposit = deposit_txn.security_deposit
          deposit_user_id = deposit&.tenancy&.property&.user_id

          errors.add(:confirmed_source, "accounting user must match imported transaction user") if deposit_user_id.present? && deposit_user_id != user_id
          errors.add(:confirmed_source, "transaction kind must be received") if deposit_txn.transaction_kind != "received"
          errors.add(:confirmed_source, "tenancy must match matched tenancy") if deposit&.tenancy_id != matched_tenancy_id
          errors.add(:confirmed_source, "party must match matched party") if deposit_txn.party_id != matched_party_id
          errors.add(:confirmed_source, "amount must match imported transaction amount") if deposit_txn.amount_cents != amount_cents
          errors.add(:confirmed_source, "occurred date must match imported transaction date") if deposit_txn.occurred_on != occurred_on
          errors.add(:confirmed_source, "external reference must match imported transaction external reference") if deposit_txn.external_reference != external_reference
        end
      else
        if confirmed_source_type.present? || confirmed_source_id.present?
          errors.add(:confirmed_source, "must be blank for unconfirmed transaction")
        end
      end
    end

    def prevent_mutation_after_confirmed
      persisted_confirmed = persisted? && self.class.where(id: id, status: :confirmed).exists?
      return unless status_was == "confirmed" || persisted_confirmed

      changed = changes_to_save.keys - %w[updated_at]
      if changed.any?
        errors.add(:base, "Cannot modify a confirmed imported transaction")
      end
    end

    def source_document_owned_by_user
      return unless user_id && source_document
      return if source_document.user_id == user_id

      errors.add(:source_document, "must belong to the same user")
    end

    def prevent_destroy_if_confirmed
      persisted_confirmed = persisted? && self.class.where(id: id, status: :confirmed).exists?
      if confirmed? || persisted_confirmed
        errors.add(:base, "Cannot delete a confirmed imported transaction")
        throw(:abort)
      end
    end
end
