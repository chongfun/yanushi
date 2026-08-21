module SecurityDepositTransactions
  class ApplyService
    def self.call(security_deposit:, charge: nil, charge_id: nil, amount: nil, amount_cents: nil, occurred_on: nil, memo: nil)
      new(
        security_deposit: security_deposit,
        charge: charge,
        charge_id: charge_id,
        amount: amount,
        amount_cents: amount_cents,
        occurred_on: occurred_on,
        memo: memo
      ).call
    end

    def initialize(security_deposit:, charge: nil, charge_id: nil, amount: nil, amount_cents: nil, occurred_on: nil, memo: nil)
      @security_deposit = security_deposit
      @charge = charge
      @charge_id = charge_id
      @raw_amount = amount
      @raw_cents = amount_cents
      @raw_occurred_on = occurred_on
      @memo = memo
    end

    def call
      unless security_deposit.is_a?(SecurityDeposit) && security_deposit.persisted? && !security_deposit.destroyed?
        return ServiceResult.failure(error: "Security deposit must be a persisted record", code: :invalid_deposit)
      end

      res_charge = resolve_charge
      unless res_charge.is_a?(Charge) && res_charge.persisted? && !res_charge.destroyed?
        return ServiceResult.failure(error: "Charge must be a persisted record", code: :invalid_charge)
      end

      if res_charge.tenancy_id != security_deposit.tenancy_id
        return ServiceResult.failure(error: "Charge must belong to the same tenancy as the security deposit", code: :tenancy_mismatch)
      end

      cents = resolve_cents
      if cents.nil? || !cents.positive?
        return ServiceResult.failure(error: "Amount must be greater than zero", code: :invalid_input)
      end

      if raw_occurred_on.blank?
        return ServiceResult.failure(error: "Occurred on date is required", code: :invalid_input)
      end

      occ_date = resolve_occurred_on
      unless occ_date
        return ServiceResult.failure(error: "Invalid occurred on date", code: :invalid_input)
      end

      if occ_date > Date.current
        return ServiceResult.failure(error: "Occurred on date cannot be in the future", code: :invalid_date)
      end

      created_txn = nil # : SecurityDepositTransaction?
      journal_entry = nil # : JournalEntry?
      failure_res = nil # : (Dry::Monads::Result::Success | Dry::Monads::Result::Failure)?

      SecurityDeposit.transaction do
        # Enforce lock order: SecurityDeposit -> Charge
        security_deposit.lock!
        res_charge.lock!

        unless res_charge.posted? && res_charge.active?
          failure_res = ServiceResult.failure(error: "Cannot apply deposit to an inactive or unposted charge", code: :invalid_charge_state)
          raise ActiveRecord::Rollback
        end

        if occ_date < res_charge.charge_date
          failure_res = ServiceResult.failure(
            error: "Application date (#{occ_date}) cannot precede the charge date (#{res_charge.charge_date})",
            code: :precedes_charge_date
          )
          raise ActiveRecord::Rollback
        end

        remaining_charge_cap = res_charge.remaining_deposit_application_cents
        if cents > remaining_charge_cap
          failure_res = ServiceResult.failure(
            error: "Applied amount (#{format_money(cents)}) exceeds charge remaining capacity (#{format_money(remaining_charge_cap)})",
            code: :exceeds_charge_capacity
          )
          raise ActiveRecord::Rollback
        end

        outstanding_balance = security_deposit.tenancy.balance_cents(as_of: occ_date)
        if cents > outstanding_balance
          failure_res = ServiceResult.failure(
            error: "Applied amount (#{format_money(cents)}) exceeds tenancy outstanding balance (#{format_money(outstanding_balance)}) as of #{occ_date}",
            code: :exceeds_tenancy_balance
          )
          raise ActiveRecord::Rollback
        end

        timeline_res = SecurityDeposits::LiabilityTimeline.validate(
          security_deposit: security_deposit,
          additions: [ { occurred_on: occ_date, delta_cents: -cents } ]
        )
        unless timeline_res.success?
          failure_res = timeline_res
          raise ActiveRecord::Rollback
        end

        txn = security_deposit.transactions.create!(
          transaction_kind: "applied",
          charge: res_charge,
          amount_cents: cents,
          occurred_on: occ_date,
          memo: memo
        )

        post_res = post_transaction(txn)
        unless post_res.success?
          failure_res = post_res
          raise ActiveRecord::Rollback
        end

        txn.update_columns(posted_at: Time.current)
        created_txn = txn
        journal_entry = post_res.value!.data[:journal_entry]
      end

      if (f = failure_res)
        f
      elsif (t = created_txn)
        ServiceResult.success(transaction: t, journal_entry: journal_entry)
      else
        ServiceResult.failure(error: "Failed to apply security deposit", code: :application_failed)
      end
    end

    private

      attr_reader :security_deposit, :charge, :charge_id, :raw_amount, :raw_cents, :raw_occurred_on, :memo

      def post_transaction(txn)
        postings = [
          Accounting::PostingSpec.new(
            account_key: "security_deposits_held",
            amount_cents: txn.amount_cents,
            tenancy: txn.tenancy
          ),
          Accounting::PostingSpec.new(
            account_key: "tenant_receivable",
            amount_cents: -txn.amount_cents,
            tenancy: txn.tenancy
          )
        ]

        charge_desc = txn.charge&.description || txn.charge&.charge_kind&.titleize || "charge"
        default_desc = "Security deposit applied to #{charge_desc}"

        Accounting::PostEntryService.call(
          source: txn,
          event_type: "deposit_applied",
          occurred_on: txn.occurred_on,
          postings: postings,
          description: txn.memo.presence || default_desc
        )
      end

      def resolve_charge
        return charge if charge.is_a?(Charge)
        return Charge.find_by(id: charge_id) if charge_id.present?

        nil
      end

      def resolve_cents
        if raw_cents.present?
          return raw_cents if raw_cents.is_a?(Integer)

          nil
        elsif raw_amount.present?
          str = raw_amount.is_a?(Numeric) ? raw_amount.to_s : raw_amount.to_s.strip
          return nil unless str.match?(/\A\d+(\.\d{1,2})?\z/)

          (BigDecimal(str) * 100).round
        else
          nil
        end
      end

      def resolve_occurred_on
        return nil if raw_occurred_on.blank?
        return raw_occurred_on if raw_occurred_on.is_a?(Date)
        return raw_occurred_on.to_date if raw_occurred_on.respond_to?(:to_date)

        Date.parse(raw_occurred_on.to_s)
      rescue ArgumentError, Date::Error
        nil
      end

      def format_money(cents)
        sprintf("$%.2f", cents.to_f / 100)
      end
  end
end
