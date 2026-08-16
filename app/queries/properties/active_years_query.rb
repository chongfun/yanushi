module Properties
  class ActiveYearsQuery
    def initialize(property:)
      @property = property
    end

    def call(additional_years: [])
      years = Set.new
      years << Date.current.year
      years.merge(years_for(:charges, :charge_date))
      years.merge(years_for(:tenant_payments, :payment_date))
      years.merge(years_for(:expenses, :expense_date))
      additional_years.each do |year|
        next unless year.respond_to?(:to_i)

        parsed_year = year.to_i
        years << parsed_year unless parsed_year.zero?
      end
      years.to_a.sort
    end

    private

      attr_reader :property

      def years_for(association_name, date_attribute)
        table = property.public_send(association_name).klass.table_name
        property.public_send(association_name)
                .pluck(Arel.sql("DISTINCT EXTRACT(YEAR FROM #{table}.#{date_attribute})::integer"))
                .compact
      end
  end
end
