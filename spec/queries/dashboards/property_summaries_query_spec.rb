require "rails_helper"

RSpec.describe Dashboards::PropertySummariesQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, commencement_date: Date.current.beginning_of_month, termination_date: Date.current.end_of_month) }
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant") }
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 100_000,
      effective_from: tenancy.commencement_date,
      effective_until: tenancy.termination_date
    )
  end

  it "returns property financial summaries and active tenancy balances" do
    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount: 1200,
      received_on: Date.current,
      payment_method: "other"
    )
    create(:expense, property: property, amount: 200, expense_date: Date.current)
    Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "rent",
      amount_cents: 100_000,
      charge_date: Date.current,
      due_on: Date.current,
      rent_term: rent_term,
      service_period_start: tenancy.commencement_date,
      service_period_end: tenancy.termination_date
    )

    result = described_class.new(properties: [ property ]).call

    expect(result.first[:property]).to eq(property)
    expect(result.first[:income]).to eq(1200)
    expect(result.first[:expenses]).to eq(200)
    expect(result.first[:net_income]).to eq(1000)
    expect(result.first[:tenancy_balances].first[:tenancy]).to eq(tenancy)
    # 1000 charged - 1200 paid = -200 (credit/prepaid)
    expect(result.first[:tenancy_balances].first[:balance]).to eq(-200)
  end
end
