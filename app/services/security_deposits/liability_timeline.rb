module SecurityDeposits
  class LiabilityTimeline
    def self.validate(security_deposit:, additions: [], removing_ids: [])
      new(security_deposit: security_deposit, additions: additions, removing_ids: removing_ids).validate
    end

    def initialize(security_deposit:, additions: [], removing_ids: [])
      @security_deposit = security_deposit
      @additions = additions
      @removing_ids = if removing_ids.is_a?(Array)
                        removing_ids.compact.map(&:to_i)
      elsif removing_ids.present?
                        [ removing_ids.to_i ]
      else
                        []
      end
    end

    def validate
      date_deltas = {} # : Hash[Date, Integer]

      # 1. Load active posted transactions (excluding those marked for removal)
      existing_txns = security_deposit.transactions.active.posted
      existing_txns = existing_txns.where.not(id: removing_ids) if removing_ids.present?

      existing_txns.each do |txn|
        delta_int = txn.received? ? txn.amount_cents.to_i : -txn.amount_cents.to_i
        curr_cents = (date_deltas[txn.occurred_on] || 0).to_i
        date_deltas[txn.occurred_on] = (curr_cents + delta_int).to_i
      end

      # 2. Incorporate additions
      additions.each do |add|
        occ = add[:occurred_on]
        occ = Date.parse(occ.to_s) unless occ.is_a?(Date)
        curr_cents = (date_deltas[occ] || 0).to_i
        date_deltas[occ] = (curr_cents + add[:delta_cents].to_i).to_i
      end

      # 3. Walk timeline chronologically
      running_held_cents = 0
      sorted_dates = date_deltas.keys.sort

      sorted_dates.each do |date|
        running_held_cents += date_deltas[date]
        if running_held_cents < 0
          return ServiceResult.failure(
            error: "Transaction would result in negative security deposit liability (#{format_money(running_held_cents)}) as of #{date}",
            code: :negative_deposit_liability,
            data: { as_of: date, balance_cents: running_held_cents }
          )
        end
      end

      ServiceResult.success(final_balance_cents: running_held_cents)
    end

    private

      attr_reader :security_deposit, :additions, :removing_ids

      def format_money(cents)
        sprintf("$%.2f", cents.to_f / 100)
      end
  end
end
