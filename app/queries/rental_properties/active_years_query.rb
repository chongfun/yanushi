module RentalProperties
  class ActiveYearsQuery
    def initialize(rental_property:)
      @rental_property = rental_property
    end

    def call(additional_years: [])
      years = Set.new
      years << Date.current.year
      years.merge(years_for(:scheduled_rents, :due_date))
      years.merge(years_for(:tenant_payments, :payment_date))
      years.merge(years_for(:tenant_charges, :charge_date))
      years.merge(years_for(:expenses, :expense_date))
      years.merge(additional_years.map { |year| year.to_i if year.respond_to?(:to_i) }.compact.reject(&:zero?))
      years.to_a.sort
    end

    private

    attr_reader :rental_property

    def years_for(association_name, date_attribute)
      table = rental_property.public_send(association_name).klass.table_name
      rental_property.public_send(association_name)
                     .pluck(Arel.sql("DISTINCT EXTRACT(YEAR FROM #{table}.#{date_attribute})::integer"))
                     .compact
    end
  end
end
