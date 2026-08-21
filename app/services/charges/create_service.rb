module Charges
  class CreateService
    def self.call(
      tenancy:,
      charge_kind:,
      amount_cents: nil,
      amount: nil,
      charge_date: nil,
      due_on: nil,
      description: nil,
      rent_term: nil,
      source_expense: nil,
      service_period_start: nil,
      service_period_end: nil
    )
      new(
        tenancy: tenancy,
        charge_kind: charge_kind,
        amount_cents: amount_cents,
        amount: amount,
        charge_date: charge_date,
        due_on: due_on,
        description: description,
        rent_term: rent_term,
        source_expense: source_expense,
        service_period_start: service_period_start,
        service_period_end: service_period_end
      ).call
    end

    def initialize(
      tenancy:,
      charge_kind:,
      amount_cents: nil,
      amount: nil,
      charge_date: nil,
      due_on: nil,
      description: nil,
      rent_term: nil,
      source_expense: nil,
      service_period_start: nil,
      service_period_end: nil
    )
      @tenancy = tenancy
      @charge_kind = charge_kind.to_s
      @amount_cents = amount_cents
      @amount = amount
      @charge_date = charge_date || Date.current
      @due_on = due_on || @charge_date
      @description = description
      @source_expense = source_expense
      @service_period_start = service_period_start
      @service_period_end = service_period_end

      if @charge_kind == "rent"
        period_start = @service_period_start || @charge_date.beginning_of_month
        @service_period_start = period_start
        @service_period_end ||= period_start.end_of_month
        @rent_term = rent_term || default_rent_term
      else
        @rent_term = rent_term
      end
    end

    def call
      resolved_cents = if amount_cents.present?
        amount_cents.to_i
      elsif amount.present?
        begin
          (BigDecimal(amount.to_s) * 100).round
        rescue StandardError
          0
        end
      else
        0
      end

      created_charge = nil # : Charge?
      created_entry = nil # : JournalEntry?
      failure_result = nil # : Dry::Monads::Result::Failure?

      Charge.transaction do
        charge = Charge.new(
          tenancy: tenancy,
          charge_kind: charge_kind,
          amount_cents: resolved_cents,
          charge_date: charge_date,
          due_on: due_on,
          description: description,
          rent_term: rent_term,
          source_expense: source_expense,
          service_period_start: service_period_start,
          service_period_end: service_period_end
        )

        unless charge.save
          failure_result = ServiceResult.failure(
            data: { charge: charge },
            error: charge.errors.full_messages.to_sentence,
            code: :validation_error
          )
          raise ActiveRecord::Rollback
        end

        post_result = Charges::PostService.call(charge: charge)
        unless post_result.success?
          failure_result = ServiceResult.failure(
            data: { charge: charge },
            error: post_result.failure.error,
            code: post_result.failure.code
          )
          raise ActiveRecord::Rollback
        end

        journal_entry = post_result.value!.data[:journal_entry]
        charge.update_columns(posted_at: journal_entry.posted_at)

        created_charge = charge
        created_entry = journal_entry
      end

      if (f = failure_result)
        f
      elsif created_charge && created_entry
        ServiceResult.success(charge: created_charge, journal_entry: created_entry)
      else
        ServiceResult.failure(error: "Failed to create and post charge", code: :creation_failed)
      end
    end

    private

      attr_reader :tenancy, :charge_kind, :amount_cents, :amount, :charge_date,
                  :due_on, :description, :rent_term, :source_expense,
                  :service_period_start, :service_period_end

      def default_rent_term
        return nil unless tenancy

        target_date = [ service_period_start, tenancy.commencement_date ].compact.max
        tenancy.rent_terms.active(target_date).first
      end
  end
end
