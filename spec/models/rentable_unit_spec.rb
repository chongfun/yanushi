require "rails_helper"

RSpec.describe RentableUnit, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:property) }
    it { is_expected.to have_many(:tenancies).dependent(:restrict_with_error) }
  end

  describe "validations" do
    subject { build(:rentable_unit) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_numericality_of(:square_footage).only_integer.is_greater_than(0).allow_nil }

    it "validates name uniqueness scoped to property_id" do
      property = create(:property)
      create(:rentable_unit, property: property, name: "Unit A")
      duplicate = build(:rentable_unit, property: property, name: "Unit A")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "validates unit_identifier uniqueness scoped to property_id" do
      property = create(:property)
      create(:rentable_unit, property: property, name: "Unit 1", unit_identifier: "101")
      duplicate = build(:rentable_unit, property: property, name: "Unit 2", unit_identifier: "101")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:unit_identifier]).to include("has already been taken")
    end

    it "allows same unit name for different properties" do
      prop1 = create(:property)
      prop2 = create(:property)
      create(:rentable_unit, property: prop1, name: "Unit A")
      other = build(:rentable_unit, property: prop2, name: "Unit A")
      expect(other).to be_valid
    end

    it "normalizes name and unit_identifier with nil, whitespace, or presence" do
      unit = build(:rentable_unit, name: "  Unit 1  ", unit_identifier: "  1A  ")
      expect(unit.name).to eq("Unit 1")
      expect(unit.unit_identifier).to eq("1A")

      unit_nil = build(:rentable_unit, name: nil, unit_identifier: nil)
      expect(unit_nil.name).to be_nil
      expect(unit_nil.unit_identifier).to be_nil

      unit_blank = build(:rentable_unit, unit_identifier: "   ")
      expect(unit_blank.unit_identifier).to be_nil
    end
  end

  describe "#display_name" do
    let(:property) { create(:property, address: "742 Evergreen Terr") }

    it "combines name and unit identifier when present" do
      unit = create(:rentable_unit, property: property, name: "Apartment 2", unit_identifier: "2B")
      expect(unit.display_name).to eq("Apartment 2 (2B)")
    end

    it "returns name when unit identifier is blank" do
      unit = create(:rentable_unit, property: property, name: "Main House", unit_identifier: nil)
      expect(unit.display_name).to eq("Main House")
    end
  end

  describe "#occupied? and active scope" do
    let(:property) { create(:property) }
    let(:unit) { create(:rentable_unit, property: property) }

    it "returns false when no active tenancies" do
      expect(unit.occupied?).to be false
    end

    it "returns true when an active tenancy exists" do
      create(:tenancy, rentable_unit: unit, commencement_date: 1.month.ago, termination_date: 1.month.from_now)
      expect(unit.occupied?).to be true
      expect(unit.occupied?(2.months.ago)).to be false
      expect(unit.occupied?(Date.current)).to be true
    end
  end

  describe "#accounting_user" do
    let(:user) { create(:user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }

    it "returns the property user" do
      expect(unit.accounting_user).to eq(user)
    end

    it "returns nil if property is absent" do
      orphan = build(:rentable_unit, property: nil)
      expect(orphan.accounting_user).to be_nil
    end
  end
end
