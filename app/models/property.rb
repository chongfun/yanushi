class Property < ApplicationRecord
  belongs_to :user
  has_many :rentable_units, dependent: :destroy
  has_many :tenancies, through: :rentable_units
  has_many :expenses, dependent: :restrict_with_error
  has_many :scheduled_rents, through: :tenancies
  has_many :tenant_payments, through: :tenancies
  has_many :tenant_charges, through: :tenancies

  ASSET_TYPES = %w[
    single_family
    multifamily
    commercial
    mixed_use
    land
    other
  ].freeze

  enum :asset_type, ASSET_TYPES.index_by(&:itself), prefix: false, validate: true

  validates :address, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }
  validates :asset_type, presence: true
  validates :square_footage, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  normalizes :address, with: ->(a) { a.strip }

  def financial_items(*args, year: nil)
    target_year = year || args.first || Date.current.year
    Properties::FinancialItemsQuery.new(property: self).call(year: target_year)
  end

  def active_years(additional_years = [])
    Properties::ActiveYearsQuery.new(property: self).call(additional_years: additional_years)
  end

  def schedule_e_summary(*args, year: nil)
    target_year = year || args.first || Date.current.year
    Properties::ScheduleESummaryQuery.new(property: self).call(year: target_year)
  end
end
