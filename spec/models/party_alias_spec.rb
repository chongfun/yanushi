require "rails_helper"

RSpec.describe PartyAlias, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:party) }
  end

  describe "validations" do
    subject { build(:party_alias) }

    it { is_expected.to validate_presence_of(:alias_name) }

    it "validates uniqueness of alias_name case-insensitively within the same party" do
      party = create(:party)
      create(:party_alias, party: party, alias_name: "JohnDoe")
      duplicate = build(:party_alias, party: party, alias_name: "johndoe")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:alias_name]).to include("has already been taken")
    end

    it "allows the same alias_name for different parties" do
      party1 = create(:party)
      party2 = create(:party)
      create(:party_alias, party: party1, alias_name: "JohnDoe")
      other = build(:party_alias, party: party2, alias_name: "JohnDoe")

      expect(other).to be_valid
    end
  end
end
