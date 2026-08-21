require "rails_helper"

RSpec.describe PaymentIngestions::DestroyService do
  let(:user) { create(:user) }
  let(:party) { create(:party, user: user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "destroys an unconfirmed payment ingestion" do
    ingestion = create(:payment_ingestion, user: user, status: :matched)

    expect {
      result = described_class.call(user: user, ingestion: ingestion)
      expect(result).to be_success
    }.to change(PaymentIngestion, :count).by(-1)
  end

  it "rejects destroying a confirmed payment ingestion" do
    ingestion = create(:payment_ingestion,
      user: user,
      status: :confirmed,
      party: party,
      tenancy: tenancy,
      amount: 1000.0,
      payment_date: Date.current,
      payment_method: "zelle"
    )

    expect {
      result = described_class.call(user: user, ingestion: ingestion)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:immutable)
      expect(result.failure.error).to eq("Cannot delete a confirmed payment ingestion")
    }.not_to change(PaymentIngestion, :count)
  end

  it "returns failure when ingestion belongs to another user" do
    other_user = create(:user)
    ingestion = create(:payment_ingestion, user: other_user)

    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:not_found)
  end
end
