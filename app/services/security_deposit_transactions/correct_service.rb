module SecurityDepositTransactions
  class CorrectService
    def self.call(
      transaction:,
      amount: :not_set,
      amount_cents: :not_set,
      occurred_on: :not_set,
      party: :not_set,
      party_id: :not_set,
      charge: :not_set,
      charge_id: :not_set,
      external_reference: :not_set,
      memo: :not_set
    )
      new(
        transaction: transaction,
        amount: amount,
        amount_cents: amount_cents,
        occurred_on: occurred_on,
        party: party,
        party_id: party_id,
        charge: charge,
        charge_id: charge_id,
        external_reference: external_reference,
        memo: memo
      ).call
    end

    def initialize(
      transaction:,
      amount: :not_set,
      amount_cents: :not_set,
      occurred_on: :not_set,
      party: :not_set,
      party_id: :not_set,
      charge: :not_set,
      charge_id: :not_set,
      external_reference: :not_set,
      memo: :not_set
    )
      @transaction = transaction
      @raw_amount = amount
      @raw_cents = amount_cents
      @raw_occurred_on = occurred_on
      @party = party
      @party_id = party_id
      @charge = charge
      @charge_id = charge_id
      @external_reference = external_reference
      @memo = memo
    end

    def call
      unless transaction.is_a?(SecurityDepositTransaction) && transaction.persisted? && !transaction.destroyed?
        return ServiceResult.failure(error: "Transaction must be a persisted SecurityDepositTransaction record", code: :invalid_source)
      end

      deposit = transaction.security_deposit
      unless deposit
        return ServiceResult.failure(error: "Security deposit not found", code: :not_found)
      end

      cents = if raw_cents == :not_set && raw_amount == :not_set
                transaction.amount_cents
      else
                resolve_cents
      end

      if cents.nil? || !cents.positive?
        return ServiceResult.failure(error: "Amount must be greater than zero", code: :invalid_input)
      end

      occ_date = if raw_occurred_on == :not_set
                   transaction.occurred_on
      else
                   resolve_occurred_on
      end

      unless occ_date
        return ServiceResult.failure(error: "Occurred on date is invalid", code: :invalid_date)
      end

      if occ_date > Date.current
        return ServiceResult.failure(error: "Occurred on date cannot be in the future", code: :invalid_date)
      end

      # Resolve party for received/refunded
      res_party = nil # : Party?
      if transaction.received? || transaction.refunded?
        if party == :not_set && party_id == :not_set
          res_party = transaction.party
        elsif party.is_a?(Party)
          res_party = party
        elsif party_id != :not_set && party_id.present?
          res_party = Party.find_by(id: party_id)
          unless res_party
            return ServiceResult.failure(error: "Party not found", code: :invalid_party)
          end
        else
          return ServiceResult.failure(error: "Party is required", code: :invalid_party)
        end

        if res_party && res_party.user_id != deposit.accounting_user&.id
          return ServiceResult.failure(error: "Party must belong to your account", code: :party_user_mismatch)
        end
      end

      # Resolve charge for applied
      res_charge = nil # : Charge?
      if transaction.applied?
        if charge == :not_set && charge_id == :not_set
          res_charge = transaction.charge
        elsif charge.is_a?(Charge)
          res_charge = charge
        elsif charge_id != :not_set && charge_id.present?
          res_charge = Charge.find_by(id: charge_id)
          unless res_charge
            return ServiceResult.failure(error: "Charge not found", code: :invalid_charge)
          end
        else
          return ServiceResult.failure(error: "Charge is required", code: :invalid_charge)
        end
      end

      res_memo = if memo == :not_set
                   transaction.memo
      elsif memo.present?
                   memo.to_s.strip
      else
                   nil
      end

      res_ext = if external_reference == :not_set
                  transaction.external_reference
      elsif external_reference.present?
                  external_reference.to_s.strip
      else
                  nil
      end

      failure_result = nil # : (Dry::Monads::Result::Success | Dry::Monads::Result::Failure)?
      success_result = nil # : (Dry::Monads::Result::Success | Dry::Monads::Result::Failure)?

      SecurityDeposit.transaction do
        # Enforce lock order: SecurityDeposit -> Charge(s) -> SecurityDepositTransaction
        deposit.lock!

        charges_to_lock = [ transaction.charge, res_charge ].compact.uniq.sort_by(&:id)
        charges_to_lock.each do |c|
          c.lock!
          c.reload
        end

        transaction.lock!
        transaction.reload

        # 1. Check if already superseded (Idempotency)
        if transaction.superseded?
          replacement = transaction.superseded_by
          reversal = transaction.journal_entries.find_by(event_type: "deposit_#{transaction.transaction_kind}")&.reversal

          if replacement &&
             replacement.amount_cents == cents &&
             replacement.occurred_on == occ_date &&
             replacement.party_id == res_party&.id &&
             replacement.charge_id == res_charge&.id &&
             replacement.memo.to_s.strip == res_memo.to_s.strip &&
             replacement.external_reference.to_s.strip == res_ext.to_s.strip
            success_result = ServiceResult.success(original: transaction, replacement: replacement, reversal: reversal)
          else
            failure_result = ServiceResult.failure(
              error: "Cannot correct an already superseded transaction with different parameters",
              code: :idempotency_conflict
            )
          end
          raise ActiveRecord::Rollback
        end

        if transaction.voided?
          failure_result = ServiceResult.failure(error: "Cannot correct a voided deposit transaction", code: :already_voided)
          raise ActiveRecord::Rollback
        end

        # 2. Kind-specific validations for replacement after locks acquired
        case transaction.transaction_kind
        when "received", "refunded"
          unless res_party
            failure_result = ServiceResult.failure(error: "Party is required", code: :invalid_party)
            raise ActiveRecord::Rollback
          end
        when "applied"
          unless res_charge
            failure_result = ServiceResult.failure(error: "Charge is required", code: :invalid_charge)
            raise ActiveRecord::Rollback
          end
          if res_charge.tenancy_id != deposit.tenancy_id
            failure_result = ServiceResult.failure(error: "Charge must belong to the same tenancy", code: :tenancy_mismatch)
            raise ActiveRecord::Rollback
          end
          unless res_charge.posted? && res_charge.active?
            failure_result = ServiceResult.failure(error: "Target charge is inactive or unposted", code: :invalid_charge_state)
            raise ActiveRecord::Rollback
          end

          if occ_date < res_charge.charge_date
            failure_result = ServiceResult.failure(
              error: "Application date (#{occ_date}) cannot precede the charge date (#{res_charge.charge_date})",
              code: :precedes_charge_date
            )
            raise ActiveRecord::Rollback
          end

          prior_apps_cents = res_charge.security_deposit_applications.active.where.not(id: transaction.id).sum(:amount_cents)
          remaining_cap = res_charge.amount_cents.to_i - prior_apps_cents.to_i
          if cents > remaining_cap
            failure_result = ServiceResult.failure(
              error: "Applied amount (#{format_money(cents)}) exceeds remaining capacity for this charge (#{format_money(remaining_cap)})",
              code: :exceeds_charge_capacity
            )
            raise ActiveRecord::Rollback
          end

          current_ar = deposit.tenancy.balance_cents(as_of: occ_date)
          effective_ar = current_ar + (occ_date >= transaction.occurred_on ? transaction.amount_cents : 0)
          if cents > effective_ar
            failure_result = ServiceResult.failure(
              error: "Applied amount (#{format_money(cents)}) exceeds tenancy outstanding balance (#{format_money(effective_ar)}) as of #{occ_date}",
              code: :exceeds_tenancy_balance
            )
            raise ActiveRecord::Rollback
          end
        end

        # 3. Timeline validation
        replacement_delta = transaction.received? ? cents : -cents
        timeline_res = SecurityDeposits::LiabilityTimeline.validate(
          security_deposit: deposit,
          removing_ids: [ transaction.id ],
          additions: [ { occurred_on: occ_date, delta_cents: replacement_delta } ]
        )
        unless timeline_res.success?
          failure_result = timeline_res
          raise ActiveRecord::Rollback
        end

        # 4. Reverse original entry
        entry_event = "deposit_#{transaction.transaction_kind}"
        journal_entry = transaction.journal_entries.find_by(event_type: entry_event)
        unless journal_entry
          failure_result = ServiceResult.failure(error: "Original journal entry not found", code: :not_found)
          raise ActiveRecord::Rollback
        end

        rev_res = Accounting::ReverseEntryService.call(
          journal_entry: journal_entry,
          occurred_on: transaction.occurred_on,
          description: "Correction of deposit transaction ##{transaction.id}"
        )
        unless rev_res.success?
          failure_result = rev_res
          raise ActiveRecord::Rollback
        end
        reversal = rev_res.value!.data[:journal_entry]

        # 5. Create replacement transaction
        replacement = SecurityDepositTransaction.new(
          security_deposit: deposit,
          transaction_kind: transaction.transaction_kind,
          amount_cents: cents,
          occurred_on: occ_date,
          party: (transaction.applied? ? nil : res_party),
          charge: (transaction.applied? ? res_charge : nil),
          external_reference: res_ext,
          memo: res_memo
        )

        unless replacement.save
          failure_result = ServiceResult.failure(error: replacement.errors.full_messages.join(", "), code: :validation_error)
          raise ActiveRecord::Rollback
        end

        post_res = post_replacement(replacement)
        unless post_res.success?
          failure_result = post_res
          raise ActiveRecord::Rollback
        end

        replacement.update_columns(posted_at: Time.current)
        transaction.update_columns(
          voided_at: Time.current,
          superseded_by_id: replacement.id
        )

        success_result = ServiceResult.success(original: transaction, replacement: replacement, reversal: reversal)
      end

      if (s = success_result)
        s
      elsif (f = failure_result)
        f
      else
        ServiceResult.failure(error: "Failed to correct deposit transaction", code: :correction_failed)
      end
    end

    private

      attr_reader :transaction, :raw_amount, :raw_cents, :raw_occurred_on, :party, :party_id, :charge, :charge_id, :external_reference, :memo

      def post_replacement(rep)
        case rep.transaction_kind
        when "received"
          postings = [
            Accounting::PostingSpec.new(account_key: "cash", amount_cents: rep.amount_cents, tenancy: rep.tenancy, party: rep.party),
            Accounting::PostingSpec.new(account_key: "security_deposits_held", amount_cents: -rep.amount_cents, tenancy: rep.tenancy, party: rep.party)
          ]
          Accounting::PostEntryService.call(
            source: rep,
            event_type: "deposit_received",
            occurred_on: rep.occurred_on,
            postings: postings,
            description: rep.memo.presence || "Security deposit received"
          )
        when "refunded"
          postings = [
            Accounting::PostingSpec.new(account_key: "security_deposits_held", amount_cents: rep.amount_cents, tenancy: rep.tenancy, party: rep.party),
            Accounting::PostingSpec.new(account_key: "cash", amount_cents: -rep.amount_cents, tenancy: rep.tenancy, party: rep.party)
          ]
          Accounting::PostEntryService.call(
            source: rep,
            event_type: "deposit_refunded",
            occurred_on: rep.occurred_on,
            postings: postings,
            description: rep.memo.presence || "Security deposit refund"
          )
        when "applied"
          postings = [
            Accounting::PostingSpec.new(account_key: "security_deposits_held", amount_cents: rep.amount_cents, tenancy: rep.tenancy),
            Accounting::PostingSpec.new(account_key: "tenant_receivable", amount_cents: -rep.amount_cents, tenancy: rep.tenancy)
          ]
          charge_desc = rep.charge&.description || rep.charge&.charge_kind&.titleize || "charge"
          Accounting::PostEntryService.call(
            source: rep,
            event_type: "deposit_applied",
            occurred_on: rep.occurred_on,
            postings: postings,
            description: rep.memo.presence || "Security deposit applied to #{charge_desc}"
          )
        else
          ServiceResult.failure(error: "Unknown transaction kind", code: :invalid_input)
        end
      end

      def resolve_cents
        if raw_cents != :not_set && raw_cents.present?
          return raw_cents if raw_cents.is_a?(Integer)

          nil
        elsif raw_amount != :not_set && raw_amount.present?
          str = raw_amount.is_a?(Numeric) ? raw_amount.to_s : raw_amount.to_s.strip
          return nil unless str.match?(/\A\d+(\.\d{1,2})?\z/)

          (BigDecimal(str) * 100).round
        else
          nil
        end
      end

      def resolve_occurred_on
        return raw_occurred_on if raw_occurred_on.is_a?(Date)
        return raw_occurred_on.to_date if raw_occurred_on.respond_to?(:to_date)
        return nil if raw_occurred_on.blank? || raw_occurred_on == :not_set

        Date.parse(raw_occurred_on.to_s)
      rescue ArgumentError, Date::Error
        nil
      end

      def format_money(cents)
        sprintf("$%.2f", cents.to_f / 100)
      end
  end
end
