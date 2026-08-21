module Tenancies
  class CreateService
    def self.call(user:, tenancy_params: nil, participants: nil, initial_rent: nil, params: nil)
      p = (tenancy_params || params || {}).to_h.symbolize_keys
      parts = participants || p.delete(:participants) || p.delete(:party_ids) || []
      rent = (initial_rent || p.delete(:rent_term) || p.delete(:initial_rent) || {}).to_h.symbolize_keys

      if parts.is_a?(Array) && (parts.first.is_a?(Numeric) || parts.first.is_a?(String))
        parts = parts.reject(&:blank?).map { |pid| { party_id: pid.to_i, role: "tenant" } }
      end

      if p[:rent_amount].present? && rent[:amount_cents].blank?
        dollars = BigDecimal(p.delete(:rent_amount).to_s)
        rent[:amount_cents] = (dollars * 100).round
      end
      if p[:due_day].present? && rent[:due_day].blank?
        rent[:due_day] = p.delete(:due_day).to_i
      end
      if p[:frequency].present? && rent[:frequency].blank?
        rent[:frequency] = p.delete(:frequency).to_s
      end

      new(user: user, tenancy_params: p, participants: parts, initial_rent: rent).call
    end

    def initialize(user:, tenancy_params:, participants:, initial_rent:)
      @user = user
      @tenancy_params = tenancy_params
      @participants = Array(participants)
      @initial_rent = initial_rent || {}
    end

    def call
      rentable_unit_id = tenancy_params[:rentable_unit_id]
      unit = user.rentable_units.where(active: true).find_by(id: rentable_unit_id)
      unless unit
        return ServiceResult.failure(
          data: nil,
          error: "Active rentable unit not found or not owned by user",
          code: :not_found
        )
      end

      tenancy = unit.tenancies.new(tenancy_params)

      has_tenant_role = participants.any? do |p|
        role = p[:role] || p["role"]
        role.to_s == "tenant"
      end

      unless has_tenant_role
        tenancy.errors.add(:base, "At least one tenant participant is required")
        return ServiceResult.failure(
          data: { tenancy: tenancy },
          error: "At least one tenant participant is required",
          code: :validation_error
        )
      end

      created_rent_term = nil

      Tenancy.transaction do
        unit.lock!
        tenancy.save!

        participants.each do |p|
          party_id = p[:party_id] || p["party_id"] || (p[:party]&.id || p["party"]&.id)
          party = user.parties.find_by(id: party_id)
          unless party
            raise ActiveRecord::RecordNotFound, "Party #{party_id} not found or not owned by user"
          end

          role = p[:role] || p["role"]
          effective_from = p[:effective_from] || p["effective_from"] || tenancy.commencement_date
          effective_until = p[:effective_until] || p["effective_until"] || tenancy.termination_date

          tenancy.tenancy_parties.create!(
            party: party,
            role: role,
            effective_from: effective_from,
            effective_until: effective_until
          )
        end

        unless tenancy.continuous_tenant_coverage?
          tenancy.errors.add(:base, "Tenancy must maintain continuous tenant coverage throughout its duration")
          raise ActiveRecord::RecordInvalid, tenancy
        end

        amount_cents = initial_rent[:amount_cents] || initial_rent["amount_cents"]
        due_day = initial_rent[:due_day] || initial_rent["due_day"] || 1
        frequency = initial_rent[:frequency] || initial_rent["frequency"] || "monthly"
        effective_from = initial_rent[:effective_from] || initial_rent["effective_from"] || tenancy.commencement_date
        effective_until = initial_rent[:effective_until] || initial_rent["effective_until"] || tenancy.termination_date

        created_rent_term = tenancy.rent_terms.create!(
          amount_cents: amount_cents,
          due_day: due_day,
          frequency: frequency,
          effective_from: effective_from,
          effective_until: effective_until
        )

        if tenancy.commencement_date && tenancy.commencement_date <= Date.current
          gen_result = RentCharges::GenerateThroughService.call(tenancy: tenancy, through: Date.current)
          unless gen_result.success?
            tenancy.errors.add(:base, gen_result.failure.error)
            raise ActiveRecord::RecordInvalid, tenancy
          end
        end
      end

      ServiceResult.success({ tenancy: tenancy, rent_term: created_rent_term })
    rescue ActiveRecord::RecordInvalid => e
      failed_record = e.record || tenancy
      term_obj = failed_record.is_a?(RentTerm) ? failed_record : nil
      ServiceResult.failure(data: { tenancy: tenancy, rent_term: term_obj }, error: failed_record.errors.full_messages.to_sentence, code: :validation_error)
    rescue ActiveRecord::RecordNotFound => e
      ServiceResult.failure(data: { tenancy: tenancy }, error: e.message, code: :not_found)
    end

    private

      attr_reader :user, :tenancy_params, :participants, :initial_rent
  end
end
