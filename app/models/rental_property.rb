class RentalProperty < ApplicationRecord
  belongs_to :user
  has_many :leases, dependent: :destroy
  has_many :scheduled_rents, through: :leases
  has_many :rent_payments, through: :scheduled_rents
  has_many :expenses, dependent: :destroy
  has_many :utility_payments, through: :leases
  enum :property_type, { commercial: 0, residential: 1 }

  def financial_items(year)
    start_date = Date.new(year.to_i, 1, 1)
    end_date = start_date.end_of_year

    items = []

    scheduled_rents.where(due_date: start_date..end_date).each do |sr|
      items << { date: sr.due_date, type: "Scheduled Rent", amount: sr.amount, object: sr }
    end

    rent_payments.where(payment_date: start_date..end_date).each do |rp|
      items << { date: rp.payment_date, type: "Rent Payment", amount: rp.amount, object: rp }
    end

    expenses.where(expense_date: start_date..end_date).each do |exp|
      items << { date: exp.expense_date, type: "Expense", amount: exp.amount, object: exp }
    end

    utility_payments.where(payment_date: start_date..end_date).each do |up|
      items << { date: up.payment_date, type: "Utility Payment", amount: up.amount, object: up }
    end

    items.sort_by { |item| item[:date] }
  end
end
