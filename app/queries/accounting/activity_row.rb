module Accounting
  class ActivityRow < Data.define(
    :id,
    :journal_entry,
    :occurred_on,
    :kind,
    :label,
    :description,
    :amount_cents,
    :property,
    :rentable_unit,
    :tenancy,
    :party,
    :source,
    :reversal,
    :corrected,
    :lifecycle_status
  )
    def corrected?
      lifecycle_status == :corrected || corrected == true
    end

    def voided?
      lifecycle_status == :voided
    end

    def active?
      lifecycle_status == :active || (!corrected? && !voided?)
    end
  end
end
