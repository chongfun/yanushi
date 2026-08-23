module TaxReporting
  class ScheduleEEventMap
    KNOWN_EXCLUDED_EVENT_TYPES = %w[
      charge_posted
      charge_waiver
      deposit_received
      deposit_refunded
      expense_posted
    ].freeze

    def self.classify_income_event(journal_entry)
      source_type = journal_entry.source_type
      event_type = journal_entry.event_type

      case [ source_type, event_type ]
      when [ "Receipt", "receipt_posted" ]
        :rents_received
      when [ "Receipt", "reversal" ], [ "Receipt", "receipt_voided" ]
        classify_reversal(journal_entry)
      when [ "SecurityDepositTransaction", "deposit_applied" ]
        :review_required
      when [ "SecurityDepositTransaction", "reversal" ]
        classify_reversal(journal_entry)
      when [ "Expense", "expense_posted" ],
           [ "Expense", "reversal" ],
           [ "Charge", "charge_posted" ],
           [ "Charge", "charge_waiver" ],
           [ "Charge", "reversal" ],
           [ "SecurityDepositTransaction", "deposit_received" ],
           [ "SecurityDepositTransaction", "deposit_refunded" ]
        :excluded
      else
        if journal_entry.reversal? || event_type == "reversal"
          classify_reversal(journal_entry)
        else
          :review_required
        end
      end
    end

    def self.classify_reversal(journal_entry)
      orig = journal_entry.reversal_of
      raise ArgumentError, "Reversal journal entry ##{journal_entry.id} is missing reversal_of lineage" unless orig

      case [ orig.source_type, orig.event_type ]
      when [ "Receipt", "receipt_posted" ]
        :rents_received_reversal
      when [ "SecurityDepositTransaction", "deposit_applied" ]
        :reversal_of_reviewed
      when [ "Expense", "expense_posted" ],
           [ "Charge", "charge_posted" ],
           [ "Charge", "charge_waiver" ],
           [ "SecurityDepositTransaction", "deposit_received" ],
           [ "SecurityDepositTransaction", "deposit_refunded" ]
        :excluded
      else
        :reversal_of_reviewed
      end
    end

    def self.reviewable?(journal_entry, property: nil)
      return false unless journal_entry
      return false if journal_entry.reversal? || journal_entry.event_type == "reversal" || journal_entry.reversal_of_id.present?

      classification = classify_income_event(journal_entry)
      return true if classification == :review_required

      postings = journal_entry.postings
      if property
        postings = postings.select do |p|
          p.property_id == property.id ||
            p.rentable_unit&.property_id == property.id ||
            p.tenancy&.rentable_unit&.property_id == property.id
        end
      end

      # Non-review_required events (e.g. expense_posted) are only reviewable
      # if they touch an expense account not mapped in ScheduleEAccountMap.
      postings.any? do |p|
        p.account&.account_type == "expense" && ScheduleEAccountMap.category_for(p.account&.key).nil?
      end
    end
  end
end
