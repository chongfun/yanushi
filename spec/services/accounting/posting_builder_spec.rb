require "rails_helper"

RSpec.describe Accounting::PostingBuilder do
  let!(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }

  describe ".call" do
    it "successfully normalizes and balances a valid two-line entry" do
      specs = [
        Accounting::PostingSpec.new(account_key: "tenant_receivable", amount_cents: 200_000, tenancy: tenancy),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -200_000, tenancy: tenancy)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_success

      postings = result.value!.data[:postings]
      expect(postings.size).to eq(2)

      p1, p2 = postings
      expect(p1[:amount_cents]).to eq(200_000)
      expect(p1[:account_id]).to eq(user.accounts.find_by(key: "tenant_receivable").id)
      expect(p1[:property_id]).to eq(property.id)
      expect(p1[:rentable_unit_id]).to eq(unit.id)
      expect(p1[:tenancy_id]).to eq(tenancy.id)

      expect(p2[:amount_cents]).to eq(-200_000)
      expect(p2[:account_id]).to eq(user.accounts.find_by(key: "rental_income").id)
      expect(p2[:property_id]).to eq(property.id)
      expect(p2[:rentable_unit_id]).to eq(unit.id)
      expect(p2[:tenancy_id]).to eq(tenancy.id)
    end

    it "rejects entries with fewer than two lines" do
      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 0)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_postings)
      expect(result.failure.error).to include("at least two postings")
    end

    it "rejects zero or non-integer amounts" do
      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 0),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: 0)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_postings)
      expect(result.failure.error).to include("non-zero integer")
    end

    it "rejects unbalanced entries" do
      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 200_000),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -199_999)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:unbalanced_entry)
      expect(result.failure.error).to include("unbalanced")
    end

    it "rejects unknown account keys" do
      specs = [
        Accounting::PostingSpec.new(account_key: "non_existent_key", amount_cents: 10_000),
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: -10_000)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:missing_account)
      expect(result.failure.error).to include("Account 'non_existent_key' not found")
    end

    it "rejects inactive accounts" do
      cash_account = user.accounts.find_by(key: "cash")
      cash_account.update!(active: false)

      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 10_000),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -10_000)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:inactive_account)
      expect(result.failure.error).to include("Account 'cash' is inactive")
    end

    it "derives property from rentable_unit when tenancy is not specified" do
      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, rentable_unit: unit),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000, rentable_unit: unit)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_success
      postings = result.value!.data[:postings]
      expect(postings.first[:property_id]).to eq(property.id)
      expect(postings.first[:rentable_unit_id]).to eq(unit.id)
      expect(postings.first[:tenancy_id]).to be_nil
    end

    it "rejects contradictory unit and property dimensions" do
      other_property = create(:property, user: user)
      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, property: other_property, rentable_unit: unit),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:dimension_mismatch)
      expect(result.failure.error).to include("rentable unit does not belong to specified property")
    end

    it "rejects contradictory tenancy and unit dimensions" do
      other_unit = create(:rentable_unit, property: property, name: "Other Unit")
      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, tenancy: tenancy, rentable_unit: other_unit),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:dimension_mismatch)
      expect(result.failure.error).to include("tenancy does not belong to specified rentable unit")
    end

    it "rejects contradictory tenancy and property dimensions" do
      other_property = create(:property, user: user)
      specs = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, tenancy: tenancy, property: other_property),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]

      result = described_class.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:dimension_mismatch)
      expect(result.failure.error).to include("tenancy does not belong to specified property")
    end

    it "rejects cross-user dimensions for property, unit, tenancy, and party" do
      other_user = create(:user)
      other_property = create(:property, user: other_user)
      other_unit = create(:rentable_unit, property: other_property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_party = create(:party, user: other_user)

      specs_prop = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, property: other_property),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]
      expect(described_class.call(user: user, postings: specs_prop).failure.code).to eq(:ownership_mismatch)

      specs_unit = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, rentable_unit: other_unit),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]
      expect(described_class.call(user: user, postings: specs_unit).failure.code).to eq(:ownership_mismatch)

      specs_tenancy = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, tenancy: other_tenancy),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]
      expect(described_class.call(user: user, postings: specs_tenancy).failure.code).to eq(:ownership_mismatch)

      specs_party = [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, party: other_party),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]
      expect(described_class.call(user: user, postings: specs_party).failure.code).to eq(:ownership_mismatch)
    end

    it "rejects unpersisted dimensions" do
      unsaved_property = build(:property, user: user)
      unsaved_unit = build(:rentable_unit, property: property)
      unsaved_tenancy = build(:tenancy, rentable_unit: unit)
      unsaved_party = build(:party, user: user)

      expect(described_class.call(user: user, postings: [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, property: unsaved_property),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]).failure.code).to eq(:invalid_dimension)

      expect(described_class.call(user: user, postings: [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, rentable_unit: unsaved_unit),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]).failure.code).to eq(:invalid_dimension)

      expect(described_class.call(user: user, postings: [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, tenancy: unsaved_tenancy),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]).failure.code).to eq(:invalid_dimension)

      expect(described_class.call(user: user, postings: [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, party: unsaved_party),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ]).failure.code).to eq(:invalid_dimension)
    end

    it "rejects destroyed dimensions" do
      temp_party = create(:party, user: user)
      temp_party.destroy

      result = described_class.call(user: user, postings: [
        Accounting::PostingSpec.new(account_key: "cash", amount_cents: 50_000, party: temp_party),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -50_000)
      ])

      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_dimension)
    end
  end
end
