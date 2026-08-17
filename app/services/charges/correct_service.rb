module Charges
  class CorrectService
    def self.call(
      charge:,
      amount_cents: nil,
      amount: nil,
      charge_date: nil,
      due_on: nil,
      description: :not_set,
      tenancy: nil,
      source_expense: :not_set,
      rent_term: :not_set,
      service_period_start: :not_set,
      service_period_end: :not_set,
      user: nil
    )
      new(
        charge: charge,
        amount_cents: amount_cents,
        amount: amount,
        charge_date: charge_date,
        due_on: due_on,
        description: description,
        tenancy: tenancy,
        source_expense: source_expense,
        rent_term: rent_term,
        service_period_start: service_period_start,
        service_period_end: service_period_end,
        user: user
      ).call
    end

    def initialize(
      charge:,
      amount_cents: nil,
      amount: nil,
      charge_date: nil,
      due_on: nil,
      description: :not_set,
      tenancy: nil,
      source_expense: :not_set,
      rent_term: :not_set,
      service_period_start: :not_set,
      service_period_end: :not_set,
      user: nil
    )
      @charge = charge
      @raw_amount_cents = amount_cents
      @raw_amount = amount
      @raw_charge_date = charge_date
      @raw_due_on = due_on
      @raw_description = description
      @target_tenancy = tenancy || charge&.tenancy
      @raw_source_expense = source_expense
      @raw_rent_term = rent_term
      @raw_service_period_start = service_period_start
      @raw_service_period_end = service_period_end
      @user = user
    end

    def call
      unless charge.is_a?(Charge) && charge.persisted? && !charge.destroyed?
        return failure("Charge must be a persisted Charge record", :invalid_source)
      end

      journal_entry = charge.journal_entries.find_by(event_type: "charge_posted")
      unless journal_entry
        return failure("Journal entry not found for charge", :not_found)
      end

      if user && charge.tenancy&.accounting_user != user
        return failure("Charge was not found", :not_found)
      end

      unless target_tenancy
        return failure("Tenancy is required", :invalid_input)
      end

      if charge.tenancy&.accounting_user != target_tenancy.accounting_user
        return failure("Cannot transfer charge to another user's tenancy", :ownership_mismatch)
      end

      resolved_charge_date = if raw_charge_date.present?
        parse_date(raw_charge_date)
      else
        charge.charge_date
      end
      return failure("Invalid charge date", :invalid_input) unless resolved_charge_date

      resolved_due_on = if raw_due_on.present?
        parse_date(raw_due_on)
      else
        charge.due_on || resolved_charge_date
      end
      return failure("Invalid due on date", :invalid_input) unless resolved_due_on

      resolved_cents = parse_cents
      if resolved_cents.nil? || resolved_cents <= 0
        return failure("Charge amount must be greater than zero", :invalid_amount)
      end

      resolved_description = if raw_description == :not_set
        charge.description
      else
        raw_description.to_s.strip.presence
      end

      resolved_source_expense = if raw_source_expense == :not_set
        charge.source_expense
      else
        raw_source_expense
      end

      resolved_rent_term = if raw_rent_term == :not_set
        charge.rent_term
      else
        raw_rent_term
      end

      resolved_service_start = if raw_service_period_start == :not_set
        charge.service_period_start
      elsif raw_service_period_start.present?
        parsed = parse_date(raw_service_period_start)
        return failure("Invalid service period start date", :invalid_input) unless parsed

        parsed
      end

      resolved_service_end = if raw_service_period_end == :not_set
        charge.service_period_end
      elsif raw_service_period_end.present?
        parsed = parse_date(raw_service_period_end)
        return failure("Invalid service period end date", :invalid_input) unless parsed

        parsed
      end

      replacement_charge = nil # : Charge?
      failure_result = nil # : ServiceResult?

      Charge.transaction do
        expenses_to_lock = [] # : Array[Expense]
        if charge.charge_kind == "reimbursement" || (resolved_source_expense.is_a?(Expense) && resolved_source_expense.persisted?)
          src = charge.source_expense
          expenses_to_lock << src if src.is_a?(Expense) && src.persisted?
          if resolved_source_expense.is_a?(Expense) && resolved_source_expense.persisted? && !expenses_to_lock.include?(resolved_source_expense)
            expenses_to_lock << resolved_source_expense
          end
          expenses_to_lock.sort_by! { |e| e.id.to_i }
        end

        expenses_to_lock.each { |e| e.lock! }
        charge.lock!

        if charge.superseded?
          existing_rep = charge.superseded_by
          if existing_rep && matches_replacement?(existing_rep, target_tenancy, resolved_cents, resolved_charge_date, resolved_due_on, resolved_description, resolved_source_expense, resolved_rent_term, resolved_service_start, resolved_service_end)
            return success({ charge: existing_rep, original_charge: charge, replacement: existing_rep })
          else
            failure_result = failure("Cannot correct an already superseded charge", :already_superseded)
            raise ActiveRecord::Rollback
          end
        end

        if charge.voided?
          failure_result = failure("Cannot correct a voided charge", :already_voided)
          raise ActiveRecord::Rollback
        end

        # Reverse original entry on original charge_date
        reverse_res = Accounting::ReverseEntryService.call(
          journal_entry: journal_entry,
          occurred_on: charge.charge_date,
          description: "Corrected by replacement charge"
        )
        unless reverse_res.success?
          failure_result = reverse_res
          raise ActiveRecord::Rollback
        end

        # If reimbursement, validate against target source expense
        if charge.charge_kind == "reimbursement"
          unless resolved_source_expense
            failure_result = failure("Source expense is required for reimbursement charge", :invalid_input)
            raise ActiveRecord::Rollback
          end

          unless resolved_source_expense.posted? && (resolved_source_expense.active? || resolved_source_expense.id == charge.source_expense_id)
            failure_result = failure("Cannot reimburse an inactive or unposted expense", :invalid_expense_state)
            raise ActiveRecord::Rollback
          end

          if resolved_source_expense.rentable_unit_id.present? && resolved_source_expense.rentable_unit_id != target_tenancy.rentable_unit_id
            failure_result = failure("Unit-scoped expense can only be reimbursed by tenancies in the same unit", :unit_mismatch)
            raise ActiveRecord::Rollback
          end

          # Active reimbursements on target expense excluding the charge being superseded
          already_reimbursed = resolved_source_expense.reimbursement_charges.active.where.not(id: charge.id).sum(:amount_cents)
          remaining = resolved_source_expense.amount_cents.to_i - already_reimbursed
          if resolved_cents > remaining
            remaining_dollars = sprintf("%.2f", [ remaining, 0 ].max / 100.0)
            failure_result = failure("Reimbursement amount exceeds remaining reimbursable amount for this expense ($#{remaining_dollars})", :exceeds_expense_amount)
            raise ActiveRecord::Rollback
          end
        end

        charge.update_columns(voided_at: Time.current)

        # Create replacement charge
        create_res = Charges::CreateService.call(
          tenancy: target_tenancy,
          charge_kind: charge.charge_kind,
          amount_cents: resolved_cents,
          charge_date: resolved_charge_date,
          due_on: resolved_due_on,
          description: resolved_description,
          source_expense: resolved_source_expense,
          rent_term: resolved_rent_term,
          service_period_start: resolved_service_start,
          service_period_end: resolved_service_end
        )

        unless create_res.success?
          failure_result = create_res
          raise ActiveRecord::Rollback
        end

        created = create_res.value!.data[:charge]
        charge.update_columns(superseded_by_id: created.id)
        replacement_charge = created
      end

      if (f = failure_result)
        f
      elsif replacement_charge
        success({
          charge: replacement_charge,
          original_charge: charge,
          replacement: replacement_charge
        })
      else
        failure("Failed to correct charge", :correction_failed)
      end
    end

    private

      attr_reader :charge, :raw_amount_cents, :raw_amount, :raw_charge_date, :raw_due_on,
                  :raw_description, :target_tenancy, :raw_source_expense, :raw_rent_term,
                  :raw_service_period_start, :raw_service_period_end, :user

      def parse_date(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s)
      rescue ArgumentError, Date::Error
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
        elsif charge
          charge.amount_cents
        else
          nil
        end
      end

      def matches_replacement?(rep, t_tenancy, cents, date, due, desc, exp, term, start_date, end_date)
        rep.tenancy_id == t_tenancy.id &&
          rep.amount_cents == cents &&
          rep.charge_date == date &&
          rep.due_on == due &&
          rep.description.to_s.strip.presence == desc.to_s.strip.presence &&
          rep.source_expense_id == exp&.id &&
          rep.rent_term_id == term&.id &&
          rep.service_period_start == start_date &&
          rep.service_period_end == end_date
      end

      def success(data)
        ServiceResult.success(data)
      end

      def failure(error, code, data = {})
        ServiceResult.failure(error: error, code: code, data: data)
      end
  end
end
