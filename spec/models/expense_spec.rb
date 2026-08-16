require "rails_helper"

RSpec.describe Expense, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:property) }
    it { is_expected.to have_many(:charges).with_foreign_key(:source_expense_id).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:reimbursement_charges).class_name("Charge").with_foreign_key(:source_expense_id).dependent(:restrict_with_error) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:category).with_values(
      advertising: "advertising",
      auto_and_travel: "auto_and_travel",
      cleaning_and_maintenance: "cleaning_and_maintenance",
      commissions: "commissions",
      insurance: "insurance",
      legal_and_other_professional_fees: "legal_and_other_professional_fees",
      management_fees: "management_fees",
      mortgage_interest: "mortgage_interest",
      other_interest: "other_interest",
      repairs: "repairs",
      supplies: "supplies",
      taxes: "taxes",
      utilities: "utilities",
      depreciation_expense: "depreciation_expense",
      other: "other"
    ).backed_by_column_of_type(:string) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:amount) }
    it { is_expected.to validate_numericality_of(:amount).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:category) }
    it { is_expected.to validate_presence_of(:expense_date) }

    context "when tenant_reimbursable is true" do
      subject { build(:expense, tenant_reimbursable: true) }

      it { is_expected.to validate_numericality_of(:reimburse_amount).is_greater_than(0).allow_blank }
    end
  end

  describe "reimbursement integration" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }

    it "creates a reimbursable expense and a matching reimbursement Charge" do
      expense = build(:expense,
        property: property,
        amount: 150.00,
        category: "utilities",
        expense_date: Date.current,
        description: "Water bill",
        tenant_reimbursable: true,
        reimburse_tenancy_id: tenancy.id
      )

      expect {
        result = Expenses::SaveService.call(expense: expense)
        expect(result).to be_success
      }.to change(Charge, :count).by(1)

      charge = expense.reimbursement_charges.first
      expect(charge.amount).to eq(150.00)
      expect(charge.tenancy_id).to eq(tenancy.id)
      expect(charge.reimbursement?).to be true
      expect(charge.posted?).to be true
    end

    it "creates a reimbursable expense with a custom amount" do
      expense = build(:expense,
        property: property,
        amount: 150.00,
        category: "utilities",
        expense_date: Date.current,
        description: "Water bill",
        tenant_reimbursable: true,
        reimburse_tenancy_id: tenancy.id,
        reimburse_amount: 75.00
      )

      Expenses::SaveService.call(expense: expense)
      expect(expense.reimbursement_charges.first.amount).to eq(75.00)
    end
  end

  describe "#reimburse_tenancy_id" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }

    it "returns @reimburse_tenancy_id when present" do
      expense = build(:expense, reimburse_tenancy_id: 123)
      expect(expense.reimburse_tenancy_id).to eq(123)
    end

    it "returns first reimbursement_charge tenancy_id when @reimburse_tenancy_id is blank" do
      expense = create(:expense, property: property, amount: 100)
      create(:charge, :reimbursement_charge, tenancy: tenancy, source_expense: expense, amount_cents: 10_000)
      expect(expense.reload.reimburse_tenancy_id).to eq(tenancy.id)
    end
  end

  describe "#prevent_property_change_with_charges" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:other_property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }
    let(:expense) { create(:expense, property: property, amount: 100) }

    it "allows changing property when no charges exist" do
      expense.property = other_property
      expect(expense).to be_valid
    end

    it "rejects changing property when reimbursement charges exist" do
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy,
        amount: 50.0,
        charge_date: Date.current,
        due_on: Date.current
      )

      expense.property = other_property
      expect(expense).not_to be_valid
      expect(expense.errors[:property]).to include("cannot change after reimbursement charges have been posted")
    end
  end

  describe "reimbursement amount tracking" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }
    let(:expense) { create(:expense, property: property, amount: 200.0) }

    it "calculates remaining reimbursable amount correctly" do
      expect(expense.remaining_reimbursable_cents).to eq(20_000)
      expect(expense.remaining_reimbursable_amount).to eq(200.0)
      expect(expense.fully_reimbursed?).to be false

      # Create partial reimbursement
      charge1 = Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy,
        amount: 75.0,
        charge_date: Date.current,
        due_on: Date.current
      ).value!.data[:charge]

      expect(expense.total_active_reimbursement_cents).to eq(7500)
      expect(expense.remaining_reimbursable_cents).to eq(12_500)
      expect(expense.remaining_reimbursable_amount).to eq(125.0)
      expect(expense.fully_reimbursed?).to be false

      # Create second reimbursement to fully reimburse
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy,
        amount: 125.0,
        charge_date: Date.current,
        due_on: Date.current
      )

      expect(expense.total_active_reimbursement_cents).to eq(20_000)
      expect(expense.remaining_reimbursable_cents).to eq(0)
      expect(expense.remaining_reimbursable_amount).to eq(0.0)
      expect(expense.fully_reimbursed?).to be true

      # Voiding the first charge frees up available amount
      Charges::VoidService.call(charge: charge1)
      expect(expense.total_active_reimbursement_cents).to eq(12_500)
      expect(expense.remaining_reimbursable_cents).to eq(7500)
      expect(expense.remaining_reimbursable_amount).to eq(75.0)
      expect(expense.fully_reimbursed?).to be false
    end
  end

  describe "#prevent_amount_reduction_below_reimbursements" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }
    let(:expense) { create(:expense, property: property, amount: 300.0) }

    before do
      Charges::CreateReimbursementService.call(
        expense: expense,
        tenancy: tenancy,
        amount: 200.0,
        charge_date: Date.current,
        due_on: Date.current
      )
    end

    it "rejects reducing amount below active reimbursement total" do
      expense.amount = 150.0
      expect(expense).not_to be_valid
      expect(expense.errors[:amount]).to include("cannot be reduced below total active reimbursement charges ($200.00)")
    end

    it "allows reducing amount down to the exact active reimbursement total" do
      expense.amount = 200.0
      expect(expense).to be_valid
    end

    it "allows reducing amount above the active reimbursement total" do
      expense.amount = 250.0
      expect(expense).to be_valid
    end

    it "allows reducing amount after active reimbursement is voided" do
      charge = expense.reimbursement_charges.first
      Charges::VoidService.call(charge: charge)

      expense.amount = 100.0
      expect(expense).to be_valid
    end
  end

  describe "#accounting_user" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:expense) { create(:expense, property: property) }

    it "returns the property user" do
      expect(expense.accounting_user).to eq(user)
    end

    it "returns nil when property is absent" do
      orphan = build(:expense, property: nil)
      expect(orphan.accounting_user).to be_nil
    end
  end
end
