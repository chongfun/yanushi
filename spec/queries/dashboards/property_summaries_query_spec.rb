require "rails_helper"

RSpec.describe Dashboards::PropertySummariesQuery do
  let(:user) { create(:user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property, commencement_date: Date.current - 1.day, termination_date: Date.current + 1.day) }

  it "returns property financial summaries and active lease balances" do
    create(:tenant_payment, lease: lease, amount: 1200, payment_date: Date.current)
    create(:expense, rental_property: property, amount: 200, expense_date: Date.current)
    create(:scheduled_rent, lease: lease, amount: 1000, due_date: Date.current)

    result = described_class.new(properties: [ property ]).call

    expect(result.first[:property]).to eq(property)
    expect(result.first[:income]).to eq(1200)
    expect(result.first[:expenses]).to eq(200)
    expect(result.first[:net_income]).to eq(1000)
    expect(result.first[:lease_balances]).to eq([ { lease: lease, balance: 200 } ])
  end
end
