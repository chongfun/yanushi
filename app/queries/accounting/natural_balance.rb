module Accounting
  class NaturalBalance
    DEBIT_TYPES = %w[asset expense].freeze
    CREDIT_TYPES = %w[liability equity income].freeze

    def self.multiplier_for(account_or_type)
      type = resolve_type(account_or_type)
      DEBIT_TYPES.include?(type) ? 1 : -1
    end

    def self.convert(account_or_type, raw_balance_cents)
      return 0 if raw_balance_cents.nil?

      raw_balance_cents * multiplier_for(account_or_type)
    end

    def self.to_raw(account_or_type, natural_balance_cents)
      return 0 if natural_balance_cents.nil?

      natural_balance_cents * multiplier_for(account_or_type)
    end

    def self.debit_normal?(account_or_type)
      multiplier_for(account_or_type) == 1
    end

    def self.credit_normal?(account_or_type)
      multiplier_for(account_or_type) == -1
    end

    private

      def self.resolve_type(account_or_type)
        if account_or_type.respond_to?(:account_type)
          account_or_type.account_type.to_s
        else
          account_or_type.to_s
        end
      end
  end
end
