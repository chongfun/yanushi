module Accounting
  class PostingSpec
    attr_reader :account_key, :amount_cents, :property, :rentable_unit, :tenancy, :party, :memo

    def initialize(account_key:, amount_cents:, property: nil, rentable_unit: nil, tenancy: nil, party: nil, memo: nil)
      @account_key = account_key.to_s
      @amount_cents = amount_cents
      @property = property
      @rentable_unit = rentable_unit
      @tenancy = tenancy
      @party = party
      @memo = memo
    end
  end
end
