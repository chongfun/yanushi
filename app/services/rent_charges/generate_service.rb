module RentCharges
  class GenerateService
    def self.call(tenancy:, service_month:)
      new(tenancy: tenancy, service_month: service_month).call
    end

    def initialize(tenancy:, service_month:)
      @tenancy = tenancy
      @service_month = parse_month(service_month)
    end

    def call
      unless tenancy && tenancy.persisted?
        return ServiceResult.failure(error: "Tenancy must be a persisted record", code: :invalid_input)
      end

      unless service_month
        return ServiceResult.failure(error: "Service month must be a valid date", code: :invalid_input)
      end

      month_start = service_month.beginning_of_month
      month_end = service_month.end_of_month

      tenancy.with_lock do
        target_date = [ month_start, tenancy.commencement_date ].compact.max
        term = tenancy.rent_terms.active(target_date).first
        return ServiceResult.success(nil) unless term

        service_period_start = [ month_start, tenancy.commencement_date, term.effective_from ].compact.max
        service_period_end = [ month_end, tenancy.termination_date || month_end, term.effective_until || month_end ].compact.min

        return ServiceResult.success(nil) if service_period_end < service_period_start

        term_due = term.due_date_for(service_month.year, service_month.month)
        due_on = [ term_due, service_period_start ].max
        charge_date = due_on
        amount_cents = term.amount_cents
        description = "Rent - #{service_month.strftime('%B %Y')}"

        existing_charge = tenancy.charges.where(
          charge_kind: "rent",
          service_period_start: service_period_start
        ).active.first

        if existing_charge
          if existing_charge.amount_cents == amount_cents &&
             existing_charge.due_on == due_on &&
             existing_charge.rent_term_id == term.id
            entry = existing_charge.journal_entries.find_by(event_type: "charge_posted")
            return ServiceResult.success(charge: existing_charge, journal_entry: entry)
          else
            return ServiceResult.failure(
              error: "Conflicting rent charge already exists for #{service_month.strftime('%B %Y')}",
              code: :conflict
            )
          end
        end

        Charges::CreateService.call(
          tenancy: tenancy,
          charge_kind: "rent",
          amount_cents: amount_cents,
          charge_date: charge_date,
          due_on: due_on,
          description: description,
          rent_term: term,
          service_period_start: service_period_start,
          service_period_end: service_period_end
        )
      end
    rescue ActiveRecord::RecordNotUnique
      existing_charge = tenancy.charges.where(
        charge_kind: "rent",
        service_period_start: [ month_start, tenancy.commencement_date ].compact.max
      ).active.first

      if existing_charge
        entry = existing_charge.journal_entries.find_by(event_type: "charge_posted")
        ServiceResult.success(charge: existing_charge, journal_entry: entry)
      else
        ServiceResult.failure(error: "Rent charge generation race occurred", code: :conflict)
      end
    end

    private

      attr_reader :tenancy, :service_month

      def parse_month(val)
        return nil if val.blank?
        return val.to_date.beginning_of_month if val.is_a?(Date) || val.is_a?(Time) || val.is_a?(DateTime)
        return nil unless val.to_s =~ /\d/

        Date.parse(val.to_s).beginning_of_month
      rescue ArgumentError, Date::Error
        nil
      end
  end
end
