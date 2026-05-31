require "rails_helper"

RSpec.describe PaymentIngestions::ConfirmService do
  let(:user) { create(:user) }
  let(:tenant) { create(:tenant, user: user) }
  let(:property) { create(:rental_property, user: user) }
  let(:lease) { create(:lease, rental_property: property) }

  def build_ingestion(attributes = {})
    create(:payment_ingestion, {
      user: user,
      source: "pdf_upload",
      status: "matched",
      tenant: tenant,
      lease: lease,
      amount: 1200.0,
      payment_date: Date.current,
      payment_method: "venmo",
      transaction_number: "TXN#{SecureRandom.hex(4)}"
    }.merge(attributes))
  end

  it "creates a tenant payment and marks the ingestion confirmed" do
    ingestion = build_ingestion(transaction_number: "TXNCONFIRM")

    expect {
      result = described_class.call(user: user, ingestion: ingestion)
      expect(result).to be_success
      expect(result.value!.data).to be_a(TenantPayment)
    }.to change(TenantPayment, :count).by(1)

    expect(ingestion.reload.status).to eq("confirmed")
    expect(ingestion.tenant_payment.transaction_number).to eq("TXNCONFIRM")
  end

  it "creates aliases only for candidate payer values" do
    create(:tenant_alias, tenant: tenant, alias_name: "@existing")
    ingestion = build_ingestion(payer_name: "Samantha Lopez", payer_username: "@existing")

    expect {
      result = described_class.call(user: user, ingestion: ingestion, create_alias: true)
      expect(result).to be_success
    }.to change(TenantAlias, :count).by(1)

    expect(tenant.tenant_aliases.exists?(alias_name: "Samantha Lopez")).to be(true)
  end

  it "returns a failure when the ingestion is not confirmable" do
    ingestion = build_ingestion(lease: nil)

    result = described_class.call(user: user, ingestion: ingestion)

    expect(result).to be_failure
    expect(result.failure.error).to eq("Cannot confirm: missing required fields or duplicate exists")
  end

  it "prevents concurrent confirmation" do
    ingestion = build_ingestion(transaction_number: "TXNRACE")
    results = []

    2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << described_class.call(user: user, ingestion: PaymentIngestion.find(ingestion.id))
        end
      end
    end.each(&:join)

    expect(results.count(&:success?)).to eq(1)
    expect(results.count(&:failure?)).to eq(1)
    expect(results.find(&:failure?).failure.error).to eq("Already confirmed")
    expect(ingestion.reload.status).to eq("confirmed")
  end
end
