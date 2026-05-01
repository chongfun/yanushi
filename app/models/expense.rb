class Expense < ApplicationRecord
  belongs_to :rental_property
  
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :category, presence: true
  validates :expense_date, presence: true

  enum :category, {
    advertising: "advertising",
    auto_and_travel: "auto_and_travel",
    cleaning_and_maintenance: "cleaning_and_maintenance",
    commissions: "commissions",
    insurance: "insurance",
    legal_and_other_professional_fees: "legal_and_other_professional_fees",
    management_fees: "management_fees",
    mortgage_interest: "mortgage_interest",
    other_interest: "other_interest",
    repairs: "repairs",
    supplies: "supplies",
    taxes: "taxes",
    utilities: "utilities",
    depreciation_expense: "depreciation_expense",
    other: "other"
  }
end
