require "rails_helper"

RSpec.describe Expenses::CorrectService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "corrects an expense by reversing the original and posting a replacement" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.new(2026, 2, 1),
      amount_cents: 30_000,
      vendor_name: "City Water",
      description: "Water bill"
    )
    original = create_res.value!.data[:expense]
    original_entry = create_res.value!.data[:journal_entry]

    expect {
      result = described_class.call(
        expense: original,
        expense_kind: "repairs",
        amount_cents: 45_000,
        paid_on: Date.new(2026, 2, 5),
        vendor_name: "City Plumbing",
        description: "Pipe repair"
      )
      expect(result).to be_success
      replacement = result.value!.data[:replacement]
      expect(replacement).to be_posted
      expect(replacement.expense_kind).to eq("repairs")
      expect(replacement.amount_cents).to eq(45_000)
      expect(replacement.vendor_name).to eq("City Plumbing")
    }.to change(Expense, :count).by(1)
     .and change(JournalEntry, :count).by(2) # 1 reversal + 1 replacement entry

    expect(original.reload).to be_voided
    expect(original.superseded_by).to be_present
    expect(original.superseded_by.amount_cents).to eq(45_000)

    reversal_entry = JournalEntry.find_by(reversal_of_id: original_entry.id)
    expect(reversal_entry).to be_present
    expect(reversal_entry.occurred_on).to eq(Date.new(2026, 2, 1))
  end

  it "allows cross-property correction within the same user's portfolio" do
    prop2 = create(:property, user: user)
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.current,
      amount_cents: 20_000
    )
    original = create_res.value!.data[:expense]

    result = described_class.call(
      expense: original,
      property: prop2
    )

    expect(result).to be_success
    expect(result.value!.data[:replacement].property).to eq(prop2)
  end

  it "rejects cross-user property transfer before reversal starts" do
    other_user = create(:user)
    other_prop = create(:property, user: other_user)
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.current,
      amount_cents: 20_000
    )
    original = create_res.value!.data[:expense]

    expect {
      result = described_class.call(
        expense: original,
        property: other_prop
      )
      expect(result).to be_failure
      expect(result.failure.code).to eq(:ownership_mismatch)
    }.not_to change(JournalEntry, :count)

    expect(original.reload).not_to be_voided
  end

  it "automatically restates active reimbursement charges onto the replacement expense" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.new(2026, 1, 1),
      amount_cents: 30_000
    )
    original = create_res.value!.data[:expense]

    charge_res = Charges::CreateReimbursementService.call(
      expense: original,
      tenancy: tenancy,
      amount_cents: 15_000,
      charge_date: Date.new(2026, 1, 1)
    )
    expect(charge_res).to be_success
    original_charge = charge_res.value!.data[:charge]

    # Tenancy balance before correction
    expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 7, 1))).to eq(150.0)
    expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 8, 16))).to eq(150.0)

    # Correct expense
    corr_res = described_class.call(expense: original, amount_cents: 35_000)
    expect(corr_res).to be_success
    replacement_expense = corr_res.value!.data[:replacement]

    # Original charge was superseded and reversed on original date
    expect(original_charge.reload).to be_superseded
    expect(original_charge.superseded_by).to be_present
    replacement_charge = original_charge.superseded_by
    expect(replacement_charge.source_expense_id).to eq(replacement_expense.id)
    expect(replacement_charge.amount_cents).to eq(15_000)
    expect(replacement_charge.charge_date).to eq(Date.new(2026, 1, 1))

    # Reversal was dated on original charge_date (no double counting)
    reversal = original_charge.journal_entries.find_by(event_type: "charge_posted").reversal
    expect(reversal.occurred_on).to eq(Date.new(2026, 1, 1))

    # Point-in-time tenancy balance is preserved without doubling
    expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 7, 1))).to eq(150.0)
    expect(Tenancies::BalanceQuery.call(tenancy: tenancy, as_of: Date.new(2026, 8, 16))).to eq(150.0)
  end

  it "rejects correction when active reimbursements exceed new expense amount" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.new(2026, 1, 1),
      amount_cents: 30_000
    )
    original = create_res.value!.data[:expense]

    charge_res = Charges::CreateReimbursementService.call(
      expense: original,
      tenancy: tenancy,
      amount_cents: 20_000,
      charge_date: Date.new(2026, 1, 1)
    )
    expect(charge_res).to be_success

    # Attempt to reduce expense amount below total active reimbursements ($100 < $200)
    result = described_class.call(expense: original, amount_cents: 10_000)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:exceeds_expense_amount)
    expect(result.failure.error).to include("less than total active reimbursements")
  end

  it "rejects correction when active reimbursements conflict with new property or unit" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.new(2026, 1, 1),
      amount_cents: 30_000
    )
    original = create_res.value!.data[:expense]

    charge_res = Charges::CreateReimbursementService.call(
      expense: original,
      tenancy: tenancy,
      amount_cents: 15_000,
      charge_date: Date.new(2026, 1, 1)
    )
    expect(charge_res).to be_success

    # Transfer to another property fails
    other_prop = create(:property, user: user)
    res_prop = described_class.call(expense: original, property: other_prop)
    expect(res_prop).to be_failure
    expect(res_prop.failure.code).to eq(:property_mismatch)

    # Scoping to a different unit fails
    other_unit = create(:rentable_unit, property: property, name: "Unit 99")
    res_unit = described_class.call(expense: original, rentable_unit: other_unit)
    expect(res_unit).to be_failure
    expect(res_unit.failure.code).to eq(:unit_mismatch)

    # Active deposit application on reimbursement charge blocks expense correction
    party = create(:party, user: user)
    deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: deposit,
      party: party,
      amount_cents: 100_000,
      occurred_on: Date.new(2026, 1, 1)
    )
    reimb_charge = charge_res.value!.data[:charge]
    SecurityDepositTransactions::ApplyService.call(
      security_deposit: deposit,
      charge: reimb_charge,
      amount_cents: 5000,
      occurred_on: Date.new(2026, 1, 5)
    )
    res_dep = described_class.call(expense: original, amount_cents: 35_000)
    expect(res_dep).to be_failure
    expect(res_dep.failure.code).to eq(:active_deposit_applications)
  end

  it "is idempotent on identical retries" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.new(2026, 1, 1),
      amount_cents: 10_000
    )
    original = create_res.value!.data[:expense]

    res1 = described_class.call(
      expense: original,
      amount_cents: 12_000,
      paid_on: Date.new(2026, 1, 2)
    )
    expect(res1).to be_success
    replacement1 = res1.value!.data[:replacement]

    # Identical retry
    res2 = described_class.call(
      expense: original,
      amount_cents: 12_000,
      paid_on: Date.new(2026, 1, 2)
    )
    expect(res2).to be_success
    expect(res2.value!.data[:replacement].id).to eq(replacement1.id)

    # Conflicting retry
    res3 = described_class.call(
      expense: original,
      amount_cents: 99_000,
      paid_on: Date.new(2026, 1, 2)
    )
    expect(res3).to be_failure
    expect(res3.failure.code).to eq(:idempotency_conflict)
  end

  describe "concurrency serialization" do
    it "safely serializes concurrent corrections" do
      create_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.current,
        amount_cents: 10_000
      )
      original = create_res.value!.data[:expense]

      res1 = nil
      res2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res1 = described_class.call(expense: Expense.find(original.id), amount_cents: 12_000)
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res2 = described_class.call(expense: Expense.find(original.id), amount_cents: 15_000)
        end
      end

      [ t1, t2 ].each(&:join)

      successes = [ res1, res2 ].count(&:success?)
      conflicts = [ res1, res2 ].count { |r| r.failure? && r.failure.code == :idempotency_conflict }

      expect(successes).to eq(1)
      expect(conflicts).to eq(1)
      expect(original.reload.superseded_by).to be_present
    end

    it "serializes concurrent void vs correct, with exactly one terminal outcome" do
      create_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.current,
        amount_cents: 10_000
      )
      original = create_res.value!.data[:expense]

      void_res = nil
      correct_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          void_res = Expenses::VoidService.call(expense: Expense.find(original.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          correct_res = described_class.call(expense: Expense.find(original.id), amount_cents: 15_000)
        end
      end

      [ t1, t2 ].each(&:join)

      # Exactly one operation succeeds
      results = [ void_res, correct_res ]
      expect(results.count(&:success?)).to eq(1)

      if void_res.success?
        # Void won, correct should be rejected as already_voided
        expect(correct_res).to be_failure
        expect(correct_res.failure.code).to eq(:already_voided)
      else
        # Correct won (which voids+supersedes), void sees it as already voided and returns success (idempotent)
        expect(correct_res).to be_success
      end
    end

    it "serializes concurrent Expense correction vs reimbursement Charge void without resurrecting voided charges" do
      create_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.new(2026, 1, 1),
        amount_cents: 30_000
      )
      original_expense = create_res.value!.data[:expense]

      charge_res = Charges::CreateReimbursementService.call(
        expense: original_expense,
        tenancy: tenancy,
        amount_cents: 15_000,
        charge_date: Date.new(2026, 1, 1)
      )
      reimb_charge = charge_res.value!.data[:charge]

      correct_res = nil
      void_charge_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          correct_res = described_class.call(
            expense: Expense.find(original_expense.id),
            amount_cents: 35_000
          )
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          void_charge_res = Charges::VoidService.call(
            charge: Charge.find(reimb_charge.id),
            reason: "Voided by tenant request"
          )
        end
      end

      [ t1, t2 ].each(&:join)

      reimb_charge.reload
      if void_charge_res.success?
        # Void won first: charge is purely voided, correction did not recreate it
        expect(reimb_charge).to be_voided
        expect(reimb_charge).not_to be_superseded
        expect(correct_res).to be_success
        replacement_expense = correct_res.value!.data[:replacement]
        expect(replacement_expense.reimbursement_charges.active.count).to eq(0)
      else
        # Correction won first: charge is superseded, void is rejected as already_superseded
        expect(void_charge_res).to be_failure
        expect(void_charge_res.failure.code).to eq(:already_superseded)
        expect(correct_res).to be_success
        expect(reimb_charge).to be_superseded
        replacement_expense = correct_res.value!.data[:replacement]
        expect(replacement_expense.reimbursement_charges.active.count).to eq(1)
      end
    end
  end

  it "rejects correction of a voided expense" do
    create_res = Expenses::CreateService.call(
      property: property,
      expense_kind: "utilities",
      paid_on: Date.current,
      amount_cents: 10_000
    )
    expense = create_res.value!.data[:expense]

    # Void it first
    void_res = Expenses::VoidService.call(expense: expense)
    expect(void_res).to be_success
    expect(expense.reload).to be_voided

    # Now attempt correction
    expect {
      result = described_class.call(expense: expense, amount_cents: 15_000)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:already_voided)
      expect(result.failure.error).to include("already been voided")
    }.not_to change(Expense, :count)
  end

  describe "validation edge cases" do
    it "handles missing expense, invalid date, invalid amounts, and invalid unit" do
      expect(described_class.call(expense: nil)).to be_failure

      create_res = Expenses::CreateService.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount_cents: 10_000)
      exp = create_res.value!.data[:expense]

      other_prop = create(:property, user: user)
      foreign_unit = create(:rentable_unit, property: other_prop)

      # Unit mismatch
      res_unit = described_class.call(expense: exp, rentable_unit: foreign_unit)
      expect(res_unit).to be_failure
      expect(res_unit.failure.code).to eq(:property_mismatch)

      # Invalid date
      res_date = described_class.call(expense: exp, paid_on: "invalid-date")
      expect(res_date).to be_failure

      # Invalid amounts
      res_amt1 = described_class.call(expense: exp, amount: "-10")
      expect(res_amt1).to be_failure

      res_amt2 = described_class.call(expense: exp, amount: "invalid")
      expect(res_amt2).to be_failure

      # Success with string amount
      res_amt3 = described_class.call(expense: exp, amount: "123.45")
      expect(res_amt3).to be_success
      # Non-integer amount_cents
      expect(described_class.call(expense: exp, amount_cents: "15000")).to be_failure
      expect(described_class.call(expense: exp, amount_cents: "15000oops")).to be_failure
      expect(described_class.call(expense: exp, amount_cents: -500)).to be_failure

      # User mismatch
      other_user = create(:user)
      res_user = described_class.call(expense: exp, user: other_user)
      expect(res_user).to be_failure
      expect(res_user.failure.code).to eq(:not_found)

      # Property ownership mismatch
      other_user_prop = create(:property, user: other_user)
      res_prop = described_class.call(expense: exp, property: other_user_prop)
      expect(res_prop).to be_failure
      expect(res_prop.failure.code).to eq(:ownership_mismatch)
    end

    it "returns a proper failure result when replacement creation fails" do
      create_res = Expenses::CreateService.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount_cents: 10_000)
      exp = create_res.value!.data[:expense]

      allow(Accounting::ReverseEntryService).to receive(:call).and_return(ServiceResult.failure(error: "Reversal error", code: :reversal_error))
      res_rev = described_class.call(expense: exp, amount_cents: 15_000)
      expect(res_rev).to be_failure
      expect(res_rev.failure.error).to eq("Reversal error")

      allow(Accounting::ReverseEntryService).to receive(:call).and_call_original
      allow(Expenses::CreateService).to receive(:call).and_return(ServiceResult.failure(error: "Create error", code: :create_error))
      res_create = described_class.call(expense: exp, amount_cents: 15_000)
      expect(res_create).to be_failure
      expect(res_create.failure.error).to eq("Create error")
    end

    it "rejects invalid expense_kind" do
      create_res = Expenses::CreateService.call(property: property, expense_kind: "utilities", paid_on: Date.current, amount_cents: 10_000)
      exp = create_res.value!.data[:expense]

      res_k = described_class.call(expense: exp, expense_kind: "invalid_kind")
      expect(res_k).to be_failure
      expect(res_k.failure.code).to eq(:validation_error)
    end

    it "rejects changing property or unit on an expense with an active reimbursement" do
      prop2 = create(:property, user: user)
      unit2 = create(:rentable_unit, property: prop2)
      create(:tenancy, rentable_unit: unit2)

      create_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        paid_on: Date.current,
        amount_cents: 20_000
      )
      exp = create_res.value!.data[:expense]

      Charges::CreateReimbursementService.call(
        expense: exp,
        tenancy: tenancy,
        amount_cents: 20_000
      )

      # Attempt changing to different property
      res_prop_change = described_class.call(expense: exp, property: prop2)
      expect(res_prop_change).to be_failure
      expect(res_prop_change.failure.code).to eq(:property_mismatch)

      # Attempt changing unit on same property to a unit not matching tenancy
      other_unit_on_prop = create(:rentable_unit, property: property)
      res_unit_change = described_class.call(expense: exp, rentable_unit: other_unit_on_prop)
      expect(res_unit_change).to be_failure
      expect(res_unit_change.failure.code).to eq(:unit_mismatch)
    end
  end
end
