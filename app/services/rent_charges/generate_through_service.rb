module RentCharges
  class GenerateThroughService
    def self.call(tenancy:, through: nil)
      new(tenancy: tenancy, through: through).call
    end

    def initialize(tenancy:, through: nil)
      @tenancy = tenancy
      @through = parse_date(through) || Date.current
    end

    def call
      unless tenancy && tenancy.persisted?
        return ServiceResult.failure(error: "Tenancy must be a persisted record", code: :invalid_input)
      end

      starts_on = tenancy.commencement_date
      empty_charges = [] # : Array[Charge]
      return ServiceResult.success(charges: empty_charges) if starts_on.nil? || starts_on > through

      current_month = starts_on.beginning_of_month
      end_month = through.beginning_of_month
      generated_charges = [] # : Array[Charge]

      while current_month <= end_month
        # Check if due date for current month is <= through
        target_date = [ current_month, starts_on ].compact.max
        term = tenancy.rent_terms.active(target_date).first

        if term
          term_due = term.due_date_for(current_month.year, current_month.month)
          service_period_start = [ current_month, starts_on, term.effective_from ].compact.max
          due_on = [ term_due, service_period_start ].max

          if due_on <= through
            result = RentCharges::GenerateService.call(
              tenancy: tenancy,
              service_month: current_month
            )

            if result.success?
              data = result.value!
              generated_charges << data.data[:charge] if data && data.data && data.data[:charge]
            else
              return result
            end
          end
        end

        current_month = current_month.next_month.beginning_of_month
      end

      ServiceResult.success(charges: generated_charges)
    end

    private

      attr_reader :tenancy, :through

      def parse_date(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s)
      rescue ArgumentError, Date::Error
        nil
      end
  end
end
