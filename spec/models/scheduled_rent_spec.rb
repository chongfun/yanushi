require "rails_helper"

RSpec.describe ScheduledRent, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  describe "associations" do
    it { is_expected.to belong_to(:tenancy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:amount) }
    it { is_expected.to validate_numericality_of(:amount).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:due_date) }
  end

  describe "instance methods" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit, late_period_days: 5) }
    let(:rent) { create(:scheduled_rent, tenancy: tenancy, amount: 1000.0, due_date: Date.parse("2026-05-01")) }

    describe "#covered?" do
      it "returns false when not paid" do
        expect(rent.covered?).to be_falsey
      end

      it "returns true when fully paid" do
        create(:tenant_payment, tenancy: tenancy, amount: 1000.0, payment_date: Date.parse("2026-05-01"))
        expect(rent.covered?).to be_truthy
      end

      it "returns false when due date is missing" do
        rent = build(:scheduled_rent, tenancy: tenancy, due_date: nil)
        expect(rent.covered?).to be(false)
      end
    end

    describe "#late?" do
      it "returns false if covered" do
        create(:tenant_payment, tenancy: tenancy, amount: 1000.0, payment_date: Date.parse("2026-05-01"))
        travel_to Date.parse("2026-05-10") do
          expect(rent.late?).to be_falsey
        end
      end

      it "returns false if not covered but before late period grace days" do
        travel_to Date.parse("2026-05-03") do
          expect(rent.late?).to be_falsey
        end
      end

      it "returns true if not covered and after late period grace days" do
        travel_to Date.parse("2026-05-07") do
          expect(rent.late?).to be_truthy
        end
      end

      it "returns false when due date is missing" do
        rent = build(:scheduled_rent, tenancy: tenancy, due_date: nil)
        expect(rent.late?).to be(false)
      end

      it "returns false when late period days are missing" do
        tenancy = build(:tenancy, late_period_days: nil)
        rent = build(:scheduled_rent, tenancy: tenancy)
        expect(rent.late?).to be(false)
      end
    end

    describe "#display_name" do
      it "returns formatted display name" do
        expect(rent.display_name).to eq("#{property.address} - 2026-05-01")
      end

      it "falls back to default when tenancy/property is absent" do
        orphan_rent = build(:scheduled_rent, tenancy: nil, due_date: Date.new(2026, 5, 1))
        expect(orphan_rent.display_name).to eq("Property - 2026-05-01")
      end
    end

    describe "#accounting_user" do
      it "returns the user of the tenancy property" do
        expect(rent.accounting_user).to eq(user)
      end

      it "returns nil when tenancy is absent" do
        orphan_rent = build(:scheduled_rent, tenancy: nil)
        expect(orphan_rent.accounting_user).to be_nil
      end
    end
  end
end
