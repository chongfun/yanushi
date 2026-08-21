module Properties
  class FinancialItemsQuery
    def initialize(property:)
      @property = property
    end

    def call(year:)
      start_date = Date.new(year.to_i, 1, 1)
      end_date = start_date.end_of_year

      [
        items_for(:charges, :charge_date, "Charge", start_date, end_date),
        items_for(:receipts, :received_on, "Payment", start_date, end_date),
        items_for(:expenses, :paid_on, "Expense", start_date, end_date)
      ].flatten.sort_by { |item| item[:date] }
    end

    private

      attr_reader :property

      def items_for(association_name, date_attribute, type, start_date, end_date)
        records = records_for(association_name, date_attribute, start_date, end_date)
        records.map do |record|
          {
            date: record.public_send(date_attribute),
            type: type,
            amount: record.amount,
            object: record
          }
        end
      end

      def records_for(association_name, date_attribute, start_date, end_date)
        association = property.public_send(association_name)
        if association.loaded?
          association.select do |record|
            date = record.public_send(date_attribute)
            date.present? && date.between?(start_date, end_date)
          end
        else
          association.where(date_attribute => start_date..end_date)
        end
      end
  end
end
