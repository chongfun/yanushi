module Reports
  class ScheduleEStatusesQuery
    # States that still require action from the owner, in the order the Reports
    # landing should surface them (PRD 13.1: which properties require work).
    NEEDS_WORK_STATES = [ :needs_profile, :needs_review ].freeze

    # Sort weight per state; unknown states sort last.
    STATE_ORDER = { needs_profile: 0, needs_review: 1, ready: 2 }.freeze

    class ScheduleEStatus < Data.define(
      :property,
      :state,
      :unresolved_review_count,
      :net_income_cents
    )
      def needs_work?
        NEEDS_WORK_STATES.include?(state)
      end
    end

    def self.call(user:, tax_year:)
      new(user: user, tax_year: tax_year).call
    end

    # Calculates Schedule E readiness status for a property
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
      statuses = properties.map do |property|
        schedule_e_result = TaxReporting::ScheduleEQuery.call(property: property, tax_year: tax_year)
        self.class.build_status(property: property, schedule_e_result: schedule_e_result)
      end

      # Work first, then ready; address is the tiebreak inside each group.
      statuses.sort_by do |status|
        [ STATE_ORDER.fetch(status.state, STATE_ORDER.size), status.property.address ]
      end
    end

    private

      attr_reader :user, :tax_year
  end
end
