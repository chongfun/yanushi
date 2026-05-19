class RentalProperty < ApplicationRecord
  belongs_to :user
  has_many :leases, dependent: :destroy
  has_many :scheduled_rents, through: :leases
  has_many :expenses, dependent: :destroy
  has_many :tenant_payments, through: :leases
  has_many :tenant_charges, through: :leases
  enum :property_type, {
    single_family_residence: 1,
    multi_family_residence: 2,
    vacation_or_short_term_rental: 3,
    commercial: 4,
    land: 5,
    royalties: 6,
    self_rental: 7,
    other: 8
  }

  def financial_items(year)
    start_date = Date.new(year.to_i, 1, 1)
    end_date = start_date.end_of_year

    items = []

    scheduled_rents.where(due_date: start_date..end_date).each do |sr|
      items << { date: sr.due_date, type: "Scheduled Rent", amount: sr.amount, object: sr }
    end

    tenant_payments.where(payment_date: start_date..end_date).each do |tp|
      items << { date: tp.payment_date, type: "Tenant Payment", amount: tp.amount, object: tp }
    end

    tenant_charges.where(charge_date: start_date..end_date).each do |tc|
      items << { date: tc.charge_date, type: "Tenant Charge", amount: tc.amount, object: tc }
    end

    expenses.where(expense_date: start_date..end_date).each do |exp|
      items << { date: exp.expense_date, type: "Expense", amount: exp.amount, object: exp }
    end

    items.sort_by { |item| item[:date] }
  end
end
