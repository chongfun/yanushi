class PropertyTaxReviewResolution < ApplicationRecord
  belongs_to :property
  belongs_to :journal_entry

  TREATMENTS = %w[
    include_in_rents
    map_to_schedule_e_category
    exclude
  ].freeze

  enum :treatment, TREATMENTS.index_by(&:itself), prefix: false, validate: true

  validates :tax_year, presence: true,
                       numericality: {
                         only_integer: true,
                         greater_than_or_equal_to: TaxReporting::TaxYear::MIN_YEAR,
                         less_than_or_equal_to: TaxReporting::TaxYear::MAX_YEAR
                       }
  validates :treatment, presence: true, inclusion: { in: TREATMENTS }
  validates :schedule_e_category,
            presence: true,
            inclusion: { in: TaxReporting::ScheduleEAccountMap.supported_categories.map(&:to_s) },
            if: :map_to_schedule_e_category?
  validates :schedule_e_category, absence: true, unless: :map_to_schedule_e_category?
  validates :journal_entry_id, uniqueness: {
    scope: [ :property_id, :tax_year ],
    message: "has already been resolved for this tax year"
  }

  validate :validate_journal_entry_consistency
  validate :validate_not_a_reversal
  validate :validate_entry_requires_review
  validate :validate_single_unmapped_expense_account
  validate :validate_treatment_compatibility

  def include_in_rents?
    treatment == "include_in_rents"
  end

  def map_to_schedule_e_category?
    treatment == "map_to_schedule_e_category"
  end

  def exclude?
    treatment == "exclude"
  end

  private

    def validate_not_a_reversal
      return unless journal_entry

      if journal_entry.reversal? || journal_entry.reversal_of_id.present? || journal_entry.event_type == "reversal"
        errors.add(:journal_entry, "is a reversal; tax treatment is automatically derived from the original event")
      end
    end

    def validate_entry_requires_review
      return unless journal_entry

      unless TaxReporting::ScheduleEEventMap.reviewable?(journal_entry, property: property)
        errors.add(:journal_entry, "does not require tax review; resolution cannot be attached")
      end
    end

    def validate_single_unmapped_expense_account
      return unless journal_entry && property

      unmapped_account_ids = journal_entry.postings
        .select { |p| posting_belongs_to_property?(p, property) && p.account&.account_type == "expense" && TaxReporting::ScheduleEAccountMap.category_for(p.account&.key).nil? }
        .map(&:account_id)
        .compact
        .uniq

      if unmapped_account_ids.size > 1
        errors.add(:journal_entry, "contains multiple distinct unmapped expense accounts for this property and cannot be resolved with a single journal-entry-level resolution")
      end
    end

    def validate_journal_entry_consistency
      return unless property && journal_entry

      if journal_entry.user_id != property.user_id
        errors.add(:journal_entry, "must belong to the same user as the property")
      end

      unless property_postings_exist?
        errors.add(:journal_entry, "does not have any postings for this property")
      end

      if journal_entry.occurred_on.year != tax_year
        errors.add(:tax_year, "must match the year the journal entry occurred (#{journal_entry.occurred_on.year})")
      end
    end

    def property_postings_exist?
      journal_entry.postings.any? do |p|
        posting_belongs_to_property?(p, property)
      end
    end

    def posting_belongs_to_property?(posting, prop)
      return false unless posting && prop

      posting.property_id == prop.id ||
        posting.rentable_unit&.property_id == prop.id ||
        posting.tenancy&.rentable_unit&.property_id == prop.id
    end

    def validate_treatment_compatibility
      return unless journal_entry

      prop_postings = property ? journal_entry.postings.select { |p| posting_belongs_to_property?(p, property) } : journal_entry.postings

      if include_in_rents?
        is_deposit = journal_entry.event_type == "deposit_applied"
        has_cash_inflow = prop_postings.any? do |p|
          p.account&.key == "cash" && p.amount_cents.to_i.positive?
        end
        is_expense_module_event = journal_entry.event_type == "expense_posted" || journal_entry.source_type == "Expense"
        is_pure_expense = prop_postings.all? { |p| p.account&.account_type == "expense" || p.account&.account_type == "liability" }

        if is_expense_module_event || is_pure_expense || (!is_deposit && !has_cash_inflow)
          errors.add(:treatment, "cannot include an expense or non-cash/deposit entry in rental income")
        end
      elsif map_to_schedule_e_category?
        has_expense = prop_postings.any? { |p| p.account&.account_type == "expense" }
        unless has_expense
          errors.add(:treatment, "cannot map a non-expense entry to a Schedule E expense category")
        end
      end
    end
end
