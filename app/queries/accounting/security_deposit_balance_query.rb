module Accounting
  class SecurityDepositBalanceQuery
    def self.call(tenancy: nil, property: nil, user: nil, as_of: nil)
      new(tenancy: tenancy, property: property, user: user).balance_cents_as_of(as_of || Date.current)
    end

    def initialize(tenancy: nil, property: nil, user: nil)
      @tenancy = tenancy
      @property = property || tenancy&.property
      @user = user || tenancy&.accounting_user || @property&.user
    end

    def balance_cents_as_of(as_of = Date.current)
      return 0 unless user

      account = user.accounts.find_by(key: "security_deposits_held")
      return 0 unless account

      scope = account.postings
                     .joins(:journal_entry)
                     .where("journal_entries.occurred_on <= ?", as_of)

      if tenancy
        scope = scope.where(tenancy_id: tenancy.id)
      elsif property
        scope = scope.where(property_id: property.id)
      end

      # Liability postings have negative amounts for credits (deposit held).
      # Inverting sign gives positive amount for held deposit.
      -scope.sum(:amount_cents)
    end

    def balance_as_of(as_of = Date.current)
      BigDecimal(balance_cents_as_of(as_of)) / 100
    end

    private

      attr_reader :tenancy, :property, :user
  end
end
