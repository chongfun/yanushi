module Properties
  class ScheduleESummaryQuery
    Result = Data.define(:rents_received, :utility_reimbursements, :total_income, :expenses_by_category, :total_expenses, :net_income)

    def initialize(property:)
      @property = property
    end

    def call(year:)
      start_date = Date.new(year.to_i, 1, 1)
      end_date = start_date.end_of_year
      rents_received = BigDecimal(property.receipts.active.where(received_on: start_date..end_date).sum(:amount_cents).to_s) / 100
      utility_reimbursements = BigDecimal("0")
      total_income = rents_received + utility_reimbursements
      expenses_cents_by_kind = property.expenses.posted.active
                                        .where(paid_on: start_date..end_date)
                                        .group(:expense_kind)
                                        .sum(:amount_cents)
      expenses_by_category = expenses_cents_by_kind.transform_values { |cents| BigDecimal(cents.to_s) / 100 }
      total_expenses = expenses_by_category.values.sum(BigDecimal("0"))

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

      attr_reader :property
  end
end
