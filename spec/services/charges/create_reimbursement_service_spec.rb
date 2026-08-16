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
  let(:expense) { create(:expense, property: property, amount: 300) }

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

    it "allows one expense to reimburse multiple tenancies" do
      unit2 = create(:rentable_unit, property: property, name: "Unit 2")
      tenancy2 = create(:tenancy, rentable_unit: unit2, commencement_date: Date.new(2026, 1, 1), termination_date: Date.new(2026, 12, 31))

      result1 = described_class.call(expense: expense, tenancy: tenancy, amount_cents: 15_000)
      result2 = described_class.call(expense: expense, tenancy: tenancy2, amount_cents: 15_000)

      expect(result1).to be_success
      expect(result2).to be_success
      expect(expense.charges.count).to eq(2)
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
      other_expense = create(:expense, property: other_property, amount: 200)

      result = described_class.call(
        expense: other_expense,
        tenancy: tenancy,
        amount_cents: 10_000
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:property_mismatch)
    end

    it "rejects reimbursement when expense belongs to a different user" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)
      other_expense = create(:expense, property: other_property, amount: 200)

      result = described_class.call(
        expense: other_expense,
        tenancy: tenancy,
        amount_cents: 10_000
      )

      expect(result).to be_failure
      expect(result.failure.code).to eq(:property_mismatch)
    end
  end
end
