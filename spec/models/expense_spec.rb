require "rails_helper"

RSpec.describe Expense, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:property) }
    it { is_expected.to have_one(:tenant_charge).dependent(:destroy) }
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

    def save_with_tenant_charge!(expense)
      expense.save!
      Expenses::TenantChargeService.call(expense)
    end

    it "creates a reimbursable expense and a matching tenant charge" do
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
        save_with_tenant_charge!(expense)
      }.to change(TenantCharge, :count).by(1)

      charge = expense.tenant_charge
      expect(charge.amount).to eq(150.00)
      expect(charge.tenancy_id).to eq(tenancy.id)
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

      save_with_tenant_charge!(expense)
      expect(expense.tenant_charge.amount).to eq(75.00)
    end

    it "updates charge amount automatically when expense amount is changed (unless custom)" do
      expense = create(:expense,
        property: property,
        amount: 150.00,
        category: "utilities",
        expense_date: Date.current,
        description: "Water bill"
      )
      expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)
      save_with_tenant_charge!(expense)

      expense.assign_attributes(amount: 200.00, reimburse_amount: "150.00")
      save_with_tenant_charge!(expense)

      expect(expense.tenant_charge.amount).to eq(200.00)
    end

    it "does not update charge amount when expense is changed if the charge was custom" do
      expense = create(:expense,
        property: property,
        amount: 150.00,
        category: "utilities",
        expense_date: Date.current,
        description: "Water bill"
      )
      expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id, reimburse_amount: 50.00)
      save_with_tenant_charge!(expense)

      expense.assign_attributes(amount: 200.00, reimburse_amount: "50.00")
      save_with_tenant_charge!(expense)

      expect(expense.tenant_charge.amount).to eq(50.00)
    end

    it "clears custom reimbursement amount when reimburse_amount is set to empty" do
      expense = create(:expense,
        property: property,
        amount: 150.00,
        category: "utilities",
        expense_date: Date.current,
        description: "Water bill"
      )
      expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id, reimburse_amount: 50.00)
      save_with_tenant_charge!(expense)

      expense.assign_attributes(amount: 150.00, reimburse_amount: "")
      save_with_tenant_charge!(expense)

      expect(expense.tenant_charge.amount).to eq(150.00)
    end

    it "syncs programmatic updates when not custom" do
      expense = create(:expense,
        property: property,
        amount: 150.00,
        category: "utilities",
        expense_date: Date.current,
        description: "Water bill"
      )
      expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)
      save_with_tenant_charge!(expense)

      expense.update!(amount: 180.00)
      Expenses::TenantChargeService.call(expense)

      expect(expense.tenant_charge.reload.amount).to eq(180.00)
    end

    it "does not sync programmatic updates when custom" do
      expense = create(:expense,
        property: property,
        amount: 150.00,
        category: "utilities",
        expense_date: Date.current,
        description: "Water bill"
      )
      expense.assign_attributes(tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id, reimburse_amount: 50.00)
      save_with_tenant_charge!(expense)

      expense.update!(amount: 180.00)
      Expenses::TenantChargeService.call(expense)

      expect(expense.tenant_charge.reload.amount).to eq(50.00)
    end
  end

  describe "#reimburse_tenancy_id" do
    it "returns @reimburse_tenancy_id when present" do
      expense = build(:expense, reimburse_tenancy_id: 123)
      expect(expense.reimburse_tenancy_id).to eq(123)
    end

    it "returns tenant_charge tenancy_id when @reimburse_tenancy_id is blank" do
      charge = build(:tenant_charge, tenancy_id: 456)
      expense = build(:expense, tenant_charge: charge)
      expect(expense.reimburse_tenancy_id).to eq(456)
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
