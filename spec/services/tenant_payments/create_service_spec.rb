require "rails_helper"

RSpec.describe TenantPayments::CreateService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 12, 31)
    )
  end

  describe ".call" do
    it "creates a TenantPayment and posts Dr Cash / Cr Tenant Receivable" do
      result = described_class.call(
        tenancy: tenancy,
        amount: "1500.00",
        payment_date: Date.new(2026, 5, 2),
        payment_method: "ach",
        transaction_number: "ACH12345"
      )

      expect(result).to be_success
      payment = result.value!.data[:tenant_payment]
      entry = result.value!.data[:journal_entry]

      expect(payment.persisted?).to be true
      expect(payment.amount).to eq(1500.00)

      expect(entry.event_type).to eq("payment_received")
      expect(entry.source).to eq(payment)
      expect(entry.occurred_on).to eq(Date.new(2026, 5, 2))

      dr = entry.postings.find_by(amount_cents: 150_000)
      cr = entry.postings.find_by(amount_cents: -150_000)

      expect(dr.account.key).to eq("cash")
      expect(cr.account.key).to eq("tenant_receivable")
      expect(cr.tenancy_id).to eq(tenancy.id)
    end

    it "rolls back if invalid" do
      result = described_class.call(
        tenancy: tenancy,
        amount: -100
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
      expect(TenantPayment.count).to eq(0)
      expect(JournalEntry.count).to eq(0)
    end
  end
end
