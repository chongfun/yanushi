module SecurityDepositTransactions
  class RefundService
    def self.call(security_deposit:, party: nil, party_id: nil, amount: nil, amount_cents: nil, occurred_on: nil, external_reference: nil, memo: nil)
      new(
        security_deposit: security_deposit,
        party: party,
        party_id: party_id,
        amount: amount,
        amount_cents: amount_cents,
        occurred_on: occurred_on,
        external_reference: external_reference,
        memo: memo
      ).call
    end

    def initialize(security_deposit:, party: nil, party_id: nil, amount: nil, amount_cents: nil, occurred_on: nil, external_reference: nil, memo: nil)
      @security_deposit = security_deposit
      @party = party
      @party_id = party_id
      @raw_amount = amount
      @raw_cents = amount_cents
      @raw_occurred_on = occurred_on
      @external_reference = external_reference
      @memo = memo
    end

    def call
      unless security_deposit.is_a?(SecurityDeposit) && security_deposit.persisted? && !security_deposit.destroyed?
        return ServiceResult.failure(error: "Security deposit must be a persisted record", code: :invalid_deposit)
      end

      res_party = resolve_party
      unless res_party.is_a?(Party) && res_party.persisted? && !res_party.destroyed?
        return ServiceResult.failure(error: "Party must be a persisted record", code: :invalid_party)
      end

      if res_party.user_id != security_deposit.accounting_user&.id
        return ServiceResult.failure(error: "Party must belong to your account", code: :party_user_mismatch)
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

      security_deposit.with_lock do
        timeline_res = SecurityDeposits::LiabilityTimeline.validate(
          security_deposit: security_deposit,
          additions: [ { occurred_on: occ_date, delta_cents: -cents } ]
        )
        unless timeline_res.success?
          failure_res = timeline_res
          raise ActiveRecord::Rollback
        end

        txn = security_deposit.transactions.create!(
          transaction_kind: "refunded",
          party: res_party,
          amount_cents: cents,
          occurred_on: occ_date,
          external_reference: external_reference,
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
        ServiceResult.failure(error: "Failed to record deposit refund", code: :refund_failed)
      end
    end

    private

      attr_reader :security_deposit, :party, :party_id, :raw_amount, :raw_cents, :raw_occurred_on, :external_reference, :memo

      def post_transaction(txn)
        postings = [
          Accounting::PostingSpec.new(
            account_key: "security_deposits_held",
            amount_cents: txn.amount_cents,
            tenancy: txn.tenancy,
            party: txn.party
          ),
          Accounting::PostingSpec.new(
            account_key: "cash",
            amount_cents: -txn.amount_cents,
            tenancy: txn.tenancy,
            party: txn.party
          )
        ]

        Accounting::PostEntryService.call(
          source: txn,
          event_type: "deposit_refunded",
          occurred_on: txn.occurred_on,
          postings: postings,
          description: txn.memo.presence || "Security deposit refund"
        )
      end

      def resolve_party
        return party if party.is_a?(Party)
        return Party.find_by(id: party_id) if party_id.present?

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
  end
end
