module Accounting
  class TenancyBalanceQuery
    def self.call(tenancy:, as_of: nil)
      new(tenancy: tenancy).balance_as_of(as_of || Date.current)
    end

    def self.balance_cents_as_of(tenancy:, as_of: nil)
      new(tenancy: tenancy).balance_cents_as_of(as_of || Date.current)
    end

    def initialize(tenancy:)
      @tenancy = tenancy
    end

    def balance_cents_as_of(as_of = Date.current)
      return 0 unless tenancy

      account = tenancy.accounting_user&.accounts&.find_by(key: "tenant_receivable")
      return 0 unless account

      AccountBalanceQuery.call(
        account: account,
        as_of: as_of,
        tenancy: tenancy
      )
    end

    def balance_as_of(as_of = Date.current)
      BigDecimal(balance_cents_as_of(as_of).to_s) / 100
    end

    def current_balance
      balance_as_of(Date.current)
    end

    def current_balance_cents
      balance_cents_as_of(Date.current)
    end

    private

      attr_reader :tenancy
  end
end
