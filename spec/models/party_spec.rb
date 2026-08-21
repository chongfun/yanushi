require "rails_helper"

RSpec.describe Party, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:party_aliases).dependent(:destroy) }
    it { is_expected.to have_many(:tenancy_parties).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:tenancies).through(:tenancy_parties) }
    it { is_expected.to have_many(:imported_transactions).with_foreign_key(:matched_party_id).dependent(:nullify) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:party_type).with_values(Party::PARTY_TYPES.index_by(&:itself)).backed_by_column_of_type(:string) }

    it "validates enum assignment without raising ArgumentError" do
      party = build(:party, party_type: "invalid_type")
      expect(party).not_to be_valid
      expect(party.errors[:party_type]).to include("is not included in the list")
    end
  end

  describe "validations" do
    subject { build(:party) }

    it { is_expected.to validate_presence_of(:display_name) }
    it { is_expected.to validate_presence_of(:party_type) }

    it "validates email format if present" do
      valid_party = build(:party, email_address: "john@example.com")
      invalid_party = build(:party, email_address: "invalid-email")

      expect(valid_party).to be_valid
      expect(invalid_party).not_to be_valid
      expect(invalid_party.errors[:email_address]).to include("is invalid")
    end

    it "allows blank email" do
      party = build(:party, email_address: nil)
      expect(party).to be_valid
    end

    it "normalizes display_name and email_address with nil, whitespace, or case" do
      party = build(:party, display_name: "  Jane Doe  ", email_address: "  JANE@EXAMPLE.COM  ")
      expect(party.display_name).to eq("Jane Doe")
      expect(party.email_address).to eq("jane@example.com")

      party_nil = build(:party, display_name: nil, email_address: nil)
      expect(party_nil.display_name).to be_nil
      expect(party_nil.email_address).to be_nil

      party_blank_email = build(:party, email_address: "   ")
      expect(party_blank_email.email_address).to be_nil
    end
  end

  describe "type predicates" do
    it "identifies individual and organization" do
      individual = build(:party, party_type: "individual")
      org = build(:party, party_type: "organization")

      expect(individual.individual?).to be true
      expect(individual.organization?).to be false
      expect(org.organization?).to be true
      expect(org.individual?).to be false
    end
  end

  describe "nested attributes for party_aliases" do
    let(:user) { create(:user) }

    it "accepts nested attributes for party_aliases" do
      party = create(:party, user: user, display_name: "Alice Smith", party_aliases_attributes: [ { alias_name: "Ali Smith" }, { alias_name: "@alice_s" } ])
      expect(party.party_aliases.count).to eq(2)
      expect(party.party_aliases.pluck(:alias_name)).to contain_exactly("Ali Smith", "@alice_s")
    end
  end

  describe "#alias_candidate?" do
    let(:user) { create(:user) }
    let(:party) { create(:party, user: user, display_name: "Alice Smith") }

    it "returns false if alias_name is blank" do
      expect(party.alias_candidate?(nil)).to be false
      expect(party.alias_candidate?("   ")).to be false
    end

    it "returns false if display_name is blank" do
      party.display_name = nil
      expect(party.alias_candidate?("Ali")).to be false
    end

    it "returns false if alias_name matches display_name case-insensitively" do
      expect(party.alias_candidate?("Alice Smith")).to be false
      expect(party.alias_candidate?("  alice smith  ")).to be false
    end

    it "checks in-memory loaded party_aliases" do
      create(:party_alias, party: party, alias_name: "Ali")
      party.party_aliases.load

      expect(party.alias_candidate?("Ali")).to be false
      expect(party.alias_candidate?("Alice S.")).to be true
    end

    it "checks database when party_aliases are not loaded" do
      create(:party_alias, party: party, alias_name: "Ali")
      unloaded_party = Party.find(party.id)

      expect(unloaded_party.party_aliases.loaded?).to be false
      expect(unloaded_party.alias_candidate?("Ali")).to be false
      expect(unloaded_party.alias_candidate?("Alice S.")).to be true
    end
  end

  describe "#accounting_user" do
    let(:user) { create(:user) }
    let(:party) { create(:party, user: user) }

    it "returns the user who owns the party" do
      expect(party.accounting_user).to eq(user)
    end
  end
end
