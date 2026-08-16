module RentTerms
  class ChangeService
    def self.call(tenancy:, user: nil, amount_cents: nil, effective_from: nil, due_day: nil, frequency: nil, params: nil)
      p = (params || {}).to_h.symbolize_keys
      cents = amount_cents || p[:amount_cents]
      if cents.blank? && p[:amount].present?
        dollars = BigDecimal(p[:amount].to_s)
        cents = (dollars * 100).round
      end
      eff_from = effective_from || p[:effective_from]
      d_day = due_day || p[:due_day]
      freq = p[:frequency].presence || frequency.presence || "monthly"

      new(tenancy: tenancy, amount_cents: cents, effective_from: eff_from, due_day: d_day, frequency: freq).call
    end

    def initialize(tenancy:, amount_cents:, effective_from:, due_day: nil, frequency: "monthly")
      @tenancy = tenancy
      @amount_cents = amount_cents
      @effective_from = if effective_from.is_a?(String)
        Date.parse(effective_from) rescue nil
      else
        effective_from
      end
      @due_day = due_day
      @frequency = frequency || "monthly"
    end

    def call
      unless effective_from
        return ServiceResult.failure(
          data: nil,
          error: "Effective from date is required",
          code: :validation_error
        )
      end

      new_term = nil

      Tenancy.transaction do
        tenancy.reload
        tenancy.lock!

        if effective_from < tenancy.commencement_date
          return ServiceResult.failure(
            data: nil,
            error: "Effective from date cannot precede tenancy commencement date",
            code: :validation_error
          )
        end

        if tenancy.termination_date && effective_from > tenancy.termination_date
          return ServiceResult.failure(
            data: nil,
            error: "Effective from date cannot exceed tenancy termination date",
            code: :validation_error
          )
        end

        if effective_from != effective_from.beginning_of_month
          return ServiceResult.failure(
            data: nil,
            error: "Rent change effective date must be the first day of a month (proration is not supported)",
            code: :validation_error
          )
        end

        conflicting_charge = tenancy.charges.where(charge_kind: "rent").active.where("service_period_start >= ?", effective_from).order(:service_period_start).first
        if conflicting_charge
          period_str = conflicting_charge.service_period_start&.strftime("%B %Y") || conflicting_charge.charge_date.to_s
          return ServiceResult.failure(
            data: nil,
            error: "Rent for #{period_str} has already been charged. Void the affected rent charge before changing the rent term.",
            code: :conflict
          )
        end

        current_terms = tenancy.rent_terms.order(effective_from: :asc).lock
        previous_term = current_terms.find { |t| t.effective_until.nil? } || current_terms.last

        if previous_term
          if effective_from <= previous_term.effective_from
            return ServiceResult.failure(
              data: nil,
              error: "New rent term effective date must be after prior term start date (#{previous_term.effective_from})",
              code: :validation_error
            )
          end

          if previous_term.effective_until.nil? || previous_term.effective_until >= effective_from
            previous_term.update!(effective_until: effective_from - 1.day)
          end
        end

        resolved_due_day = due_day || previous_term&.due_day || 1

        new_term = tenancy.rent_terms.create!(
          amount_cents: amount_cents,
          effective_from: effective_from,
          effective_until: tenancy.termination_date,
          due_day: resolved_due_day,
          frequency: frequency
        )

        if effective_from <= Date.current
          gen_result = RentCharges::GenerateThroughService.call(tenancy: tenancy, through: Date.current)
          unless gen_result.success?
            raise ActiveRecord::RecordInvalid, new_term
          end
        end
      end

      ServiceResult.success({ rent_term: new_term })
    rescue ActiveRecord::RecordInvalid => e
      ServiceResult.failure(data: { rent_term: new_term }, error: e.record.errors.full_messages.to_sentence, code: :validation_error)
    end

    private

      attr_reader :tenancy, :amount_cents, :effective_from, :due_day, :frequency
  end
end
