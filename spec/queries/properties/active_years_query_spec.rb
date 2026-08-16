require "rails_helper"

RSpec.describe Properties::ActiveYearsQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "returns current, activity, and valid additional years" do
    create(:charge, :other_charge, tenancy: tenancy, charge_date: Date.new(2026, 4, 1))
    create(:tenant_payment, tenancy: tenancy, payment_date: Date.new(2025, 4, 1))
    create(:expense, property: property, expense_date: Date.new(2024, 4, 1))
    create(:charge, :late_fee_charge, tenancy: tenancy, charge_date: Date.new(2023, 4, 1))

    unresponsive_obj = Object.new
    def unresponsive_obj.respond_to?(method, *)
      return false if method == :to_i
      super
    end

    result = described_class.new(property: property).call(additional_years: [ 2020, 0, nil, "abc", unresponsive_obj ])

    expect(result).to include(Date.current.year, 2026, 2025, 2024, 2023, 2020)
    expect(result).not_to include(0)
  end
end
