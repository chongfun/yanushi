require "rails_helper"

RSpec.describe ImportedTransactions::PartyResolver do
  let(:resolver) { described_class.new }
  let(:user) { create(:user) }

  describe "#resolve" do
    it "returns unmatched if both display_name and username are blank" do
      result = resolver.resolve(user, nil, nil)
      expect(result).to be_failure
      expect(result.failure.status).to eq(:unmatched)
      expect(result.failure.party).to be_nil
    end

    it "resolves correctly when display_name is matched" do
      party = create(:party, user: user, display_name: "Alice Walker")

      result = resolver.resolve(user, "Alice Walker", nil)
      expect(result).to be_success
      expect(result.value!.status).to eq(:matched)
      expect(result.value!.party).to eq(party)
    end

    it "resolves correctly when display_name is blank but username is present" do
      party = create(:party, user: user, display_name: "Jane Smith")
      create(:party_alias, party: party, alias_name: "@janesmith")

      result = resolver.resolve(user, "", "@janesmith")
      expect(result).to be_success
      expect(result.value!.status).to eq(:matched)
      expect(result.value!.party).to eq(party)
    end

    it "returns ambiguous when multiple parties match" do
      p1 = create(:party, user: user, display_name: "John Doe")
      p2 = create(:party, user: user, display_name: "Johnny Doe")
      create(:party_alias, party: p2, alias_name: "John Doe")

      result = resolver.resolve(user, "John Doe", nil)
      expect(result).to be_failure
      expect(result.failure.status).to eq(:ambiguous)
      expect(result.failure.parties).to contain_exactly(p1, p2)
    end

    it "returns empty candidates when names are blank strings in find_candidates" do
      expect(resolver.send(:find_candidates, user, "   ", nil)).to eq([])
    end
  end
end
