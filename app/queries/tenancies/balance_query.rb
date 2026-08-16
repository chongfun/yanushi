module Tenancies
  class BalanceQuery
    def self.call(tenancy:, as_of: nil)
      new(tenancy: tenancy).balance_as_of(as_of || Date.current)
    end

    def initialize(tenancy:)
      @tenancy = tenancy
    end

    def balance_cents_as_of(as_of = Date.current)
      account = tenancy.accounting_user&.accounts&.find_by(key: "tenant_receivable")
      return 0 unless account

      tenancy.accounting_postings
             .joins(:journal_entry)
             .where(account_id: account.id)
             .where("journal_entries.occurred_on <= ?", as_of)
             .sum(:amount_cents)
    end

    def balance_as_of(as_of = Date.current)
      BigDecimal(balance_cents_as_of(as_of)) / 100
    end

    def current_balance
      balance_as_of(Date.current)
    end

    private

      attr_reader :tenancy
  end
end
