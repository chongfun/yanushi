class RentableUnit < ApplicationRecord
  belongs_to :property
  has_many :tenancies, dependent: :restrict_with_error
  has_many :expenses, dependent: :restrict_with_error
  has_many :accounting_postings, class_name: "Posting", dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :property_id, case_sensitive: false }
  validates :square_footage, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :unit_identifier, uniqueness: { scope: :property_id, case_sensitive: false }, allow_nil: true

  normalizes :unit_identifier, with: ->(id) { id.presence&.strip }
  normalizes :name, with: ->(n) { n&.strip }

  def display_name
    unit_identifier.present? ? "#{name} (#{unit_identifier})" : name
  end

  def occupied?(as_of = Date.current)
    tenancies.any? { |t| t.active?(as_of) }
  end

  def accounting_user
    property&.user
  end
end
