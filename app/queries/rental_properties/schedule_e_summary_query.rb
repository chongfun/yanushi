module RentalProperties
  class ScheduleESummaryQuery
    Result = Data.define(:rents_received, :utility_reimbursements, :total_income, :expenses_by_category, :total_expenses, :net_income)

    def initialize(rental_property:)
      @rental_property = rental_property
    end

    def call(year:)
      start_date = Date.new(year.to_i, 1, 1)
      end_date = start_date.end_of_year
      rents_received = rental_property.tenant_payments.where(payment_date: start_date..end_date).sum(:amount)
      utility_reimbursements = 0
      total_income = rents_received + utility_reimbursements
      expenses_by_category = rental_property.expenses.where(expense_date: start_date..end_date).group(:category).sum(:amount)
      total_expenses = expenses_by_category.values.sum

      Result.new(
        rents_received: rents_received,
        utility_reimbursements: utility_reimbursements,
        total_income: total_income,
        expenses_by_category: expenses_by_category,
        total_expenses: total_expenses,
        net_income: total_income - total_expenses
      )
    end

    private

    attr_reader :rental_property
  end
end
