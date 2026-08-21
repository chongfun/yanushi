require "rails_helper"

RSpec.describe Dashboards::PropertySummariesQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, commencement_date: Date.current - 1.day, termination_date: Date.current + 1.day) }

  it "returns property financial summaries and active tenancy balances" do
    create(:tenant_payment, tenancy: tenancy, amount: 1200, payment_date: Date.current)
    create(:expense, property: property, amount: 200, expense_date: Date.current)
    create(:scheduled_rent, tenancy: tenancy, amount: 1000, due_date: Date.current)

    result = described_class.new(properties: [ property ]).call

    expect(result.first[:property]).to eq(property)
    expect(result.first[:income]).to eq(1200)
    expect(result.first[:expenses]).to eq(200)
    expect(result.first[:net_income]).to eq(1000)
    expect(result.first[:tenancy_balances].first[:tenancy]).to eq(tenancy)
    expect(result.first[:tenancy_balances].first[:balance]).to eq(200)
  end
end
