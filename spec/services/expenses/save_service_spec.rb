require "rails_helper"

RSpec.describe Expenses::SaveService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "saves the expense and creates a reimbursement charge in one transaction" do
    expense = build(:expense, property: property, amount: 250, tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)

    expect {
      result = described_class.call(expense: expense)
      expect(result).to be_success
    }.to change(Expense, :count).by(1).and change(Charge, :count).by(1)

    charge = expense.reimbursement_charges.first
    expect(charge).to be_present
    expect(charge.amount_cents).to eq(25_000)
    expect(charge.tenancy).to eq(tenancy)
    expect(charge.posted?).to be true
  end

  it "does not mutate existing reimbursement charges when expense is edited" do
    expense = build(:expense, property: property, amount: 250, tenant_reimbursable: true, reimburse_tenancy_id: tenancy.id)
    described_class.call(expense: expense)

    charge = expense.reimbursement_charges.first
    expect(charge.amount_cents).to eq(25_000)

    expense.amount = 300
    expect {
      result = described_class.call(expense: expense)
      expect(result).to be_success
    }.not_to change(Charge, :count)

    expect(charge.reload.amount_cents).to eq(25_000)
  end

  it "returns validation errors without persisting" do
    expense = build(:expense, property: property, amount: -1)

    result = described_class.call(expense: expense)

    expect(result).to be_failure
    expect(expense).not_to be_persisted
  end

  it "rejects reducing amount below active reimbursement charges" do
    expense = create(:expense, property: property, amount: 200)
    Charges::CreateReimbursementService.call(expense: expense, tenancy: tenancy, amount: 150)

    expense.amount = 100
    result = described_class.call(expense: expense)

    expect(result).to be_failure
    expect(result.failure.error).to include("cannot be reduced below total active reimbursement charges")
    expect(expense.reload.amount).to eq(200)
  end

  it "rejects changing property when reimbursement charges exist" do
    other_property = create(:property, user: user)
    expense = create(:expense, property: property, amount: 200)
    Charges::CreateReimbursementService.call(expense: expense, tenancy: tenancy, amount: 150)

    expense.property = other_property
    result = described_class.call(expense: expense)

    expect(result).to be_failure
    expect(result.failure.error).to include("cannot change after reimbursement charges have been posted")
    expect(expense.reload.property).to eq(property)
  end

  it "serializes concurrent reimbursement creation and expense edit" do
    expense = create(:expense, property: property, amount: 300)
    other_property = create(:property, user: user)

    # Thread 1 starts reimbursement creation with a lock
    # Thread 2 attempts to move expense to other_property
    t1_started = Concurrent::Event.new
    t1_proceed = Concurrent::Event.new

    t1 = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Expense.transaction do
          expense_record = Expense.lock.find(expense.id)
          t1_started.set
          t1_proceed.wait(5)
          Charges::CreateReimbursementService.call(
            expense: expense_record,
            tenancy: tenancy,
            amount: 200
          )
        end
      end
    end

    t1_started.wait(5)

    # In main thread, attempt to change property via SaveService
    expense_to_edit = Expense.find(expense.id)
    expense_to_edit.property = other_property

    # Release thread 1 right after calling or in parallel
    t2 = Thread.new do
      sleep 0.05
      t1_proceed.set
    end

    result = described_class.call(expense: expense_to_edit)

    t1.join
    t2.join

    # Because T1 locked the row and posted reimbursement, SaveService had to wait for T1's lock,
    # then re-evaluated validation with reimbursement charge present, failing the property update.
    expect(result).to be_failure
    expect(expense.reload.property).to eq(property)
    expect(expense.reimbursement_charges.count).to eq(1)
  end
end
