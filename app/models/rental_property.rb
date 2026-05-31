class RentalProperty < ApplicationRecord
  belongs_to :user
  has_many :leases, dependent: :destroy
  has_many :scheduled_rents, through: :leases
  has_many :expenses, dependent: :destroy
  has_many :tenant_payments, through: :leases
  has_many :tenant_charges, through: :leases
  enum :property_type, {
    single_family_residence: 1,
    multi_family_residence: 2,
    vacation_or_short_term_rental: 3,
    commercial: 4,
    land: 5,
    royalties: 6,
    self_rental: 7,
    other: 8
  }

  validates :address, presence: true

  def financial_items(year)
    RentalProperties::FinancialItemsQuery.new(rental_property: self).call(year: year)
  end

  def active_years(additional_years = [])
    RentalProperties::ActiveYearsQuery.new(rental_property: self).call(additional_years: additional_years)
  end
end
