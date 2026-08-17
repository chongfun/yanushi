require "rails_helper"

RSpec.describe Charges::CreateReimbursementService do
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
  let(:expense) { create(:expense, :posted, property: property, amount_cents: 30_000) }

  describe ".call" do
    it "creates and posts a reimbursement charge for tenancy matching expense property" do
      result = described_class.call(
        expense: expense,
        tenancy: tenancy,
        amount_cents: 15_000,
        description: "Water bill reimbursement"
      )

      expect(result).to be_success
      charge = result.value!.data[:charge]
      expect(charge.reimbursement?).to be true
      expect(charge.source_expense).to eq(expense)
      expect(charge.amount_cents).to eq(15_000)
    end

    it "allows one property-wide expense to reimburse multiple tenancies" do
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      result1 = described_class.call(expense: expense, tenancy: tenancy, amount_cents: 15_000)
      result2 = described_class.call(expense: expense, tenancy: tenancy2, amount_cents: 15_000)

      expect(result1).to be_success
      expect(result2).to be_success
      expect(expense.reimbursement_charges.count).to eq(2)
      expect(expense.remaining_reimbursable_cents).to eq(0)
    end

    it "enforces unit scoping for unit-specific expense" do
      unit_exp = create(:expense, :posted, property: property, rentable_unit: unit, amount_cents: 20_000)
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      # Tenancy in unit succeeds
      res1 = described_class.call(expense: unit_exp, tenancy: tenancy, amount_cents: 10_000)
      expect(res1).to be_success

      # Tenancy in unit2 fails
      res2 = described_class.call(expense: unit_exp, tenancy: tenancy2, amount_cents: 10_000)
      expect(res2).to be_failure
      expect(res2.failure.code).to eq(:unit_mismatch)
    end

    it "rejects reimbursement for unposted, voided, or superseded expense" do
      unposted_exp = create(:expense, property: property, posted_at: nil, amount_cents: 20_000)
      voided_exp = create(:expense, :voided, property: property, amount_cents: 20_000)
      superseded_exp = create(:expense, :superseded, property: property, amount_cents: 20_000)

      res1 = described_class.call(expense: unposted_exp, tenancy: tenancy, amount_cents: 10_000)
      expect(res1).to be_failure
      expect(res1.failure.code).to eq(:invalid_expense_state)

      res2 = described_class.call(expense: voided_exp, tenancy: tenancy, amount_cents: 10_000)
      expect(res2).to be_failure
      expect(res2.failure.code).to eq(:invalid_expense_state)

      res3 = described_class.call(expense: superseded_exp, tenancy: tenancy, amount_cents: 10_000)
      expect(res3).to be_failure
      expect(res3.failure.code).to eq(:invalid_expense_state)
    end

    it "rejects reimbursement when amount exceeds remaining reimbursable amount" do
      result = described_class.call(
        expense: expense,
        tenancy: tenancy,
        amount_cents: 35_000
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:exceeds_expense_amount)
      expect(result.failure.error).to include("exceeds remaining reimbursable amount")
    end

    it "rejects second reimbursement when cumulative amount exceeds expense amount" do
      result1 = described_class.call(expense: expense, tenancy: tenancy, amount_cents: 20_000)
      expect(result1).to be_success

      result2 = described_class.call(expense: expense, tenancy: tenancy, amount_cents: 15_000)
      expect(result2).to be_failure
      expect(result2.failure.code).to eq(:exceeds_expense_amount)
    end

    it "allows reimbursement when previous charge has been voided" do
      result1 = described_class.call(expense: expense, tenancy: tenancy, amount_cents: 30_000)
      expect(result1).to be_success
      charge1 = result1.value!.data[:charge]

      # Second should fail
      result2 = described_class.call(expense: expense, tenancy: tenancy, amount_cents: 10_000)
      expect(result2).to be_failure

      # Void first charge
      Charges::VoidService.call(charge: charge1)

      # Now second should succeed
      result3 = described_class.call(expense: expense, tenancy: tenancy, amount_cents: 30_000)
      expect(result3).to be_success
    end

    it "rejects reimbursement when expense belongs to a different property" do
      other_property = create(:property, user: user)
      other_expense = create(:expense, :posted, property: other_property, amount_cents: 20_000)

      result = described_class.call(
        expense: other_expense,
        tenancy: tenancy,
        amount_cents: 10_000
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:property_mismatch)
    end

    it "safely serializes concurrent reimbursement creation against expense row lock" do
      unit2 = create(:rentable_unit, property: property)
      tenancy2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      res1 = nil
      res2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res1 = described_class.call(expense: Expense.find(expense.id), tenancy: Tenancy.find(tenancy.id), amount_cents: 20_000)
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res2 = described_class.call(expense: Expense.find(expense.id), tenancy: Tenancy.find(tenancy2.id), amount_cents: 20_000)
        end
      end

      [ t1, t2 ].each(&:join)

      successes = [ res1, res2 ].count(&:success?)
      failures = [ res1, res2 ].count(&:failure?)

      expect(successes).to eq(1)
      expect(failures).to eq(1)
      expect(expense.reload.total_active_reimbursement_cents).to eq(20_000)
    end

    it "rejects non-integer amount_cents and supports exact dollar strings" do
      expect(described_class.call(expense: expense, tenancy: tenancy, amount_cents: "10000")).to be_failure
      expect(described_class.call(expense: expense, tenancy: tenancy, amount_cents: "10000oops")).to be_failure
      expect(described_class.call(expense: expense, tenancy: tenancy, amount_cents: -500)).to be_failure

      res = described_class.call(expense: expense, tenancy: tenancy, amount: "123.45")
      expect(res).to be_success
      expect(res.value!.data[:charge].amount_cents).to eq(12_345)
    end

    it "rejects missing inputs and ownership mismatch" do
      expect(described_class.call(expense: nil, tenancy: tenancy, amount_cents: 10_000)).to be_failure
      expect(described_class.call(expense: expense, tenancy: nil, amount_cents: 10_000)).to be_failure

      other_user = create(:user)
      other_prop = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_prop)
      foreign_tenancy = create(:tenancy, rentable_unit: other_unit)
      # Force property mismatch bypassed to test ownership check specifically
      allow(expense).to receive(:property_id).and_return(other_prop.id)
      res = described_class.call(expense: expense, tenancy: foreign_tenancy, amount_cents: 10_000)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:ownership_mismatch)
    end
  end
end
