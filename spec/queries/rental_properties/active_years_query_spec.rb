require "rails_helper"

RSpec.describe RentalProperties::ActiveYearsQuery do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }

  it "returns current, activity, and valid additional years" do
    create(:scheduled_rent, lease: lease, due_date: Date.new(2026, 4, 1))
    create(:tenant_payment, lease: lease, payment_date: Date.new(2025, 4, 1))
    create(:expense, rental_property: property, expense_date: Date.new(2024, 4, 1))

    result = described_class.new(rental_property: property).call(additional_years: [ 2020, 0, nil, "abc" ])

    expect(result).to include(Date.current.year, 2026, 2025, 2024, 2020)
    expect(result).not_to include(0)
  end
end
