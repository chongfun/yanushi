require "rails_helper"

RSpec.describe SecurityDeposit, type: :model do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  describe "validations" do
    it "is valid with valid attributes" do
      expect(security_deposit).to be_valid
    end

    it "requires positive required_amount_cents" do
      deposit = build(:security_deposit, tenancy: tenancy, required_amount_cents: 0)
      expect(deposit).not_to be_valid
      expect(deposit.errors[:required_amount_cents]).to be_present

      deposit.required_amount_cents = -500
      expect(deposit).not_to be_valid
    end

    it "requires due_on" do
      deposit = build(:security_deposit, tenancy: tenancy, due_on: nil)
      expect(deposit).not_to be_valid
      expect(deposit.errors[:due_on]).to be_present
    end

    it "enforces unique tenancy_id" do
      security_deposit
      duplicate = build(:security_deposit, tenancy: tenancy)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:tenancy_id]).to be_present
    end
  end

  describe "amount parsing helpers and delegation" do
    it "converts required_amount_cents to required_amount decimal" do
      deposit = build(:security_deposit, required_amount_cents: 150_550)
      expect(deposit.required_amount).to eq(1505.50)

      deposit_nil = build(:security_deposit, required_amount_cents: nil)
      expect(deposit_nil.required_amount).to eq(0.0)
    end

    it "sets required_amount_cents from string/numeric amount" do
      deposit = build(:security_deposit)
      deposit.required_amount = "2500.50"
      expect(deposit.required_amount_cents).to eq(250_050)

      deposit.required_amount = 3000
      expect(deposit.required_amount_cents).to eq(300_000)

      deposit.required_amount = ""
      expect(deposit.required_amount_cents).to be_nil

      deposit.required_amount = "invalid"
      expect(deposit.required_amount_cents).to eq(-1)
      expect(deposit).not_to be_valid
    end

    it "delegates accounting_user, property, and rentable_unit" do
      expect(security_deposit.accounting_user).to eq(user)
      expect(security_deposit.property).to eq(property)
      expect(security_deposit.rentable_unit).to eq(unit)

      orphan_deposit = SecurityDeposit.new
      expect(orphan_deposit.accounting_user).to be_nil
      expect(orphan_deposit.property).to be_nil
      expect(orphan_deposit.rentable_unit).to be_nil
    end
  end

  describe "immutability after transactions exist" do
    it "allows updating requirement before any transaction exists" do
      expect(security_deposit.update(required_amount_cents: 250_000, due_on: Date.current + 1.month)).to be true
      expect(security_deposit.reload.required_amount_cents).to eq(250_000)
    end

    it "prohibits updating requirement or tenancy after a transaction exists" do
      create(:security_deposit_transaction, :received, security_deposit: security_deposit, amount_cents: 50_000)

      expect(security_deposit.update(required_amount_cents: 300_000)).to be false
      expect(security_deposit.errors[:required_amount_cents]).to include("cannot be changed after deposit transactions exist")

      expect(security_deposit.update(due_on: Date.current + 10.days)).to be false
      expect(security_deposit.errors[:due_on]).to include("cannot be changed after deposit transactions exist")

      other_u = create(:rentable_unit, property: property)
      other_t = create(:tenancy, rentable_unit: other_u)
      expect(security_deposit.update(tenancy_id: other_t.id)).to be false
      expect(security_deposit.errors[:tenancy_id]).to include("cannot be changed after deposit transactions exist")
    end
  end

  describe "funding status helpers" do
    it "reports funding statuses based on held_cents" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      allow(deposit).to receive(:held_cents).and_return(0)
      expect(deposit.funding_status).to eq("not_funded")
      expect(deposit.held_amount).to eq(0.0)
      expect(deposit.remaining_required_cents).to eq(200_000)
      expect(deposit.fully_funded?).to be false
      expect(deposit.overfunded?).to be false

      allow(deposit).to receive(:held_cents).and_return(100_000)
      expect(deposit.funding_status).to eq("partially_funded")
      expect(deposit.held_amount).to eq(1000.0)
      expect(deposit.remaining_required_cents).to eq(100_000)
      expect(deposit.remaining_required_amount).to eq(1000.0)

      allow(deposit).to receive(:held_cents).and_return(200_000)
      expect(deposit.funding_status).to eq("funded")
      expect(deposit.remaining_required_cents).to eq(0)
      expect(deposit.fully_funded?).to be true
      expect(deposit.overfunded?).to be false

      allow(deposit).to receive(:held_cents).and_return(250_000)
      expect(deposit.funding_status).to eq("overfunded")
      expect(deposit.remaining_required_cents).to eq(0)
      expect(deposit.fully_funded?).to be true
      expect(deposit.overfunded?).to be true
    end
  end
end
