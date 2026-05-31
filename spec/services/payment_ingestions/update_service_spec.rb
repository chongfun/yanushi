require "rails_helper"

RSpec.describe PaymentIngestions::UpdateService do
  let(:user) { create(:user) }
  let(:tenant) { create(:tenant, user: user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }

  it "updates editable attributes" do
    ingestion = create(:payment_ingestion, user: user, status: :matched, payment_method: "zelle")

    result = described_class.call(user: user, ingestion: ingestion, params: { payment_method: "venmo" })

    expect(result).to be_success
    expect(ingestion.reload.payment_method).to eq("venmo")
  end

  it "promotes a corrected ingestion to matched" do
    ingestion = create(:payment_ingestion, user: user, status: :unmatched)

    result = described_class.call(user: user, ingestion: ingestion, params: {
      tenant_id: tenant.id,
      lease_id: lease.id,
      amount: 100.0,
      payment_date: Date.current,
      payment_method: "zelle"
    })

    expect(result).to be_success
    expect(ingestion.reload.status).to eq("matched")
  end
end
