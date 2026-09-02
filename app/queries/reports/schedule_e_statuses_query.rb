module Reports
  class ScheduleEStatusesQuery
    ScheduleEStatus = Data.define(
      :property,
      :state,
      :unresolved_review_count,
      :net_income_cents
    )

    def self.call(user:, tax_year:)
      new(user: user, tax_year: tax_year).call
    end

    # Canonical single-property readiness calculation contract.
    # Callers (such as Properties::TaxesController and ReportsController) should rely
    # on this method rather than deriving readiness independently.
    def self.status_for(property:, tax_year:)
      return nil unless property

      schedule_e_result = TaxReporting::ScheduleEQuery.call(property: property, tax_year: tax_year)
      build_status(property: property, schedule_e_result: schedule_e_result)
    end

    def self.build_status(property:, schedule_e_result:)
      if schedule_e_result.tax_profile.blank?
        ScheduleEStatus.new(
          property: property,
          state: :needs_profile,
          unresolved_review_count: 0,
          net_income_cents: 0
        )
      elsif schedule_e_result.has_unresolved_reviews?
        ScheduleEStatus.new(
          property: property,
          state: :needs_review,
          unresolved_review_count: schedule_e_result.unresolved_review_items.size,
          net_income_cents: schedule_e_result.net_income_cents
        )
      else
        ScheduleEStatus.new(
          property: property,
          state: :ready,
          unresolved_review_count: 0,
          net_income_cents: schedule_e_result.net_income_cents
        )
      end
    end

    def initialize(user:, tax_year:)
      @user = user
      @tax_year = tax_year.to_i
    end

    def call
      return [] unless user

      properties = user.properties.includes(:tax_profiles).order(:address)
      properties.map do |property|
        schedule_e_result = TaxReporting::ScheduleEQuery.call(property: property, tax_year: tax_year)
        self.class.build_status(property: property, schedule_e_result: schedule_e_result)
      end
    end

    private

      attr_reader :user, :tax_year
  end
end
