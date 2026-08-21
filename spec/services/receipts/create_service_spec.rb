require "rails_helper"

RSpec.describe Receipts::CreateService, type: :service do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2026, 1, 1)) }
  let(:party_alice) { create(:party, user: user, display_name: "Alice Tenant") }
  let(:party_bob) { create(:party, user: user, display_name: "Bob Tenant") }
  let(:party_employer) { create(:party, user: user, display_name: "Alice Employer") }

  before do
    create(:tenancy_party, tenancy: tenancy, party: party_alice, role: "tenant")
    create(:tenancy_party, tenancy: tenancy, party: party_bob, role: "tenant")
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2026, 1, 1))
  end

  describe ".call" do
    it "atomically creates and posts a receipt" do
      expect {
        result = described_class.call(
          tenancy: tenancy,
          payer_party: party_alice,
          amount_cents: 200_000,
          received_on: Date.new(2026, 2, 1),
          payment_method: "zelle",
          external_reference: "ZEL999",
          memo: "February rent payment"
        )
        expect(result).to be_success
        receipt = result.value!.data[:receipt]
        expect(receipt).to be_persisted
        expect(receipt.posted?).to be true
        expect(receipt.posted_at).to be_present
        expect(receipt.user).to eq(user)
      }.to change(Receipt, :count).by(1)
       .and change(JournalEntry, :count).by(1)
       .and change(Posting, :count).by(2)
    end

    it "accepts decimal amount string" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount: "1500.50",
        received_on: Date.current,
        payment_method: "check"
      )
      expect(result).to be_success
      expect(result.value!.data[:receipt].amount_cents).to eq(150_050)
    end

    it "rejects fractional cents without creating receipt or journal entries" do
      expect {
        result = described_class.call(
          tenancy: tenancy,
          payer_party: party_alice,
          amount: "100.005",
          received_on: Date.current,
          payment_method: "check"
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:invalid_amount)
      }.not_to change(Receipt, :count)

      expect(JournalEntry.count).to eq(0)
    end

    it "rejects non-positive amount" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 0,
        received_on: Date.current,
        payment_method: "cash"
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_amount)
    end

    it "rolls back everything if accounting posting fails" do
      allow(Accounting::PostEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Posting failed", code: :posting_error)
      )

      expect {
        result = described_class.call(
          tenancy: tenancy,
          payer_party: party_alice,
          amount_cents: 100_000,
          received_on: Date.current,
          payment_method: "cash"
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:posting_error)
      }.not_to change(Receipt, :count)

      expect(JournalEntry.count).to eq(0)
    end

    it "supports third-party payer who is not on the tenancy" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_employer,
        amount_cents: 200_000,
        received_on: Date.current,
        payment_method: "wire"
      )
      expect(result).to be_success
      receipt = result.value!.data[:receipt]
      expect(receipt.payer_party).to eq(party_employer)
    end

    it "reduces tenancy balance for joint tenants while preserving payer identity" do
      # Initial rent charge: $2,000
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        service_period_start: Date.new(2026, 1, 1),
        service_period_end: Date.new(2026, 1, 31)
      )
      expect(charge_res).to be_success
      expect(tenancy.current_balance).to eq(BigDecimal("2000.00"))

      # Alice pays $500
      res1 = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 50_000,
        received_on: Date.new(2026, 1, 2),
        payment_method: "zelle"
      )
      expect(res1).to be_success
      expect(tenancy.current_balance).to eq(BigDecimal("1500.00"))

      # Bob pays $750
      res2 = described_class.call(
        tenancy: tenancy,
        payer_party: party_bob,
        amount_cents: 75_000,
        received_on: Date.new(2026, 1, 3),
        payment_method: "venmo"
      )
      expect(res2).to be_success
      expect(tenancy.current_balance).to eq(BigDecimal("750.00"))

      # Verify payers in postings
      alice_postings = res1.value!.data[:journal_entry].postings
      expect(alice_postings.map(&:party).uniq).to eq([ party_alice ])

      bob_postings = res2.value!.data[:journal_entry].postings
      expect(bob_postings.map(&:party).uniq).to eq([ party_bob ])
    end

    it "handles overpayments by producing a credit balance" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.current,
        due_on: Date.current,
        service_period_start: Date.current.beginning_of_month,
        service_period_end: Date.current.end_of_month
      )
      expect(charge_res).to be_success

      # Pay $2,500
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 250_000,
        received_on: Date.current,
        payment_method: "check"
      )
      expect(result).to be_success
      expect(tenancy.current_balance).to eq(BigDecimal("-500.00"))
    end

    it "rejects missing tenancy" do
      result = described_class.call(
        tenancy: nil,
        payer_party: party_alice,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "cash"
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to eq("Tenancy is required")
    end

    it "rejects missing payer party" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: nil,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "cash"
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to eq("Payer party is required")
    end

    it "rejects missing received_on" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 100_000,
        received_on: nil,
        payment_method: "cash"
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to eq("Received on date is required")
    end

    it "rejects invalid received_on string" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 100_000,
        received_on: "invalid-date",
        payment_method: "cash"
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to eq("Received on must be a valid date")
    end

    it "rejects missing or blank payment_method" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "   "
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
      expect(result.failure.error).to eq("Payment method is required")
    end

    it "rescues ActiveRecord::RecordNotUnique and returns duplicate failure" do
      # Create initial receipt
      first_result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "zelle",
        external_reference: "CONF123"
      )
      expect(first_result).to be_success

      # Second attempt with same method + external_reference
      second_result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "zelle",
        external_reference: "CONF123"
      )
      expect(second_result).to be_failure
      expect(second_result.failure.code).to eq(:validation_error)

      # Test race condition where RecordNotUnique is raised directly on save
      allow_any_instance_of(Receipt).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)
      race_result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "zelle",
        external_reference: "CONF456"
      )
      expect(race_result).to be_failure
      expect(race_result.failure.code).to eq(:duplicate)
    end

    it "returns failure for invalid non-numeric amount" do
      result = described_class.call(
        tenancy: tenancy,
        payer_party: party_alice,
        received_on: Date.current,
        payment_method: "cash",
        amount: "invalid-amount"
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_amount)
    end
  end
end
