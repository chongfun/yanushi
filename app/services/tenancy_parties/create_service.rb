module TenancyParties
  class CreateService
    def self.call(tenancy:, user: nil, params: nil)
      p = (params || {}).to_h.symbolize_keys
      new(tenancy: tenancy, user: user, params: p).call
    end

    def initialize(tenancy:, user:, params:)
      @tenancy = tenancy
      @user = user
      @params = params
    end

    def call
      party_id = params[:party_id]
      owner = user || tenancy.property&.user
      party = owner&.parties&.find_by(id: party_id)
      unless party
        return ServiceResult.failure(
          data: nil,
          error: "Party not found or not owned by user",
          code: :not_found
        )
      end

      Tenancy.transaction do
        tenancy.reload
        tenancy.lock!

        role = params[:role].presence || "tenant"
        eff_from = params[:effective_from].presence || tenancy.commencement_date
        eff_until = params[:effective_until].presence || tenancy.termination_date

        created_tp = tenancy.tenancy_parties.new(
          party: party,
          role: role,
          effective_from: eff_from,
          effective_until: eff_until
        )

        if created_tp.save
          ServiceResult.success({ tenancy_party: created_tp })
        else
          ServiceResult.failure(
            data: { tenancy_party: created_tp },
            error: created_tp.errors.full_messages.to_sentence,
            code: :validation_error
          )
        end
      end
    end

    private

      attr_reader :tenancy, :user, :params
  end
end
