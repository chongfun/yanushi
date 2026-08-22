require "rails_helper"

RSpec.describe Accounting::ActivityProjector do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil) }
  let!(:rent_term) do
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1), effective_until: nil)
  end
  let(:party) { create(:party, user: user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe ".project" do
    it "projects a rent charge entry into an ActivityRow" do
      res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1),
        description: "January 2026 Rent"
      )
      entry = res.value!.data[:journal_entry]

      row = described_class.project(entry)
      expect(row).to be_a(Accounting::ActivityRow)
      expect(row.occurred_on).to eq(Date.new(2026, 1, 1))
      expect(row.kind).to eq("rent")
      expect(row.label).to eq("Rent")
      expect(row.amount_cents).to eq(200_000)
      expect(row.property).to eq(property)
      expect(row.tenancy).to eq(tenancy)
      expect(row.reversal).to be false
      expect(row.corrected).to be false
    end

    it "projects a payment (receipt) entry into an ActivityRow" do
      res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "zelle",
        external_reference: "ZEL123"
      )
      entry = res.value!.data[:journal_entry]

      row = described_class.project(entry)
      expect(row.occurred_on).to eq(Date.new(2026, 1, 5))
      expect(row.kind).to eq("payment")
      expect(row.label).to eq("Payment")
      expect(row.amount_cents).to eq(150_000)
      expect(row.party).to eq(party)
    end

    it "projects an expense entry into an ActivityRow" do
      res = Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 30_000,
        description: "Plumbing repair"
      )
      entry = res.value!.data[:journal_entry]

      row = described_class.project(entry)
      expect(row.occurred_on).to eq(Date.new(2026, 1, 10))
      expect(row.kind).to eq("expense")
      expect(row.label).to eq("Expense")
      expect(row.amount_cents).to eq(-30_000)
      expect(row.property).to eq(property)
    end

    it "projects security deposit receive, refund, and application entries" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)

      # Receive
      rec_res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 2)
      )
      rec_row = described_class.project(rec_res.value!.data[:journal_entry])
      expect(rec_row.kind).to eq("deposit_received")
      expect(rec_row.label).to eq("Security Deposit Received")
      expect(rec_row.amount_cents).to eq(200_000)

      # Apply to charge
      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1)
      ).value!.data[:charge]

      app_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 15)
      )
      app_row = described_class.project(app_res.value!.data[:journal_entry])
      expect(app_row.kind).to eq("deposit_applied")
      expect(app_row.label).to eq("Security Deposit Applied")
      expect(app_row.amount_cents).to eq(-50_000)

      # Refund
      ref_res = SecurityDepositTransactions::RefundService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 150_000,
        occurred_on: Date.new(2026, 1, 20)
      )
      ref_row = described_class.project(ref_res.value!.data[:journal_entry])
      expect(ref_row.kind).to eq("deposit_refunded")
      expect(ref_row.label).to eq("Security Deposit Refund")
      expect(ref_row.amount_cents).to eq(-150_000)
    end

    it "projects reversal entries with appropriate negative/positive amounts corresponding to original display" do
      # Original expense: -30_000 cash
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 30_000
      )
      exp = exp_res.value!.data[:expense]
      Expenses::VoidService.call(expense: exp)
      rev_entry = JournalEntry.find_by!(event_type: "reversal")

      rev_row = described_class.project(rev_entry)
      expect(rev_row.reversal).to be true
      expect(rev_row.kind).to eq("reversal")
      expect(rev_row.label).to eq("Correction of Expense")
      expect(rev_row.amount_cents).to eq(30_000) # Reversal reverses -$300 with +$300
    end

    it "marks corrected when original source has been superseded or voided" do
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 30_000
      )
      exp = exp_res.value!.data[:expense]
      Expenses::VoidService.call(expense: exp)

      row = described_class.project(exp.journal_entries.first)
      expect(row.corrected).to be true
    end

    it "projects late fee, reimbursement, and other charge kinds" do
      late_entry = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 10)
      ).value!.data[:journal_entry]
      late_row = described_class.project(late_entry)
      expect(late_row.label).to eq("Late Fee")
      expect(late_row.kind).to eq("late_fee")

      expense = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.new(2026, 1, 10),
        amount_cents: 10_000
      ).value!.data[:expense]

      reimb_entry = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "reimbursement",
        amount_cents: 10_000,
        charge_date: Date.new(2026, 1, 12),
        source_expense: expense
      ).value!.data[:journal_entry]
      reimb_row = described_class.project(reimb_entry)
      expect(reimb_row.label).to eq("Reimbursement")
      expect(reimb_row.kind).to eq("reimbursement")

      other_entry = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 12_000,
        charge_date: Date.new(2026, 1, 14)
      ).value!.data[:journal_entry]
      other_row = described_class.project(other_entry)
      expect(other_row.label).to eq("Charge")
      expect(other_row.kind).to eq("other")
    end

    it "handles fallback projection and standalone reversal without reversal_of" do
      custom_entry = create(:journal_entry, user: user, event_type: "custom_event", description: "Custom Event")
      cash_account = user.accounts.find_by(key: "cash")
      create(:posting, journal_entry: custom_entry, account: cash_account, amount_cents: 50_000, property: property)

      custom_row = described_class.project(custom_entry)
      expect(custom_row.kind).to eq("custom_event")
      expect(custom_row.label).to eq("Custom Event")
      expect(custom_row.amount_cents).to eq(50_000)

      standalone_reversal = create(:journal_entry, user: user, event_type: "reversal", description: "Orphan Reversal")
      create(:posting, journal_entry: standalone_reversal, account: cash_account, amount_cents: -50_000, property: property)
      standalone_row = described_class.project(standalone_reversal)
      expect(standalone_row.reversal).to be true
      expect(standalone_row.label).to eq("Correction of Entry")
    end

    it "projects charge waivers as 'Waiver' with 'Charge Waived' label and :voided status" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2026, 1, 10)
      )
      charge = charge_res.value!.data[:charge]

      Charges::VoidService.call(charge: charge, occurred_on: Date.new(2026, 1, 15))

      rev_entry = JournalEntry.where(event_type: "reversal").last
      rev_row = described_class.project(rev_entry)
      expect(rev_row.kind).to eq("waiver")
      expect(rev_row.label).to eq("Late Fee Waived")
      expect(rev_row.reversal).to be true

      orig_row = described_class.project(charge.journal_entries.first)
      expect(orig_row.lifecycle_status).to eq(:voided)
      expect(orig_row.voided?).to be true
      expect(orig_row.corrected?).to be false
      expect(orig_row.active?).to be false
    end

    it "projects charge corrections as 'Correction of Charge' with :corrected status" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      charge = charge_res.value!.data[:charge]

      Charges::CorrectService.call(
        charge: charge,
        amount_cents: 210_000,
        charge_date: Date.new(2026, 1, 1)
      )

      orig_row = described_class.project(charge.journal_entries.first)
      expect(orig_row.lifecycle_status).to eq(:corrected)
      expect(orig_row.corrected?).to be true
      expect(orig_row.voided?).to be false
      expect(orig_row.active?).to be false
    end

    it "respects as_of date for lifecycle status when reversal occurs in a future period" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2025, 12, 15)
      )
      charge = charge_res.value!.data[:charge]

      # Waived in 2026
      Charges::VoidService.call(charge: charge, occurred_on: Date.new(2026, 1, 10))

      orig_entry = charge.journal_entries.first

      # As of 2025-12-31: charge was active
      row_2025 = described_class.project(orig_entry, as_of: Date.new(2025, 12, 31))
      expect(row_2025.lifecycle_status).to eq(:active)
      expect(row_2025.active?).to be true
      expect(row_2025.voided?).to be false

      # As of 2026-01-31: charge is voided
      row_2026 = described_class.project(orig_entry, as_of: Date.new(2026, 1, 31))
      expect(row_2026.lifecycle_status).to eq(:voided)
      expect(row_2026.voided?).to be true
    end

    it "handles voided_at > as_of when journal_entry.reversal is nil" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.new(2025, 12, 15)
      )
      charge = charge_res.value!.data[:charge]
      charge.update_columns(voided_at: Time.zone.local(2026, 1, 15))

      entry = charge.journal_entries.first
      # reversal entry is nil in this scenario
      row = described_class.project(entry, as_of: Date.new(2025, 12, 31))
      expect(row.lifecycle_status).to eq(:active)

      row_after = described_class.project(entry, as_of: Date.new(2026, 1, 31))
      expect(row_after.lifecycle_status).to eq(:voided)
    end

    it "projects reversed journal entry without source as corrected" do
      custom_entry = create(:journal_entry, user: user, event_type: "custom_entry", description: "Standalone")
      cash_account = user.accounts.find_by(key: "cash")
      create(:posting, journal_entry: custom_entry, account: cash_account, amount_cents: 10_000, property: property)

      rev = create(:journal_entry, user: user, event_type: "reversal", reversal_of: custom_entry, description: "Reversing")
      create(:posting, journal_entry: rev, account: cash_account, amount_cents: -10_000, property: property)

      row = described_class.project(custom_entry)
      expect(row.lifecycle_status).to eq(:corrected)
      expect(row.corrected?).to be true
    end

    it "handles fallback amount cents when no positive posting is present" do
      entry = create(:journal_entry, user: user, event_type: "adjustment", description: "Credit only")
      cash_account = user.accounts.find_by(key: "cash")
      create(:posting, journal_entry: entry, account: cash_account, amount_cents: -25_000, property: property)

      row = described_class.project(entry)
      expect(row.amount_cents).to eq(25_000)
    end

    it "projects reversal when first posting has dimensions" do
      entry = create(:journal_entry, user: user, event_type: "custom_event", description: "Custom")
      cash_account = user.accounts.find_by(key: "cash")
      create(:posting, journal_entry: entry, account: cash_account, amount_cents: 30_000, property: property, rentable_unit: unit, tenancy: tenancy, party: party)

      reversal_entry = create(:journal_entry, user: user, event_type: "reversal", reversal_of: entry, description: "Rev Custom")
      create(:posting, journal_entry: reversal_entry, account: cash_account, amount_cents: -30_000, property: property, rentable_unit: unit, tenancy: tenancy, party: party)

      row = described_class.project(reversal_entry)
      expect(row.property).to eq(property)
      expect(row.rentable_unit).to eq(unit)
      expect(row.tenancy).to eq(tenancy)
      expect(row.party).to eq(party)
    end

    it "handles entries with missing primary postings or nil source gracefully" do
      cash_account = user.accounts.find_by(key: "cash")

      # Charge without AR posting
      charge_entry = create(:journal_entry, user: user, event_type: "charge_posted", description: "No AR")
      create(:posting, journal_entry: charge_entry, account: cash_account, amount_cents: 10_000, property: property)
      charge_row = described_class.project(charge_entry)
      expect(charge_row.amount_cents).to eq(10_000)

      # Receipt without Cash posting
      ar_account = user.accounts.find_by(key: "tenant_receivable")
      receipt_entry = create(:journal_entry, user: user, event_type: "receipt_posted", description: "No Cash")
      create(:posting, journal_entry: receipt_entry, account: ar_account, amount_cents: -10_000, property: property)
      receipt_row = described_class.project(receipt_entry)
      expect(receipt_row.amount_cents).to eq(10_000)

      # Expense without Cash posting
      exp_entry = create(:journal_entry, user: user, event_type: "expense_posted", description: "No Cash Exp")
      create(:posting, journal_entry: exp_entry, account: ar_account, amount_cents: 15_000, property: property)
      exp_row = described_class.project(exp_entry)
      expect(exp_row.amount_cents).to eq(-15_000)

      # Deposit received without Cash posting
      dep_rec_entry = create(:journal_entry, user: user, event_type: "deposit_received", description: "No Cash Dep")
      create(:posting, journal_entry: dep_rec_entry, account: ar_account, amount_cents: 20_000, property: property)
      dep_rec_row = described_class.project(dep_rec_entry)
      expect(dep_rec_row.amount_cents).to eq(20_000)

      # Deposit refunded without Cash posting
      dep_ref_entry = create(:journal_entry, user: user, event_type: "deposit_refunded", description: "No Cash Ref")
      create(:posting, journal_entry: dep_ref_entry, account: ar_account, amount_cents: 20_000, property: property)
      dep_ref_row = described_class.project(dep_ref_entry)
      expect(dep_ref_row.amount_cents).to eq(-20_000)

      # Deposit applied without AR posting
      dep_app_entry = create(:journal_entry, user: user, event_type: "deposit_applied", description: "No AR App")
      create(:posting, journal_entry: dep_app_entry, account: cash_account, amount_cents: 20_000, property: property)
      dep_app_row = described_class.project(dep_app_entry)
      expect(dep_app_row.amount_cents).to eq(-20_000)
    end
  end
end
