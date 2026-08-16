require "rails_helper"

RSpec.describe TenantPayment, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:tenancy) }
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:amount) }
    it { is_expected.to validate_numericality_of(:amount).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:payment_date) }
    it { is_expected.to validate_presence_of(:payment_method) }

    describe "transaction number validation" do
      it { is_expected.to allow_value("TXN-123_abc").for(:transaction_number) }
      it { is_expected.not_to allow_value("TXN 123!").for(:transaction_number).with_message("must be alphanumeric with dashes or underscores") }
      it { is_expected.to validate_length_of(:transaction_number).is_at_most(50) }
    end

    describe "uniqueness and user scoping" do
      let(:user_one) { create(:user) }
      let(:user_two) { create(:user) }
      let(:property_one) { create(:property, user: user_one) }
      let(:property_two) { create(:property, user: user_two) }
      let(:unit_one) { create(:rentable_unit, property: property_one) }
      let(:unit_two) { create(:rentable_unit, property: property_two) }
      let(:tenancy_one) { create(:tenancy, rentable_unit: unit_one) }
      let(:tenancy_two) { create(:tenancy, rentable_unit: unit_two) }

      it "assigns user from tenancy on validation" do
        tp = build(:tenant_payment, tenancy: tenancy_one, user: nil)
        expect(tp).to be_valid
        expect(tp.user).to eq(user_one)
      end

      it "validates that user matches tenancy owner" do
        tp = build(:tenant_payment, tenancy: tenancy_one, user: user_two)
        expect(tp).not_to be_valid
        expect(tp.errors[:user]).to include("must match the tenancy owner")
      end

      it "allows same transaction number for different users" do
        create(:tenant_payment, tenancy: tenancy_one, amount: 500, payment_method: "zelle", transaction_number: "SHARED123")
        payment = build(:tenant_payment, tenancy: tenancy_two, amount: 500, payment_method: "zelle", transaction_number: "SHARED123")
        expect(payment).to be_valid
      end

      it "rejects duplicate transaction number for same user and payment method" do
        create(:tenant_payment, tenancy: tenancy_one, amount: 500, payment_method: "zelle", transaction_number: "DUPLICATE123")
        payment = build(:tenant_payment, tenancy: tenancy_one, amount: 500, payment_method: "zelle", transaction_number: "DUPLICATE123")
        expect(payment).not_to be_valid
        expect(payment.errors[:transaction_number]).to include("has already been taken")
      end

      it "allows same transaction number for same user but different payment method" do
        create(:tenant_payment, tenancy: tenancy_one, amount: 500, payment_method: "zelle", transaction_number: "SHARED123")
        payment = build(:tenant_payment, tenancy: tenancy_one, amount: 500, payment_method: "check", transaction_number: "SHARED123")
        expect(payment).to be_valid
      end

      it "returns early from owner validation if user or tenancy is missing" do
        tp = TenantPayment.new(user: nil, tenancy: nil)
        tp.valid?
        expect(tp.errors[:user]).not_to include("must match the tenancy owner")
      end

      it "returns early from owner validation if user is present but tenancy is missing" do
        tp = TenantPayment.new(user: user_one, tenancy: nil)
        tp.valid?
        expect(tp.errors[:user]).not_to include("must match the tenancy owner")
      end

      it "handles assign_user_from_tenancy when tenancy has no property" do
        orphan_tenancy = build(:tenancy, rentable_unit: nil)
        tp = TenantPayment.new(tenancy: orphan_tenancy, user: nil)
        tp.valid?
        expect(tp.user).to be_nil
      end
    end
  end

  describe "#accounting_user" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }

    it "returns the user attribute when present" do
      payment = build(:tenant_payment, tenancy: tenancy, user: user)
      expect(payment.accounting_user).to eq(user)
    end

    it "returns tenancy owner when user is nil" do
      payment = build(:tenant_payment, tenancy: tenancy, user: nil)
      expect(payment.accounting_user).to eq(user)
    end

    it "returns nil when user and tenancy are nil" do
      payment = build(:tenant_payment, tenancy: nil, user: nil)
      expect(payment.accounting_user).to be_nil
    end
  end

  describe "immutability" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }
    let(:payment) { create(:tenant_payment, tenancy: tenancy, amount: 500) }

    it "prevents updating attributes on persisted payment" do
      payment.amount = 600
      expect(payment.save).to be(false)
      expect(payment.errors[:base]).to include("Tenant payments are immutable once recorded.")
    end

    it "prevents destroying persisted payment" do
      expect(payment.destroy).to be(false)
      expect(payment.errors[:base]).to include("Tenant payments cannot be destroyed once recorded.")
      expect(TenantPayment.exists?(payment.id)).to be(true)
    end
  end
end
