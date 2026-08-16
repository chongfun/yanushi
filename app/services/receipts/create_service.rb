module Receipts
  class CreateService
    def self.call(
      tenancy:,
      payer_party:,
      received_on:,
      payment_method:,
      amount_cents: nil,
      amount: nil,
      external_reference: nil,
      memo: nil
    )
      new(
        tenancy: tenancy,
        payer_party: payer_party,
        received_on: received_on,
        payment_method: payment_method,
        amount_cents: amount_cents,
        amount: amount,
        external_reference: external_reference,
        memo: memo
      ).call
    end

    def initialize(
      tenancy:,
      payer_party:,
      received_on:,
      payment_method:,
      amount_cents: nil,
      amount: nil,
      external_reference: nil,
      memo: nil
    )
      @tenancy = tenancy
      @payer_party = payer_party
      @amount_cents = amount_cents
      @amount = amount
      @raw_received_on = received_on
      @received_on = parse_date(received_on)
      @payment_method = payment_method.to_s.strip.downcase.presence
      @external_reference = external_reference.to_s.strip.presence
      @memo = memo.to_s.strip.presence
    end

    def call
      unless tenancy && tenancy.is_a?(Tenancy) && tenancy.persisted? && !tenancy.destroyed?
        return ServiceResult.failure(error: "Tenancy is required", code: :invalid_input)
      end

      unless payer_party && payer_party.is_a?(Party) && payer_party.persisted? && !payer_party.destroyed?
        return ServiceResult.failure(error: "Payer party is required", code: :invalid_input)
      end

      if raw_received_on.blank?
        return ServiceResult.failure(error: "Received on date is required", code: :invalid_input)
      end

      unless received_on
        return ServiceResult.failure(error: "Received on must be a valid date", code: :invalid_input)
      end

      if payment_method.blank?
        return ServiceResult.failure(error: "Payment method is required", code: :invalid_input)
      end

      resolved_cents, parse_error = resolve_amount_cents
      if parse_error
        return ServiceResult.failure(error: parse_error, code: :invalid_amount)
      end

      if resolved_cents <= 0
        return ServiceResult.failure(error: "Amount must be greater than 0", code: :invalid_amount)
      end

      created_receipt = nil # : Receipt?
      created_entry = nil # : JournalEntry?
      failure_result = nil # : Dry::Monads::Result::Failure?

      begin
        Receipt.transaction do
          receipt = Receipt.new(
            tenancy: tenancy,
            user: tenancy.accounting_user,
            payer_party: payer_party,
            amount_cents: resolved_cents,
            received_on: received_on,
            payment_method: payment_method,
            external_reference: external_reference,
            memo: memo
          )

          unless receipt.save
            failure_result = ServiceResult.failure(
              data: { receipt: receipt },
              error: receipt.errors.full_messages.to_sentence,
              code: :validation_error
            )
            raise ActiveRecord::Rollback
          end

          post_result = Receipts::PostService.call(receipt: receipt)
          unless post_result.success?
            failure_result = ServiceResult.failure(
              data: { receipt: receipt },
              error: post_result.failure.error,
              code: post_result.failure.code
            )
            raise ActiveRecord::Rollback
          end

          journal_entry = post_result.value!.data[:journal_entry]
          receipt.update_columns(posted_at: journal_entry.posted_at)

          created_receipt = receipt
          created_entry = journal_entry
        end
      rescue ActiveRecord::RecordNotUnique
        return ServiceResult.failure(
          error: "A payment with this payment method and reference already exists",
          code: :duplicate
        )
      end

      if (f = failure_result)
        f
      elsif created_receipt && created_entry
        ServiceResult.success(receipt: created_receipt, journal_entry: created_entry)
      else
        ServiceResult.failure(error: "Failed to create and post receipt", code: :creation_failed)
      end
    end

    private

      attr_reader :tenancy, :payer_party, :amount_cents, :amount, :raw_received_on,
                  :received_on, :payment_method, :external_reference, :memo

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
          [ 0, "Amount is required" ]
        end
      end
  end
end
