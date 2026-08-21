module TenancyParties
  class DestroyService
    def self.call(tenancy_party:)
      new(tenancy_party: tenancy_party).call
    end

    def initialize(tenancy_party:)
      @tenancy_party = tenancy_party
    end

    def call
      tenancy = tenancy_party.tenancy

      Tenancy.transaction do
        tenancy.lock!

        if tenancy_party.tenant?
          remaining_participants = tenancy.tenancy_parties.where.not(id: tenancy_party.id)
          unless tenancy.continuous_tenant_coverage?(remaining_participants)
            tenancy_party.errors.add(:base, "Cannot remove tenant participant: tenancy must maintain continuous tenant coverage throughout its duration")
            return ServiceResult.failure(
              data: { tenancy_party: tenancy_party },
              error: "Cannot remove tenant participant: tenancy must maintain continuous tenant coverage throughout its duration",
              code: :validation_error
            )
          end
        end

        tenancy_party.destroy!
      end

      ServiceResult.success({ tenancy_party: tenancy_party })
    rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordInvalid => e
      ServiceResult.failure(
        data: { tenancy_party: tenancy_party },
        error: e.message,
        code: :validation_error
      )
    end

    private

    attr_reader :tenancy_party
  end
end
