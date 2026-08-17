module SecurityDeposits
  class UpdateService
    def self.call(security_deposit:, required_amount: nil, required_amount_cents: nil, due_on: nil)
      new(
        security_deposit: security_deposit,
        required_amount: required_amount,
        required_amount_cents: required_amount_cents,
        due_on: due_on
      ).call
    end

    def initialize(security_deposit:, required_amount: nil, required_amount_cents: nil, due_on: nil)
      @security_deposit = security_deposit
      @raw_amount = required_amount
      @raw_cents = required_amount_cents
      @raw_due_on = due_on
    end

    def call
      unless security_deposit.is_a?(SecurityDeposit) && security_deposit.persisted? && !security_deposit.destroyed?
        return ServiceResult.failure(error: "Security deposit must be a persisted record", code: :invalid_source)
      end

      cents = if raw_cents.present? || raw_amount.present?
                resolve_cents
      else
                security_deposit.required_amount_cents
      end

      if cents.nil? || !cents.positive?
        return ServiceResult.failure(error: "Required amount must be greater than zero", code: :invalid_amount)
      end

      due_date = if raw_due_on.present?
                   resolve_due_on
      else
                   security_deposit.due_on
      end

      unless due_date
        return ServiceResult.failure(error: "Invalid due date", code: :invalid_due_on)
      end

      security_deposit.with_lock do
        if security_deposit.transactions.exists?
          return ServiceResult.failure(
            error: "Security deposit requirement cannot be updated after transactions exist",
            code: :immutable_requirement
          )
        end

        security_deposit.required_amount_cents = cents
        security_deposit.due_on = due_date

        if security_deposit.save
          ServiceResult.success(security_deposit: security_deposit)
        else
          ServiceResult.failure(error: security_deposit.errors.full_messages.join(", "), code: :validation_error)
        end
      end
    end

    private

      attr_reader :security_deposit, :raw_amount, :raw_cents, :raw_due_on

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
