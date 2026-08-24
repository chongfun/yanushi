module Expenses
  class CorrectService
    def self.call(
      expense:,
      property: nil,
      rentable_unit: :not_set,
      expense_kind: nil,
      amount_cents: nil,
      amount: nil,
      paid_on: nil,
      vendor_name: :not_set,
      external_reference: :not_set,
      description: :not_set,
      user: nil
    )
      new(
        expense: expense,
        property: property,
        rentable_unit: rentable_unit,
        expense_kind: expense_kind,
        amount_cents: amount_cents,
        amount: amount,
        paid_on: paid_on,
        vendor_name: vendor_name,
        external_reference: external_reference,
        description: description,
        user: user
      ).call
    end

    def initialize(
      expense:,
      property: nil,
      rentable_unit: :not_set,
      expense_kind: nil,
      amount_cents: nil,
      amount: nil,
      paid_on: nil,
      vendor_name: :not_set,
      external_reference: :not_set,
      description: :not_set,
      user: nil
    )
      @expense = expense
      @target_property = property || expense&.property
      @raw_rentable_unit = rentable_unit
      @target_expense_kind = expense_kind.presence || expense&.expense_kind
      @raw_amount_cents = amount_cents
      @raw_amount = amount
      @raw_paid_on = paid_on || expense&.paid_on
      @raw_vendor_name = vendor_name
      @raw_external_reference = external_reference
      @raw_description = description
      @user = user
    end

    def call
      return failure("Expense is required", :invalid_input) unless expense

      if user && expense.accounting_user != user
        return failure("Expense was not found", :not_found)
      end

      target_prop = target_property
      unless target_prop
        return failure("Property is required", :invalid_input)
      end

      target_kind = target_expense_kind
      unless target_kind
        return failure("Expense category is required", :invalid_input)
      end

      target_owner = target_prop.accounting_user
      if target_owner != expense.accounting_user
        return failure("Cannot transfer expense to another user's property", :ownership_mismatch)
      end

      resolved_unit = if raw_rentable_unit == :not_set
        expense.rentable_unit
      else
        raw_rentable_unit
      end

      if resolved_unit.present? && resolved_unit.property_id != target_prop.id
        return failure("Rentable unit must belong to the selected property", :property_mismatch)
      end

      paid_on_date = parse_date(raw_paid_on)
      return failure("Invalid paid_on date", :invalid_input) unless paid_on_date

      resolved_cents = parse_cents
      if resolved_cents.nil? || resolved_cents <= 0
        return failure("Expense amount must be greater than zero", :invalid_amount)
      end

      vendor = if raw_vendor_name == :not_set
        expense.vendor_name
      else
        raw_vendor_name.to_s.strip.presence
      end

      ref = if raw_external_reference == :not_set
        expense.external_reference
      else
        raw_external_reference.to_s.strip.presence
      end

      desc = if raw_description == :not_set
        expense.description
      else
        raw_description.to_s.strip.presence
      end

      creation_failure = nil # : ServiceResult?

      result = expense.with_lock do
        # Superseded check takes precedence over voided check
        if expense.superseded?
          replacement = expense.superseded_by
          if matches_replacement?(replacement, target_prop, target_kind, resolved_cents, paid_on_date, resolved_unit, vendor, ref, desc)
            return success({ original: expense, replacement: replacement, expense: replacement })
          else
            return failure("Expense has already been corrected with different attributes", :idempotency_conflict)
          end
        end

        # Reject already voided expense
        if expense.voided?
          return failure("Expense has already been voided", :already_voided)
        end

        active_reimbursements = expense.reimbursement_charges.active.order(:id).to_a
        active_reimbursements.each(&:lock!)
        active_reimbursements.select!(&:active?)

        total_reimbursements_cents = active_reimbursements.sum(&:amount_cents)
        if resolved_cents < total_reimbursements_cents
          return failure(
            "Corrected expense amount (#{format_money(resolved_cents)}) is less than total active reimbursements (#{format_money(total_reimbursements_cents)})",
            :exceeds_expense_amount
          )
        end

        active_reimbursements.each do |reimb|
          if reimb.security_deposit_applications.active.exists?
            return failure(
              "Active reimbursement charge ##{reimb.id} has active security deposit applications. Void or correct the deposit applications first.",
              :active_deposit_applications
            )
          end

          reimb_tenancy = reimb.tenancy
          if reimb_tenancy&.property&.id != target_prop.id
            return failure(
              "Active reimbursement charge ##{reimb.id} belongs to a tenancy on the original property and cannot be transferred to a different property",
              :property_mismatch
            )
          end

          if resolved_unit.present? && reimb_tenancy&.rentable_unit_id != resolved_unit.id
            return failure(
              "Active reimbursement charge ##{reimb.id} belongs to a tenancy on a different unit than the corrected unit-scoped expense",
              :unit_mismatch
            )
          end
        end

        # Reverse original entry
        entry = expense.journal_entries.find_by(event_type: "expense_posted")
        if entry
          reversal_res = Accounting::ReverseEntryService.call(
            journal_entry: entry,
            occurred_on: expense.paid_on
          )
          unless reversal_res.success?
            return reversal_res
          end
        end

        # Create replacement
        create_res = Expenses::CreateService.call(
          property: target_prop,
          rentable_unit: resolved_unit,
          expense_kind: target_kind,
          amount_cents: resolved_cents,
          paid_on: paid_on_date,
          vendor_name: vendor,
          external_reference: ref,
          description: desc
        )

        unless create_res.success?
          creation_failure = create_res
          raise ActiveRecord::Rollback
        end

        replacement = create_res.value!.data[:expense]

        # Restate active reimbursements onto replacement expense
        active_reimbursements.each do |reimb|
          reimb_entry = reimb.journal_entries.find_by(event_type: "charge_posted")
          if reimb_entry
            reimb_rev_res = Accounting::ReverseEntryService.call(
              journal_entry: reimb_entry,
              occurred_on: reimb.charge_date,
              description: "Restated with corrected source expense ##{expense.id}"
            )
            unless reimb_rev_res.success?
              creation_failure = reimb_rev_res
              raise ActiveRecord::Rollback
            end
          end

          new_reimb_res = Charges::CreateService.call(
            tenancy: reimb.tenancy,
            charge_kind: "reimbursement",
            amount_cents: reimb.amount_cents,
            charge_date: reimb.charge_date,
            due_on: reimb.due_on,
            description: reimb.description,
            source_expense: replacement
          )
          unless new_reimb_res.success?
            creation_failure = new_reimb_res
            raise ActiveRecord::Rollback
          end

          new_reimb = new_reimb_res.value!.data[:charge]
          reimb.update_columns(
            voided_at: Time.current,
            superseded_by_id: new_reimb.id
          )
        end

        expense.update_columns(
          voided_at: Time.current,
          superseded_by_id: replacement.id
        )

        success({
          original: expense,
          replacement: replacement,
          expense: replacement,
          journal_entry: create_res.value!.data[:journal_entry]
        })
      end

      # Return captured failure after lock release
      return creation_failure if creation_failure

      result
    end

    private

      attr_reader :expense, :target_property, :raw_rentable_unit, :target_expense_kind,
                  :raw_amount_cents, :raw_amount, :raw_paid_on, :raw_vendor_name,
                  :raw_external_reference, :raw_description, :user

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
          return nil unless amt_str.match?(/\A\d+(\.\d{1,2})?\z/)
          begin
            dec = BigDecimal(amt_str)
            return nil if dec <= 0

            (dec * 100).round
          rescue ArgumentError
            nil
          end
        elsif expense
          expense.amount_cents
        else
          nil
        end
      end

      def matches_replacement?(replacement, target_prop, target_kind, cents, date, unit, vendor, ref, desc)
        return false unless replacement
        replacement.property_id == target_prop.id &&
          replacement.rentable_unit_id == unit&.id &&
          replacement.expense_kind == target_kind.to_s &&
          replacement.amount_cents == cents &&
          replacement.paid_on == date &&
          replacement.vendor_name == vendor &&
          replacement.external_reference == ref &&
          replacement.description == desc
      end

      def format_money(cents)
        sprintf("$%.2f", cents / 100.0)
      end

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code)
        ServiceResult.failure(error: error, code: code)
      end
  end
end
