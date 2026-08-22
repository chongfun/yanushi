require "rails_helper"

RSpec.describe PropertyTaxProfile, type: :model do
  let(:property) { create(:property) }

  describe "associations and validations" do
    subject { build(:property_tax_profile, property: property) }

    it { is_expected.to belong_to(:property) }
    it { is_expected.to validate_presence_of(:tax_year) }
    it { is_expected.to validate_presence_of(:schedule_e_property_type) }
    it { is_expected.to validate_numericality_of(:tax_year).only_integer.is_greater_than(1900) }
    it { is_expected.to validate_uniqueness_of(:tax_year).scoped_to(:property_id) }

    it "validates that other_description is required when schedule_e_property_type is other" do
      profile = build(:property_tax_profile, property: property, schedule_e_property_type: "other", other_description: nil)
      expect(profile).not_to be_valid
      expect(profile.errors[:other_description]).to be_present

      profile.other_description = "Storage unit"
      expect(profile).to be_valid
    end

    it "validates that other_description must be blank when schedule_e_property_type is not other" do
      profile = build(:property_tax_profile, property: property, schedule_e_property_type: "single_family_residence", other_description: "Extra text")
      expect(profile).not_to be_valid
      expect(profile.errors[:other_description]).to be_present

      profile.other_description = nil
      expect(profile).to be_valid
    end

    it "normalizes other_description by stripping whitespace" do
      profile = create(:property_tax_profile, :other, property: property, other_description: "  Warehouse  ")
      expect(profile.other_description).to eq("Warehouse")
    end
  end

  describe "#schedule_e_code and #schedule_e_code_description" do
    it "maps semantic property types to IRS codes 1 through 8" do
      mappings = {
        "single_family_residence" => [ 1, "1 — Single-Family Residence" ],
        "multi_family_residence" => [ 2, "2 — Multi-Family Residence" ],
        "vacation_short_term_rental" => [ 3, "3 — Vacation / Short-Term Rental" ],
        "commercial" => [ 4, "4 — Commercial" ],
        "land" => [ 5, "5 — Land" ],
        "royalties" => [ 6, "6 — Royalties" ],
        "self_rental" => [ 7, "7 — Self-Rental" ],
        "other" => [ 8, "8 — Other: Storage facility" ]
      }

      mappings.each do |kind, (expected_code, expected_desc)|
        profile = build(
          :property_tax_profile,
          property: property,
          schedule_e_property_type: kind,
          other_description: (kind == "other" ? "Storage facility" : nil)
        )
        expect(profile.schedule_e_code).to eq(expected_code)
        expect(profile.schedule_e_code_description).to eq(expected_desc)
      end
    end
  end

  describe "Property#tax_profile_for and year isolation" do
    it "retrieves the specific profile for a tax year" do
      profile2025 = create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
      profile2026 = create(:property_tax_profile, property: property, tax_year: 2026, schedule_e_property_type: "commercial")

      expect(property.tax_profile_for(2025)).to eq(profile2025)
      expect(property.tax_profile_for(2026)).to eq(profile2026)
      expect(property.tax_profile_for(2027)).to be_nil
    end

    it "preserves physical asset_type independently of tax profile" do
      expect(property.asset_type).to be_present
      orig_asset_type = property.asset_type

      create(:property_tax_profile, property: property, tax_year: 2026, schedule_e_property_type: "commercial")
      expect(property.reload.asset_type).to eq(orig_asset_type)
    end
  end
end
