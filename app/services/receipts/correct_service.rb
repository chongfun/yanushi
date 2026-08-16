module Receipts
  class CorrectService
    def self.call(
      receipt:,
      tenancy: nil,
      payer_party: nil,
      amount_cents: nil,
      amount: nil,
      received_on: nil,
      payment_method: nil,
      external_reference: nil,
      memo: nil
    )
      new(
        receipt: receipt,
        tenancy: tenancy,
        payer_party: payer_party,
        amount_cents: amount_cents,
        amount: amount,
        received_on: received_on,
        payment_method: payment_method,
        external_reference: external_reference,
        memo: memo
      ).call
    end

    def initialize(
      receipt:,
      tenancy: nil,
      payer_party: nil,
      amount_cents: nil,
      amount: nil,
      received_on: nil,
      payment_method: nil,
      external_reference: nil,
      memo: nil
    )
      @receipt = receipt
      @tenancy = tenancy
      @payer_party = payer_party
      @amount_cents = amount_cents
      @amount = amount
      @raw_received_on = received_on
      @received_on = parse_date(received_on)
      @payment_method = payment_method
      @external_reference = external_reference
      @memo = memo
    end

    def call
      unless receipt.is_a?(Receipt) && receipt.persisted? && !receipt.destroyed?
        return ServiceResult.failure(error: "Receipt must be a persisted Receipt record", code: :invalid_source)
      end

      journal_entry = receipt.journal_entries.find_by(event_type: "receipt_posted")
      unless journal_entry
        return ServiceResult.failure(error: "Journal entry not found for receipt", code: :not_found)
      end

      if raw_received_on.present? && received_on.nil?
        return ServiceResult.failure(error: "Received on must be a valid date", code: :invalid_input)
      end

      target_tenancy = tenancy || receipt.tenancy
      target_payer = payer_party || receipt.payer_party

      owner = receipt.user
      unless target_tenancy&.accounting_user == owner
        return ServiceResult.failure(
          error: "Cannot move receipt to another user's tenancy",
          code: :ownership_mismatch
        )
      end

      unless target_payer&.user == owner
        return ServiceResult.failure(
          error: "Cannot assign payer belonging to another user",
          code: :ownership_mismatch
        )
      end

      target_received_on = received_on || receipt.received_on
      target_method = payment_method.to_s.strip.downcase.presence || receipt.payment_method
      target_external_ref = external_reference.nil? ? receipt.external_reference : external_reference.to_s.strip.presence
      target_memo = memo.nil? ? receipt.memo : memo.to_s.strip.presence

      resolved_cents, parse_error = resolve_amount_cents
      if parse_error
        return ServiceResult.failure(error: parse_error, code: :invalid_amount)
      end

      replacement_receipt = nil # : Receipt?
      failure_result = nil # : Dry::Monads::Result::Failure?

      Receipt.transaction do
        receipt.lock!

        if receipt.superseded?
          existing_rep = receipt.superseded_by
          if existing_rep && identical_replacement?(existing_rep, target_tenancy, target_payer, resolved_cents, target_received_on, target_method, target_external_ref, target_memo)
            return ServiceResult.success(receipt: existing_rep, original_receipt: receipt)
          else
            failure_result = ServiceResult.failure(
              error: "Cannot correct an already superseded receipt",
              code: :already_superseded
            )
            raise ActiveRecord::Rollback
          end
        end

        if receipt.voided?
          failure_result = ServiceResult.failure(
            error: "Cannot correct a voided receipt",
            code: :already_voided
          )
          raise ActiveRecord::Rollback
        end

        reverse_result = Accounting::ReverseEntryService.call(
          journal_entry: journal_entry,
          occurred_on: receipt.received_on,
          description: "Corrected by replacement receipt"
        )

        unless reverse_result.success?
          failure_result = reverse_result
          raise ActiveRecord::Rollback
        end

        receipt.update_columns(voided_at: Time.current)

        create_result = Receipts::CreateService.call(
          tenancy: target_tenancy,
          payer_party: target_payer,
          amount_cents: resolved_cents,
          received_on: target_received_on,
          payment_method: target_method,
          external_reference: target_external_ref,
          memo: target_memo
        )

        unless create_result.success?
          failure_result = create_result
          raise ActiveRecord::Rollback
        end

        created = create_result.value!.data[:receipt]
        receipt.update_columns(superseded_by_id: created.id)
        replacement_receipt = created
      end

      if (f = failure_result)
        f
      elsif replacement_receipt
        ServiceResult.success(receipt: replacement_receipt, original_receipt: receipt)
      else
        ServiceResult.failure(error: "Failed to correct receipt", code: :correction_failed)
      end
    end

    private

      attr_reader :receipt, :tenancy, :payer_party, :amount_cents, :amount,
                  :raw_received_on, :received_on, :payment_method, :external_reference, :memo

      def parse_date(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s)
      rescue ArgumentError, Date::Error
        nil
      end

      def resolve_amount_cents
        if amount_cents.present?
          [ amount_cents.to_i, nil ]
        elsif amount.present?
          val_str = amount.is_a?(Numeric) ? amount.to_s : amount.to_s.strip
          unless val_str =~ /\A-?\d+(\.\d+)?\z/
            return [ 0, "Amount is not a valid number" ]
          end

          if val_str.include?(".")
            decimals = val_str.split(".").last
            if decimals.length > 2 && decimals[2..].to_i != 0
              return [ 0, "Amount cannot have fractional cents" ]
            end
          end

          [ (BigDecimal(val_str) * 100).round, nil ]
        else
          [ receipt.amount_cents, nil ]
        end
      end

      def identical_replacement?(rep, t_tenancy, t_payer, t_cents, t_date, t_method, t_ref, t_memo)
        rep.tenancy_id == t_tenancy.id &&
          rep.payer_party_id == t_payer.id &&
          rep.amount_cents == t_cents &&
          rep.received_on == t_date &&
          rep.payment_method.to_s.strip.downcase == t_method.to_s.strip.downcase &&
          rep.external_reference.to_s.strip.presence == t_ref.to_s.strip.presence &&
          rep.memo.to_s.strip.presence == t_memo.to_s.strip.presence
      end
  end
end
