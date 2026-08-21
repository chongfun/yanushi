module Accounting
  class PropertySummaryQuery
    class SummaryResult < Data.define(
      :property,
      :date_range,
      :net_cash_movement_cents,
      :income_recognized_cents,
      :operating_expenses_cents,
      :net_operating_income_cents,
      :tenant_receivable_change_cents,
      :security_deposit_liability_change_cents,
      :tenant_receivable_cents,
      :security_deposits_held_cents,
      :expenses_by_account,
      :income_by_account
    )
      def net_cash_movement
        BigDecimal(net_cash_movement_cents.to_s) / 100
      end

      def income_recognized
        BigDecimal(income_recognized_cents.to_s) / 100
      end

      def operating_expenses
        BigDecimal(operating_expenses_cents.to_s) / 100
      end

      def net_operating_income
        BigDecimal(net_operating_income_cents.to_s) / 100
      end

      def tenant_receivable
        BigDecimal(tenant_receivable_cents.to_s) / 100
      end

      def security_deposits_held
        BigDecimal(security_deposits_held_cents.to_s) / 100
      end
    end

    def self.call(property:, from: nil, through: nil, year: nil, date_range: nil)
      new(
        property: property,
        from: from,
        through: through,
        year: year,
        date_range: date_range
      ).call
    end

    def initialize(property:, from: nil, through: nil, year: nil, date_range: nil)
      @property = property
      @date_range = date_range || DateRange.parse(from: from, through: through, year: year)
    end

    def call
      return empty_summary unless property && date_range.valid?

      period_postings = scoped_period_postings.includes(:account)

      net_cash_movement_cents = 0
      income_recognized_cents = 0
      operating_expenses_cents = 0
      tenant_receivable_change_cents = 0
      security_deposit_liability_change_cents = 0

      expenses_by_acc = Hash.new(0) # : Hash[String, Integer]
      income_by_acc = Hash.new(0) # : Hash[String, Integer]

      period_postings.each do |p|
        acc = p.account
        next unless acc

        case acc.account_type
        when "asset"
          if acc.key == "cash"
            net_cash_movement_cents += p.amount_cents.to_i
          elsif acc.key == "tenant_receivable"
            tenant_receivable_change_cents += p.amount_cents.to_i
          end
        when "liability"
          if acc.key == "security_deposits_held"
            # Liability credit is negative raw cents, so positive liability increase is -amount_cents
            security_deposit_liability_change_cents += -p.amount_cents.to_i
          end
        when "expense"
          amt = p.amount_cents.to_i
          operating_expenses_cents += amt
          acc_key = acc.key.to_s
          expenses_by_acc[acc_key] = ((expenses_by_acc[acc_key] || 0) + amt).to_i
        when "income"
          amt = -p.amount_cents.to_i
          income_recognized_cents += amt
          acc_key = acc.key.to_s
          income_by_acc[acc_key] = ((income_by_acc[acc_key] || 0) + amt).to_i
        end
      end

      net_operating_income_cents = income_recognized_cents - operating_expenses_cents

      as_of_date = date_range.as_of
      user = property.user

      tenant_receivable_account = user.accounts.find_by(key: "tenant_receivable")
      tenant_receivable_cents = AccountBalanceQuery.new(
        account: tenant_receivable_account,
        as_of: as_of_date,
        property: property
      ).natural_balance_cents

      security_deposits_account = user.accounts.find_by(key: "security_deposits_held")
      security_deposits_held_cents = AccountBalanceQuery.new(
        account: security_deposits_account,
        as_of: as_of_date,
        property: property
      ).natural_balance_cents

      SummaryResult.new(
        property: property,
        date_range: date_range,
        net_cash_movement_cents: net_cash_movement_cents,
        income_recognized_cents: income_recognized_cents,
        operating_expenses_cents: operating_expenses_cents,
        net_operating_income_cents: net_operating_income_cents,
        tenant_receivable_change_cents: tenant_receivable_change_cents,
        security_deposit_liability_change_cents: security_deposit_liability_change_cents,
        tenant_receivable_cents: tenant_receivable_cents,
        security_deposits_held_cents: security_deposits_held_cents,
        expenses_by_account: expenses_by_acc,
        income_by_account: income_by_acc
      )
    end

    private

      attr_reader :property, :date_range

      def scoped_period_postings
        prop = property
        return Posting.none unless prop

        scope = prop.postings.joins(:journal_entry)
        if date_range.from && date_range.through
          scope = scope.where("journal_entries.occurred_on BETWEEN ? AND ?", date_range.from, date_range.through)
        elsif date_range.from
          scope = scope.where("journal_entries.occurred_on >= ?", date_range.from)
        elsif date_range.through
          scope = scope.where("journal_entries.occurred_on <= ?", date_range.through)
        end
        scope
      end

      def empty_summary
        SummaryResult.new(
          property: property,
          date_range: date_range,
          net_cash_movement_cents: 0,
          income_recognized_cents: 0,
          operating_expenses_cents: 0,
          net_operating_income_cents: 0,
          tenant_receivable_change_cents: 0,
          security_deposit_liability_change_cents: 0,
          tenant_receivable_cents: 0,
          security_deposits_held_cents: 0,
          expenses_by_account: {},
          income_by_account: {}
        )
      end
  end
end
