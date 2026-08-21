require "rails_helper"

RSpec.describe Charges::CorrectService do
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
    it "corrects a charge by reversing the original at original charge_date and creating replacement atomically" do
      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1),
        description: "Initial late fee"
      )
      original = create_res.value!.data[:charge]
      original_entry = create_res.value!.data[:journal_entry]

      expect {
        result = described_class.call(
          charge: original,
          amount_cents: 7500,
          charge_date: Date.new(2026, 2, 5),
          description: "Corrected late fee"
        )
        expect(result).to be_success
        replacement = result.value!.data[:charge]
        expect(replacement.amount_cents).to eq(7500)
        expect(replacement.charge_date).to eq(Date.new(2026, 2, 5))
        expect(replacement.description).to eq("Corrected late fee")
        expect(replacement).to be_posted
      }.to change(Charge, :count).by(1)
       .and change(JournalEntry, :count).by(2)

      expect(original.reload).to be_voided
      expect(original.superseded_by).to be_present
      expect(original.superseded_by.amount_cents).to eq(7500)

      reversal_entry = JournalEntry.find_by(reversal_of_id: original_entry.id)
      expect(reversal_entry).to be_present
      expect(reversal_entry.occurred_on).to eq(Date.new(2026, 2, 1))
    end

    it "corrects a reimbursement charge and maintains historical as-of balance without doubling" do
      # 1. Jan 1: Post Expense $300
      exp_res = Expenses::CreateService.call(
        property: property,
        rentable_unit: unit,
        expense_kind: "repairs",
        paid_on: Date.new(2026, 1, 1),
        amount_cents: 30_000,
        description: "Jan 1 Roof Repair"
      )
      original_exp = exp_res.value!.data[:expense]

      # 2. Jan 1: Create reimbursement $150
      reimb_res = Charges::CreateReimbursementService.call(
        expense: original_exp,
        tenancy: tenancy,
        amount_cents: 15_000,
        charge_date: Date.new(2026, 1, 1),
        description: "Tenant 50% share"
      )
      original_reimb = reimb_res.value!.data[:charge]

      # Verify initial balances
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 7, 1))).to eq(150.0)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 8, 16))).to eq(150.0)

      # 3. Aug 16: Correct source Expense to $350 (requires voiding or correcting reimbursement first)
      # Void original reimbursement on original date for restatement
      void_res = Charges::VoidService.call(charge: original_reimb, occurred_on: original_reimb.charge_date)
      expect(void_res).to be_success

      # Correct the expense
      exp_corr_res = Expenses::CorrectService.call(
        expense: original_exp,
        amount_cents: 35_000,
        paid_on: Date.new(2026, 1, 1)
      )
      expect(exp_corr_res).to be_success
      replacement_exp = exp_corr_res.value!.data[:replacement]

      # Post replacement reimbursement on the corrected expense
      new_reimb_res = Charges::CreateReimbursementService.call(
        expense: replacement_exp,
        tenancy: tenancy,
        amount_cents: 15_000,
        charge_date: Date.new(2026, 1, 1),
        description: "Tenant share on corrected expense"
      )
      expect(new_reimb_res).to be_success

      # 4. As-of historical reporting check
      # As of Jul 1, balance MUST be $150 (not $300!)
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 7, 1))).to eq(150.0)
      # As of Aug 16, balance MUST be $150
      expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 8, 16))).to eq(150.0)
    end

    it "is idempotent on identical retries and rejects conflicting retries" do
      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1)
      )
      original = create_res.value!.data[:charge]

      res1 = described_class.call(
        charge: original,
        amount_cents: 6000,
        charge_date: Date.new(2026, 2, 1)
      )
      expect(res1).to be_success
      rep1 = res1.value!.data[:charge]

      # Identical retry
      res2 = described_class.call(
        charge: original,
        amount_cents: 6000,
        charge_date: Date.new(2026, 2, 1)
      )
      expect(res2).to be_success
      expect(res2.value!.data[:charge].id).to eq(rep1.id)

      # Conflicting retry
      res3 = described_class.call(
        charge: original,
        amount_cents: 9000,
        charge_date: Date.new(2026, 2, 1)
      )
      expect(res3).to be_failure
      expect(res3.failure.code).to eq(:already_superseded)
    end

    it "rejects correction of a voided charge" do
      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1)
      )
      original = create_res.value!.data[:charge]

      Charges::VoidService.call(charge: original)
      expect(original.reload).to be_voided

      result = described_class.call(charge: original, amount_cents: 6000)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:already_voided)
    end

    it "rejects non-integer amount_cents" do
      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1)
      )
      original = create_res.value!.data[:charge]

      expect(described_class.call(charge: original, amount_cents: "6000")).to be_failure
      expect(described_class.call(charge: original, amount_cents: "6000oops")).to be_failure
      expect(described_class.call(charge: original, amount_cents: -500)).to be_failure
    end

    it "handles unpersisted charge, missing journal entry, and user ownership" do
      expect(described_class.call(charge: Charge.new)).to be_failure

      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1)
      )
      original = create_res.value!.data[:charge]

      other_user = create(:user)
      expect(described_class.call(charge: original, user: other_user)).to be_failure

      other_tenancy = create(:tenancy, rentable_unit: create(:rentable_unit, property: create(:property, user: other_user)))
      expect(described_class.call(charge: original, tenancy: other_tenancy)).to be_failure

      allow(original).to receive_message_chain(:journal_entries, :find_by).and_return(nil)
      expect(described_class.call(charge: original)).to be_failure
    end

    it "handles invalid dates and amounts" do
      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1)
      )
      original = create_res.value!.data[:charge]

      expect(described_class.call(charge: original, charge_date: "invalid-date")).to be_failure
      expect(described_class.call(charge: original, due_on: "invalid-date")).to be_failure
      expect(described_class.call(charge: original, amount: "-50.0")).to be_failure
      expect(described_class.call(charge: original, amount: "garbage")).to be_failure

      # Valid Time object, Numeric amount, and omitted amount (fallback to original cents)
      res_time = described_class.call(
        charge: original,
        charge_date: Time.zone.parse("2026-02-05 10:00:00"),
        amount: 60.0
      )
      expect(res_time).to be_success
      expect(res_time.value!.data[:charge].amount_cents).to eq(6000)

      # Correction without providing amount keeps previous amount_cents
      res_keep_amount = described_class.call(
        charge: res_time.value!.data[:charge],
        description: "Updated description only"
      )
      expect(res_keep_amount).to be_success
      expect(res_keep_amount.value!.data[:charge].amount_cents).to eq(6000)
    end

    it "handles reimbursement validation and capacity errors" do
      exp = create(:expense, :posted, property: property, amount_cents: 20_000)
      reimb_res = Charges::CreateReimbursementService.call(
        expense: exp,
        tenancy: tenancy,
        amount_cents: 10_000
      )
      reimb = reimb_res.value!.data[:charge]

      # Exceeds remaining amount
      res1 = described_class.call(charge: reimb, amount_cents: 25_000)
      expect(res1).to be_failure
      expect(res1.failure.code).to eq(:exceeds_expense_amount)

      # Unit mismatch
      unit_b = create(:rentable_unit, property: property, name: "Unit B")
      unit_b_exp = create(:expense, :posted, property: property, rentable_unit: unit_b, amount_cents: 20_000)
      res2 = described_class.call(charge: reimb, source_expense: unit_b_exp)
      expect(res2).to be_failure
      expect(res2.failure.code).to eq(:unit_mismatch)

      # Inactive source expense
      voided_exp = create(:expense, :voided, property: property, amount_cents: 20_000)
      res3 = described_class.call(charge: reimb, source_expense: voided_exp)
      expect(res3).to be_failure
      expect(res3.failure.code).to eq(:invalid_expense_state)

      # Missing source expense
      res4 = described_class.call(charge: reimb, source_expense: nil)
      expect(res4).to be_failure
    end

    it "handles reversal or create failures cleanly" do
      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1)
      )
      original = create_res.value!.data[:charge]

      allow(Accounting::ReverseEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Reverse error", code: :reverse_error)
      )
      expect(described_class.call(charge: original, amount_cents: 6000)).to be_failure

      allow(Accounting::ReverseEntryService).to receive(:call).and_call_original
      allow(Charges::CreateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Create error", code: :create_error)
      )
      expect(described_class.call(charge: original, amount_cents: 6000)).to be_failure
    end

    it "rejects correcting when active deposit applications exist" do
      party = create(:party, user: user)
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5000,
        charge_date: Date.new(2026, 2, 1)
      ).value!.data[:charge]

      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: charge,
        amount_cents: 5000,
        occurred_on: Date.new(2026, 2, 5)
      )

      result = described_class.call(charge: charge, amount_cents: 6000)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:active_deposit_applications)
    end

    it "corrects a rent charge with rent_term and service periods" do
      term = create(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2026, 1, 1), effective_until: Date.new(2026, 12, 31))
      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 120_000,
        charge_date: Date.new(2026, 3, 1),
        rent_term: term,
        service_period_start: Date.new(2026, 3, 1),
        service_period_end: Date.new(2026, 3, 31)
      )
      original = create_res.value!.data[:charge]

      result = described_class.call(
        charge: original,
        amount_cents: 130_000,
        service_period_start: "2026-03-01",
        service_period_end: "2026-03-31"
      )
      expect(result).to be_success
      replacement = result.value!.data[:charge]
      expect(replacement.amount_cents).to eq(130_000)
      expect(replacement.rent_term).to eq(term)
    end

    it "validates rent-specific fields and handles idempotency with rent payload comparison" do
      term1 = create(:rent_term, tenancy: tenancy, amount_cents: 120_000, effective_from: Date.new(2026, 1, 1), effective_until: Date.new(2026, 6, 30))
      term2 = create(:rent_term, tenancy: tenancy, amount_cents: 140_000, effective_from: Date.new(2026, 7, 1), effective_until: Date.new(2026, 12, 31))

      create_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 120_000,
        charge_date: Date.new(2026, 3, 1),
        rent_term: term1,
        service_period_start: Date.new(2026, 3, 1),
        service_period_end: Date.new(2026, 3, 31)
      )
      original = create_res.value!.data[:charge]

      # Rejects malformed service periods
      expect(described_class.call(charge: original, service_period_start: "garbage")).to be_failure
      expect(described_class.call(charge: original, service_period_end: "garbage")).to be_failure

      # Correct once
      res1 = described_class.call(
        charge: original,
        amount_cents: 130_000,
        rent_term: term1,
        service_period_start: Date.new(2026, 3, 1),
        service_period_end: Date.new(2026, 3, 31)
      )
      expect(res1).to be_success
      rep1 = res1.value!.data[:charge]

      # Identical retry with same rent payload
      res_retry = described_class.call(
        charge: original,
        amount_cents: 130_000,
        rent_term: term1,
        service_period_start: Date.new(2026, 3, 1),
        service_period_end: Date.new(2026, 3, 31)
      )
      expect(res_retry).to be_success
      expect(res_retry.value!.data[:charge].id).to eq(rep1.id)

      # Conflicting retry with different service periods
      res_conflict_dates = described_class.call(
        charge: original,
        amount_cents: 130_000,
        rent_term: term1,
        service_period_start: Date.new(2026, 4, 1),
        service_period_end: Date.new(2026, 4, 30)
      )
      expect(res_conflict_dates).to be_failure
      expect(res_conflict_dates.failure.code).to eq(:already_superseded)

      # Conflicting retry with different rent term
      res_conflict_term = described_class.call(
        charge: original,
        amount_cents: 130_000,
        rent_term: term2,
        service_period_start: Date.new(2026, 3, 1),
        service_period_end: Date.new(2026, 3, 31)
      )
      expect(res_conflict_term).to be_failure
      expect(res_conflict_term.failure.code).to eq(:already_superseded)
    end

    it "safely serializes concurrent reimbursement correction vs reimbursement creation against expense lock" do
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      exp = create(:expense, :posted, property: property, amount_cents: 30_000)
      reimb_a = Charges::CreateReimbursementService.call(
        expense: exp,
        tenancy: tenancy,
        amount_cents: 10_000
      ).value!.data[:charge]

      res_correct = nil
      res_create = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res_correct = described_class.call(
            charge: Charge.find(reimb_a.id),
            amount_cents: 20_000
          )
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res_create = Charges::CreateReimbursementService.call(
            expense: Expense.find(exp.id),
            tenancy: Tenancy.find(tenancy2.id),
            amount_cents: 15_000
          )
        end
      end

      [ t1, t2 ].each(&:join)

      active_charges = exp.reload.reimbursement_charges.active
      expect(active_charges.sum(:amount_cents)).to be <= 30_000
      expect([ res_correct.success?, res_create.success? ].count(true)).to eq(1)
    end

    it "safely serializes concurrent reimbursement correction vs another correction against expense lock" do
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      exp = create(:expense, :posted, property: property, amount_cents: 30_000)
      reimb_a = Charges::CreateReimbursementService.call(
        expense: exp,
        tenancy: tenancy,
        amount_cents: 10_000
      ).value!.data[:charge]

      reimb_b = Charges::CreateReimbursementService.call(
        expense: exp,
        tenancy: tenancy2,
        amount_cents: 10_000
      ).value!.data[:charge]

      res_corr1 = nil
      res_corr2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res_corr1 = described_class.call(
            charge: Charge.find(reimb_a.id),
            amount_cents: 20_000
          )
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res_corr2 = described_class.call(
            charge: Charge.find(reimb_b.id),
            amount_cents: 20_000
          )
        end
      end

      [ t1, t2 ].each(&:join)

      active_charges = exp.reload.reimbursement_charges.active
      expect(active_charges.sum(:amount_cents)).to be <= 30_000
      expect([ res_corr1.success?, res_corr2.success? ].count(true)).to eq(1)
    end

    it "rejects user mismatch and cross-user target tenancy" do
      create_res = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.current,
        due_on: Date.current
      )
      chg = create_res.value!.data[:charge]

      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)

      res1 = described_class.call(charge: chg, user: other_user)
      expect(res1).to be_failure
      expect(res1.failure.code).to eq(:not_found)

      res3 = described_class.call(charge: chg, tenancy: other_tenancy)
      expect(res3).to be_failure
      expect(res3.failure.code).to eq(:ownership_mismatch)
    end

    it "accepts service period start and end as Date objects and strings, or clearing them" do
      create_res = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 5_000,
        charge_date: Date.current,
        due_on: Date.current
      )
      chg = create_res.value!.data[:charge]

      res1 = described_class.call(
        charge: chg,
        service_period_start: "2026-01-01",
        service_period_end: Date.new(2026, 1, 31)
      )
      expect(res1).to be_success
      rep1 = res1.value!.data[:charge]
      expect(rep1.service_period_start).to eq(Date.new(2026, 1, 1))
      expect(rep1.service_period_end).to eq(Date.new(2026, 1, 31))

      res2 = described_class.call(
        charge: rep1,
        service_period_start: "",
        service_period_end: ""
      )
      expect(res2).to be_success
      rep2 = res2.value!.data[:charge]
      expect(rep2.service_period_start).to be_nil
      expect(rep2.service_period_end).to be_nil
    end
  end
end
