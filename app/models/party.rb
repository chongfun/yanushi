class Party < ApplicationRecord
  belongs_to :user
  has_many :party_aliases, dependent: :destroy
  has_many :tenancy_parties, dependent: :restrict_with_error
  has_many :tenancies, through: :tenancy_parties
  has_many :accounting_postings, class_name: "Posting", dependent: :restrict_with_error
  has_many :receipts_as_payer, class_name: "Receipt", foreign_key: :payer_party_id, dependent: :restrict_with_error
  has_many :payment_ingestions, dependent: :nullify

  PARTY_TYPES = %w[
    individual
    organization
  ].freeze

  enum :party_type, PARTY_TYPES.index_by(&:itself), prefix: false, validate: true

  validates :display_name, presence: true
  validates :party_type, presence: true
  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  normalizes :display_name, with: ->(n) { n&.strip }
  normalizes :email_address, with: ->(e) { e.presence&.strip&.downcase }

  accepts_nested_attributes_for :party_aliases, allow_destroy: true, reject_if: :all_blank

  def alias_candidate?(alias_name)
    return false if alias_name.blank?
    return false if display_name.blank?

    clean_name = alias_name.strip.downcase
    return false if clean_name == display_name.strip.downcase

    if party_aliases.loaded?
      party_aliases.none? { |pa| pa.alias_name.strip.downcase == clean_name }
    else
      !party_aliases.where("LOWER(TRIM(alias_name)) = ?", clean_name).exists?
    end
  end

  def accounting_user
    user
  end
end
