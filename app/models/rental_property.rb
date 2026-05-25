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

  validates :address, presence: true

  def financial_items(year)
    start_date = Date.new(year.to_i, 1, 1)
    end_date = start_date.end_of_year

    items = []

    if scheduled_rents.loaded?
      scheduled_rents.select { |sr| sr.due_date >= start_date && sr.due_date <= end_date }.each do |sr|
        items << { date: sr.due_date, type: "Scheduled Rent", amount: sr.amount, object: sr }
      end
    else
      scheduled_rents.where(due_date: start_date..end_date).each do |sr|
        items << { date: sr.due_date, type: "Scheduled Rent", amount: sr.amount, object: sr }
      end
    end

    if tenant_payments.loaded?
      tenant_payments.select { |tp| tp.payment_date >= start_date && tp.payment_date <= end_date }.each do |tp|
        items << { date: tp.payment_date, type: "Tenant Payment", amount: tp.amount, object: tp }
      end
    else
      tenant_payments.where(payment_date: start_date..end_date).each do |tp|
        items << { date: tp.payment_date, type: "Tenant Payment", amount: tp.amount, object: tp }
      end
    end

    if tenant_charges.loaded?
      tenant_charges.select { |tc| tc.charge_date >= start_date && tc.charge_date <= end_date }.each do |tc|
        items << { date: tc.charge_date, type: "Tenant Charge", amount: tc.amount, object: tc }
      end
    else
      tenant_charges.where(charge_date: start_date..end_date).each do |tc|
        items << { date: tc.charge_date, type: "Tenant Charge", amount: tc.amount, object: tc }
      end
    end

    if expenses.loaded?
      expenses.select { |exp| exp.expense_date >= start_date && exp.expense_date <= end_date }.each do |exp|
        items << { date: exp.expense_date, type: "Expense", amount: exp.amount, object: exp }
      end
    else
      expenses.where(expense_date: start_date..end_date).each do |exp|
        items << { date: exp.expense_date, type: "Expense", amount: exp.amount, object: exp }
      end
    end

    items.sort_by { |item| item[:date] }
  end

  def active_years(additional_years = [])
    @active_years_base ||= begin
      years = Set.new
      years << Date.current.year

      years.merge(scheduled_rents.pluck(Arel.sql("DISTINCT EXTRACT(YEAR FROM due_date)::integer")).compact)
      years.merge(tenant_payments.pluck(Arel.sql("DISTINCT EXTRACT(YEAR FROM payment_date)::integer")).compact)
      years.merge(tenant_charges.pluck(Arel.sql("DISTINCT EXTRACT(YEAR FROM charge_date)::integer")).compact)
      years.merge(expenses.pluck(Arel.sql("DISTINCT EXTRACT(YEAR FROM expense_date)::integer")).compact)
      years
    end

    years = @active_years_base.dup
    years.merge(additional_years.map(&:to_i).reject(&:zero?))
    years.to_a.sort
  end
end
