require "rails_helper"

RSpec.describe RentalProperties::ScheduleESummaryQuery do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }

  it "computes Schedule E summary values for a year" do
    create(:tenant_payment, lease: lease, payment_date: Date.new(2026, 1, 1), amount: 1200)
    create(:expense, rental_property: property, expense_date: Date.new(2026, 1, 2), category: "repairs", amount: 200)
    create(:expense, rental_property: property, expense_date: Date.new(2026, 1, 3), category: "utilities", amount: 100)
    create(:expense, rental_property: property, expense_date: Date.new(2025, 1, 3), category: "utilities", amount: 999)

    result = described_class.new(rental_property: property).call(year: 2026)

    expect(result.rents_received).to eq(1200)
    expect(result.utility_reimbursements).to eq(0)
    expect(result.total_income).to eq(1200)
    expect(result.expenses_by_category).to eq("repairs" => 200, "utilities" => 100)
    expect(result.total_expenses).to eq(300)
    expect(result.net_income).to eq(900)
  end
end
