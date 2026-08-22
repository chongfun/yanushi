module TaxReporting
  class ScheduleEEventMap
    def self.classify_income_event(journal_entry)
      event_type = journal_entry.event_type

      case event_type
      when "receipt_posted"
        :rents_received
      when "reversal"
        orig_entry = journal_entry.reversal_of
        if orig_entry&.event_type == "receipt_posted"
          :rents_received_reversal
        else
          :excluded
        end
      when "deposit_received", "deposit_refunded"
        :excluded
      when "deposit_applied"
        :review_required
      when "charge_posted"
        :excluded
      else
        :excluded
      end
    end
  end
end
