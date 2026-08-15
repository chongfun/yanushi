require "rails_helper"

RSpec.describe PaymentIngestions::ConfirmService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:party) { create(:party, user: user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  def build_ingestion(attributes = {})
    create(:payment_ingestion, {
      user: user,
      source: "pdf_upload",
      status: "matched",
      party: party,
      tenancy: tenancy,
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

  it "returns failure when ingestion belongs to another user" do
    ingestion = build_ingestion(user: other_user)
    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:not_found)
  end

  it "returns failure when ingestion is already confirmed" do
    ingestion = build_ingestion(status: "confirmed")
    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:already_confirmed)
  end

  it "creates aliases only for candidate payer values" do
    create(:party_alias, party: party, alias_name: "@existing")
    ingestion = build_ingestion(payer_name: "Samantha Lopez", payer_username: "@existing")

    expect {
      result = described_class.call(user: user, ingestion: ingestion, create_alias: true)
      expect(result).to be_success
    }.to change(PartyAlias, :count).by(1)

    expect(party.party_aliases.exists?(alias_name: "Samantha Lopez")).to be(true)
  end

  it "handles duplicate transaction number ActiveRecord::RecordNotUnique" do
    ingestion = build_ingestion(transaction_number: "DUPLICATETXN")
    allow(TenantPayment).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:duplicate)
  end

  it "handles ActiveRecord::RecordInvalid" do
    ingestion = build_ingestion(transaction_number: "INVALIDTXN")
    invalid_tp = TenantPayment.new
    invalid_tp.errors.add(:amount, "is invalid")
    allow(TenantPayment).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid_tp))

    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:validation_error)
  end

  it "returns a failure when the ingestion is not confirmable" do
    ingestion = build_ingestion(tenancy: nil)

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

  it "fails when ingestion becomes non-confirmable inside transaction" do
    ingestion = build_ingestion
    allow(ingestion).to receive(:confirmable?).and_return(true, false)
    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:confirmation_error)
  end

  it "skips alias creation when party is nil" do
    ingestion = build_ingestion(payer_name: "Test Payer")
    allow(ingestion).to receive(:party).and_return(nil)
    allow(ingestion).to receive(:confirmable?).and_return(true)
    result = described_class.call(user: user, ingestion: ingestion, create_alias: true)
    expect(result).to be_success
  end
end
