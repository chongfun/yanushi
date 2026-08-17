module SecurityDeposits
  class CreateService
    def self.call(tenancy:, required_amount: nil, required_amount_cents: nil, due_on: nil)
      new(
        tenancy: tenancy,
        required_amount: required_amount,
        required_amount_cents: required_amount_cents,
        due_on: due_on
      ).call
    end

    def initialize(tenancy:, required_amount: nil, required_amount_cents: nil, due_on: nil)
      @tenancy = tenancy
      @raw_amount = required_amount
      @raw_cents = required_amount_cents
      @raw_due_on = due_on
    end

    def call
      unless tenancy.is_a?(Tenancy) && tenancy.persisted? && !tenancy.destroyed?
        return ServiceResult.failure(error: "Tenancy must be a persisted Tenancy record", code: :invalid_tenancy)
      end

      cents = resolve_cents
      return ServiceResult.failure(error: "Required amount must be greater than zero", code: :invalid_input) unless cents&.positive?

      due_date = resolve_due_on
      return ServiceResult.failure(error: "Due date is required", code: :invalid_input) unless due_date

      tenancy.with_lock do
        existing = tenancy.security_deposit
        if existing
          if existing.required_amount_cents == cents && existing.due_on == due_date
            return ServiceResult.success(security_deposit: existing)
          else
            return ServiceResult.failure(
              error: "A security deposit requirement already exists for this tenancy with different terms",
              code: :conflict
            )
          end
        end

        deposit = SecurityDeposit.new(
          tenancy: tenancy,
          required_amount_cents: cents,
          due_on: due_date
        )

        if deposit.save
          ServiceResult.success(security_deposit: deposit)
        else
          ServiceResult.failure(error: deposit.errors.full_messages.join(", "), code: :validation_error)
        end
      end
    end

    private

      attr_reader :tenancy, :raw_amount, :raw_cents, :raw_due_on

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

      def resolve_due_on
        return raw_due_on if raw_due_on.is_a?(Date)
        return raw_due_on.to_date if raw_due_on.respond_to?(:to_date)
        return nil if raw_due_on.blank?

        Date.parse(raw_due_on.to_s)
      rescue ArgumentError, Date::Error
        nil
      end
  end
end
