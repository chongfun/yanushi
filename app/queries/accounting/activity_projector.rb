module Accounting
  class ActivityProjector
    def self.project(journal_entry, as_of: nil)
      new(journal_entry, as_of: as_of).project
    end

    def initialize(journal_entry, as_of: nil)
      @journal_entry = journal_entry
      @as_of = as_of
      @postings = journal_entry.postings.to_a
      @source = journal_entry.source
    end

    def project
      if journal_entry.reversal? || journal_entry.event_type == "reversal"
        project_reversal
      else
        project_standard
      end
    end

    private

      attr_reader :journal_entry, :as_of, :postings, :source

      def project_reversal
        orig_entry = journal_entry.reversal_of
        orig_row = orig_entry ? self.class.project(orig_entry, as_of: as_of) : nil
        orig_source = orig_entry&.source || source

        orig_label = orig_row&.label || "Entry"
        is_charge_waiver = orig_source.is_a?(Charge) && orig_source.voided? && !orig_source.superseded?

        if is_charge_waiver
          label = "#{orig_label} Waived"
          kind = "waiver"
        else
          label = "Correction of #{orig_label}"
          kind = "reversal"
        end

        amount_cents = orig_row ? -orig_row.amount_cents : fallback_amount_cents

        first_posting = postings.first

        ActivityRow.new(
          id: journal_entry.id,
          journal_entry: journal_entry,
          occurred_on: journal_entry.occurred_on,
          kind: kind,
          label: label,
          description: journal_entry.description,
          amount_cents: amount_cents,
          property: first_posting&.property || orig_row&.property,
          rentable_unit: first_posting&.rentable_unit || orig_row&.rentable_unit,
          tenancy: first_posting&.tenancy || orig_row&.tenancy,
          party: first_posting&.party || orig_row&.party,
          source: source || orig_row&.source,
          reversal: true,
          corrected: false,
          lifecycle_status: :active
        )
      end

      def project_standard
        case journal_entry.event_type
        when "charge_posted"
          project_charge
        when "receipt_posted"
          project_receipt
        when "expense_posted"
          project_expense
        when "deposit_received"
          project_deposit_received
        when "deposit_refunded"
          project_deposit_refunded
        when "deposit_applied"
          project_deposit_applied
        else
          project_fallback
        end
      end

      def project_charge
        charge_kind = source.respond_to?(:charge_kind) ? source.charge_kind.to_s : "charge"
        label = case charge_kind
        when "rent" then "Rent"
        when "late_fee" then "Late Fee"
        when "reimbursement" then "Reimbursement"
        else "Charge"
        end

        ar_posting = find_posting_by_account_key("tenant_receivable")
        amount_cents = ar_posting ? ar_posting.amount_cents : fallback_amount_cents

        build_row(
          kind: charge_kind,
          label: label,
          amount_cents: amount_cents,
          primary_posting: ar_posting
        )
      end

      def project_receipt
        cash_posting = find_posting_by_account_key("cash")
        amount_cents = cash_posting ? cash_posting.amount_cents : fallback_amount_cents

        build_row(
          kind: "payment",
          label: "Payment",
          amount_cents: amount_cents,
          primary_posting: cash_posting
        )
      end

      def project_expense
        cash_posting = find_posting_by_account_key("cash")
        # In DB cash is credited (-30000). For user display, expense is negative (-30000).
        amount_cents = cash_posting ? cash_posting.amount_cents : -fallback_amount_cents

        build_row(
          kind: "expense",
          label: "Expense",
          amount_cents: amount_cents,
          primary_posting: cash_posting
        )
      end

      def project_deposit_received
        cash_posting = find_posting_by_account_key("cash")
        amount_cents = cash_posting ? cash_posting.amount_cents : fallback_amount_cents

        build_row(
          kind: "deposit_received",
          label: "Security Deposit Received",
          amount_cents: amount_cents,
          primary_posting: cash_posting
        )
      end

      def project_deposit_refunded
        cash_posting = find_posting_by_account_key("cash")
        # Cash credited (-50000) -> display as -$500
        amount_cents = cash_posting ? cash_posting.amount_cents : -fallback_amount_cents

        build_row(
          kind: "deposit_refunded",
          label: "Security Deposit Refund",
          amount_cents: amount_cents,
          primary_posting: cash_posting
        )
      end

      def project_deposit_applied
        ar_posting = find_posting_by_account_key("tenant_receivable")
        # AR credited (-50000) -> display as -$500 application against balance
        amount_cents = ar_posting ? ar_posting.amount_cents : -fallback_amount_cents

        build_row(
          kind: "deposit_applied",
          label: "Security Deposit Applied",
          amount_cents: amount_cents,
          primary_posting: ar_posting
        )
      end

      def project_fallback
        first_posting = postings.first
        build_row(
          kind: journal_entry.event_type,
          label: journal_entry.event_type.titleize,
          amount_cents: fallback_amount_cents,
          primary_posting: first_posting
        )
      end

      def build_row(kind:, label:, amount_cents:, primary_posting:)
        primary = primary_posting || postings.first
        status = determine_lifecycle_status
        is_corrected = (status == :corrected)
        source_desc = source.respond_to?(:description) ? source.description : nil
        display_desc = source_desc.presence || journal_entry.description

        ActivityRow.new(
          id: journal_entry.id,
          journal_entry: journal_entry,
          occurred_on: journal_entry.occurred_on,
          kind: kind,
          label: label,
          description: display_desc,
          amount_cents: amount_cents,
          property: primary&.property,
          rentable_unit: primary&.rentable_unit,
          tenancy: primary&.tenancy,
          party: primary&.party,
          source: source,
          reversal: false,
          corrected: is_corrected,
          lifecycle_status: status
        )
      end

      def determine_lifecycle_status
        # If as_of is given, check if reversal happened after as_of
        reversal_entry = journal_entry.reversal
        if as_of.present?
          if reversal_entry && reversal_entry.occurred_on > as_of
            return :active
          elsif reversal_entry.nil? && source.respond_to?(:voided_at) && source.voided_at.present? && source.voided_at.to_date > as_of
            return :active
          end
        end

        if source.respond_to?(:superseded?) && source.superseded?
          return :corrected
        end

        if source.is_a?(Charge) && source.voided?
          return :voided
        end

        if source.respond_to?(:voided?) && source.voided?
          return :corrected
        end

        if journal_entry.reversed?
          return :corrected
        end

        :active
      end

      def check_corrected
        determine_lifecycle_status == :corrected
      end

      def find_posting_by_account_key(key)
        postings.find { |p| p.account&.key == key }
      end

      def fallback_amount_cents
        positive = postings.find { |p| p.amount_cents.positive? }
        positive ? positive.amount_cents : postings.first&.amount_cents.to_i.abs
      end
  end
end
