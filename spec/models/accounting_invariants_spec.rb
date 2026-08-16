require "rails_helper"

RSpec.describe "Accounting Invariants", type: :model do
  let!(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:dummy_source) { create(:expense, property: property) }

  describe "double-entry balancing invariants" do
    it "requires sum(postings.amount_cents) == 0 across randomized multi-line entries" do
      account_keys = Accounting::ChartOfAccounts::SYSTEM_KEYS.sample(5)

      10.times do |i|
        # Generate 2 to 6 lines of random cents
        line_count = rand(2..6)
        amounts = Array.new(line_count - 1) { rand(-500_000..500_000) }.reject(&:zero?)
        balancing_amount = -amounts.sum

        # Ensure balancing line is non-zero
        if balancing_amount == 0
          amounts[0] += 100
          balancing_amount = -amounts.sum
        end

        all_amounts = amounts + [ balancing_amount ]

        specs = all_amounts.map do |cents|
          Accounting::PostingSpec.new(
            account_key: account_keys.sample,
            amount_cents: cents,
            tenancy: tenancy
          )
        end

        result = Accounting::PostEntryService.call(
          user: user,
          source: dummy_source,
          event_type: "invariant_test_#{i}",
          occurred_on: Date.current,
          postings: specs
        )

        expect(result).to be_success
        entry = result.value!.data[:journal_entry]
        expect(entry.postings.count).to be >= 2
        expect(entry.postings.sum(:amount_cents)).to eq(0)
      end
    end

    it "rejects any entry mutated by even 1 cent" do
      specs = [
        Accounting::PostingSpec.new(account_key: "tenant_receivable", amount_cents: 200_000, tenancy: tenancy),
        Accounting::PostingSpec.new(account_key: "rental_income", amount_cents: -200_001, tenancy: tenancy)
      ]

      result = Accounting::PostingBuilder.call(user: user, postings: specs)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:unbalanced_entry)
      expect(result.failure.error).to include("unbalanced: net sum is -1")
    end
  end
end
