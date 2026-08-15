require "rails_helper"

RSpec.describe PaymentIngestions::UpdateService do
  let(:user) { create(:user) }
  let(:party) { create(:party, user: user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "updates editable attributes" do
    ingestion = create(:payment_ingestion, user: user, status: :matched, payment_method: "zelle")

    result = described_class.call(user: user, ingestion: ingestion, params: { payment_method: "venmo" })

    expect(result).to be_success
    expect(ingestion.reload.payment_method).to eq("venmo")
  end

  it "promotes a corrected ingestion to matched" do
    ingestion = create(:payment_ingestion, user: user, status: :unmatched)

    result = described_class.call(user: user, ingestion: ingestion, params: {
      party_id: party.id,
      tenancy_id: tenancy.id,
      amount: 100.0,
      payment_date: Date.current,
      payment_method: "zelle"
    })

    expect(result).to be_success
    expect(ingestion.reload.status).to eq("matched")
  end

  it "returns failure when ingestion belongs to another user" do
    other_user = create(:user)
    ingestion = create(:payment_ingestion, user: other_user)

    result = described_class.call(user: user, ingestion: ingestion, params: { payment_method: "venmo" })
    expect(result).to be_failure
    expect(result.failure.code).to eq(:not_found)
  end

  it "returns failure when update attributes are invalid" do
    ingestion = create(:payment_ingestion, user: user)

    result = described_class.call(user: user, ingestion: ingestion, params: { transaction_number: "invalid txn!" })
    expect(result).to be_failure
    expect(result.failure.code).to eq(:validation_error)
  end
end
