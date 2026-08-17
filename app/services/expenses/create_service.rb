module Expenses
  class CreateService
    def self.call(property:, expense_kind:, paid_on:, amount_cents: nil, amount: nil, rentable_unit: nil, vendor_name: nil, external_reference: nil, description: nil)
      new(
        property: property,
        expense_kind: expense_kind,
        paid_on: paid_on,
        amount_cents: amount_cents,
        amount: amount,
        rentable_unit: rentable_unit,
        vendor_name: vendor_name,
        external_reference: external_reference,
        description: description
      ).call
    end

    def initialize(property:, expense_kind:, paid_on:, amount_cents: nil, amount: nil, rentable_unit: nil, vendor_name: nil, external_reference: nil, description: nil)
      @property = property
      @expense_kind = expense_kind.to_s.presence
      @raw_paid_on = paid_on
      @raw_amount_cents = amount_cents
      @raw_amount = amount
      @rentable_unit = rentable_unit
      @raw_vendor_name = vendor_name.to_s.strip.presence
      @raw_external_reference = external_reference.to_s.strip.presence
      @raw_description = description.to_s.strip.presence
    end

    def call
      return failure("Property is required", :invalid_input) unless property
      return failure("Expense category is required", :invalid_input) unless expense_kind
      return failure("Date paid is required", :invalid_input) unless raw_paid_on.present?

      paid_on_date = parse_date(raw_paid_on)
      return failure("Invalid paid_on date", :invalid_input) unless paid_on_date

      resolved_cents = parse_cents
      return failure("Expense amount must be greater than zero", :invalid_amount) if resolved_cents.nil? || resolved_cents <= 0

      if rentable_unit.present? && rentable_unit.property_id != property.id
        return failure("Rentable unit must belong to the property", :property_mismatch)
      end

      expense = Expense.new(
        property: property,
        rentable_unit: rentable_unit,
        expense_kind: expense_kind,
        amount_cents: resolved_cents,
        paid_on: paid_on_date,
        vendor_name: raw_vendor_name,
        external_reference: raw_external_reference,
        description: raw_description
      )

      unless expense.valid?
        return failure(expense.errors.full_messages.to_sentence, :validation_error, { expense: expense })
      end

      posted_expense = nil # : Expense?
      journal_entry = nil # : JournalEntry?

      Expense.transaction do
        expense.save!

        post_result = Expenses::PostService.call(expense: expense)
        if post_result.success?
          entry = post_result.value!.data[:journal_entry] # : JournalEntry
          journal_entry = entry
          expense.update_columns(posted_at: entry.posted_at)
          posted_expense = expense
        else
          raise ActiveRecord::Rollback, post_result.failure.error
        end
      end

      if (pe = posted_expense) && pe.posted?
        success({ expense: pe, journal_entry: journal_entry })
      else
        failure("Failed to post expense to ledger", :posting_failed, { expense: expense })
      end
    end

    private

      attr_reader :property, :expense_kind, :raw_paid_on, :raw_amount_cents, :raw_amount,
                  :rentable_unit, :raw_vendor_name, :raw_external_reference, :raw_description

      def parse_date(val)
        return val if val.is_a?(Date)
        Date.parse(val.to_s)
      rescue Date::Error, ArgumentError
        nil
      end

      def parse_cents
        if raw_amount_cents.present?
          return nil unless raw_amount_cents.is_a?(Integer)
          return nil if raw_amount_cents <= 0

          raw_amount_cents
        elsif raw_amount.present?
          amt_str = raw_amount.is_a?(Numeric) ? raw_amount.to_s : raw_amount.to_s.strip
          # Prevent invalid decimal strings or fractional cents like "100.005"
          return nil unless amt_str.match?(/\A\d+(\.\d{1,2})?\z/)
          begin
            dec = BigDecimal(amt_str)
            return nil if dec <= 0

            (dec * 100).round
          rescue ArgumentError
            nil
          end
        else
          nil
        end
      end

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code, data = {})
        ServiceResult.failure(error: error, code: code, data: data)
      end
  end
end
