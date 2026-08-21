require "rails_helper"

RSpec.describe Property, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:rentable_units).dependent(:destroy) }
    it { is_expected.to have_many(:tenancies).through(:rentable_units) }
    it { is_expected.to have_many(:expenses).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:charges).through(:tenancies) }
    it { is_expected.to have_many(:receipts).through(:tenancies) }
    it { is_expected.to have_many(:accounting_postings).class_name("Posting").dependent(:restrict_with_error) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:asset_type).with_values(Property::ASSET_TYPES.index_by(&:itself)).backed_by_column_of_type(:string) }

    it "validates enum assignment without raising ArgumentError" do
      prop = build(:property, asset_type: "invalid_asset")
      expect(prop).not_to be_valid
      expect(prop.errors[:asset_type]).to include("is not included in the list")
    end
  end

  describe "validations" do
    subject { build(:property) }

    it { is_expected.to validate_presence_of(:address) }
    it { is_expected.to validate_presence_of(:asset_type) }
    it { is_expected.to validate_numericality_of(:square_footage).only_integer.is_greater_than(0).allow_nil }

    it "validates address uniqueness scoped to user_id" do
      user = create(:user)
      create(:property, user: user, address: "123 Main St")
      duplicate = build(:property, user: user, address: "123 Main St")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:address]).to include("has already been taken")
    end

    it "allows same address for different users" do
      user1 = create(:user)
      user2 = create(:user)
      create(:property, user: user1, address: "123 Main St")
      other_user_property = build(:property, user: user2, address: "123 Main St")
      expect(other_user_property).to be_valid
    end
  end

  describe "delegation and query methods" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }

    it "delegates financial queries correctly" do
      expect(property.active_years).to include(Date.current.year)
      expect(property.financial_items(year: Date.current.year)).to eq([])
      expect(property.accounting_activity(year: Date.current.year)).to eq([])
      expect(property.accounting_summary(year: Date.current.year).net_cash_movement_cents).to eq(0)
      summary = property.schedule_e_summary(year: Date.current.year)
      expect(summary.total_income).to eq(0)
    end

    it "returns the owning user via #accounting_user" do
      expect(property.accounting_user).to eq(user)
    end
  end
end
