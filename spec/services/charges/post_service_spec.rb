require "rails_helper"

RSpec.describe Charges::PostService do
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
  let(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 200_000,
      effective_from: Date.new(2026, 1, 1),
      effective_until: Date.new(2026, 12, 31)
    )
  end

  describe ".call" do
    it "posts a rent charge to Tenant Receivable and Rental Income with tenancy dimensions" do
      charge = create(:charge, :rent_charge,
        tenancy: tenancy,
        rent_term: rent_term,
        amount_cents: 200_000,
        charge_date: Date.new(2026, 5, 1),
        due_on: Date.new(2026, 5, 1),
        service_period_start: Date.new(2026, 5, 1),
        service_period_end: Date.new(2026, 5, 31)
      )

      result = described_class.call(charge: charge)
      expect(result).to be_success

      entry = result.value!.data[:journal_entry]
      expect(entry.event_type).to eq("charge_posted")
      expect(entry.source).to eq(charge)
      expect(entry.occurred_on).to eq(Date.new(2026, 5, 1))
      expect(entry.postings.sum(:amount_cents)).to eq(0)

      dr = entry.postings.find_by(amount_cents: 200_000)
      cr = entry.postings.find_by(amount_cents: -200_000)

      expect(dr.account.key).to eq("tenant_receivable")
      expect(dr.tenancy_id).to eq(tenancy.id)
      expect(dr.rentable_unit_id).to eq(unit.id)
      expect(dr.property_id).to eq(property.id)

      expect(cr.account.key).to eq("rental_income")
      expect(cr.tenancy_id).to eq(tenancy.id)
      expect(cr.rentable_unit_id).to eq(unit.id)
      expect(cr.property_id).to eq(property.id)
    end

    it "posts a late fee charge to Tenant Receivable and Late Fee Income" do
      charge = create(:charge, :late_fee_charge,
        tenancy: tenancy,
        amount_cents: 5000,
        charge_date: Date.new(2026, 5, 10),
        due_on: Date.new(2026, 5, 10)
      )

      result = described_class.call(charge: charge)
      expect(result).to be_success

      entry = result.value!.data[:journal_entry]
      dr = entry.postings.find_by(amount_cents: 5000)
      cr = entry.postings.find_by(amount_cents: -5000)

      expect(dr.account.key).to eq("tenant_receivable")
      expect(cr.account.key).to eq("late_fee_income")
    end

    it "posts a reimbursement charge to Tenant Receivable and Reimbursement Income" do
      expense = create(:expense, property: property, amount: 300)
      charge = create(:charge, :reimbursement_charge,
        tenancy: tenancy,
        source_expense: expense,
        amount_cents: 30_000,
        charge_date: Date.new(2026, 5, 5),
        due_on: Date.new(2026, 5, 5)
      )

      result = described_class.call(charge: charge)
      expect(result).to be_success

      entry = result.value!.data[:journal_entry]
      dr = entry.postings.find_by(amount_cents: 30_000)
      cr = entry.postings.find_by(amount_cents: -30_000)

      expect(dr.account.key).to eq("tenant_receivable")
      expect(cr.account.key).to eq("reimbursement_income")
    end

    it "posts an other charge to Tenant Receivable and Other Tenant Income" do
      charge = create(:charge, :other_charge,
        tenancy: tenancy,
        amount_cents: 2500,
        charge_date: Date.new(2026, 5, 12),
        due_on: Date.new(2026, 5, 12)
      )

      result = described_class.call(charge: charge)
      expect(result).to be_success

      entry = result.value!.data[:journal_entry]
      dr = entry.postings.find_by(amount_cents: 2500)
      cr = entry.postings.find_by(amount_cents: -2500)

      expect(dr.account.key).to eq("tenant_receivable")
      expect(cr.account.key).to eq("other_tenant_income")
    end

    it "is idempotent on repeated calls" do
      charge = create(:charge, :other_charge, tenancy: tenancy, amount_cents: 2500)

      result1 = described_class.call(charge: charge)
      expect(result1).to be_success

      expect {
        result2 = described_class.call(charge: charge)
        expect(result2).to be_success
        expect(result2.value!.data[:journal_entry].id).to eq(result1.value!.data[:journal_entry].id)
      }.not_to change(JournalEntry, :count)
    end

    it "rejects posting a voided charge" do
      charge = create(:charge, :other_charge, :voided_charge, tenancy: tenancy)
      result = described_class.call(charge: charge)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_state)
    end
  end
end
