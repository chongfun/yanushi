class Posting < ApplicationRecord
  belongs_to :journal_entry
  belongs_to :account
  belongs_to :property, optional: true
  belongs_to :rentable_unit, optional: true
  belongs_to :tenancy, optional: true
  belongs_to :party, optional: true

  validates :amount_cents, presence: true, numericality: { only_integer: true, other_than: 0 }
  validate :account_belongs_to_journal_entry_user
  validate :dimensions_belong_to_journal_entry_user
  validate :dimension_hierarchy_coherent

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  def debit?
    amount_cents.positive?
  end

  def credit?
    amount_cents.negative?
  end

  def debit_amount
    amount_cents.positive? ? amount_cents : nil
  end

  def credit_amount
    amount_cents.negative? ? -amount_cents : nil
  end

  def accounting_user
    journal_entry&.user || account&.user
  end

  private

    def prevent_mutation
      errors.add(:base, "Posted journal postings are immutable")
      throw :abort
    end

    def account_belongs_to_journal_entry_user
      return unless account && journal_entry&.user_id

      if account.user_id != journal_entry.user_id
        errors.add(:account, "must belong to the journal entry user")
      end
    end

    def dimensions_belong_to_journal_entry_user
      return unless journal_entry

      user_id = journal_entry.user_id

      if (p = property) && p.user_id != user_id
        errors.add(:property, "must belong to the journal entry user")
      end

      if (u = rentable_unit) && u.property.user_id != user_id
        errors.add(:rentable_unit, "must belong to the journal entry user")
      end

      if (t = tenancy) && t.rentable_unit.property.user_id != user_id
        errors.add(:tenancy, "must belong to the journal entry user")
      end

      if (prt = party) && prt.user_id != user_id
        errors.add(:party, "must belong to the journal entry user")
      end
    end

    def dimension_hierarchy_coherent
      if (u = rentable_unit) && (p = property) && u.property_id != p.id
        errors.add(:property, "does not match rentable unit property")
      end

      if (t = tenancy)
        if (u = rentable_unit) && t.rentable_unit_id != u.id
          errors.add(:rentable_unit, "does not match tenancy rentable unit")
        end

        if (p = property) && t.rentable_unit.property_id != p.id
          errors.add(:property, "does not match tenancy property")
        end
      end
    end
end
